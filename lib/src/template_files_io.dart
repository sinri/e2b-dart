import 'dockerignore.dart';
import 'node_utf8.dart';
import 'js_string.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'connection.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'errors.dart';

List<String> readDockerignore(String context) {
  final file = File(p.join(context, '.dockerignore'));
  if (!file.existsSync()) return [];
  return nodeUtf8Decode(file.readAsBytesSync())
      .replaceFirst(RegExp('^\uFEFF'), '')
      .split('\n')
      .where((s) => !s.startsWith('#'))
      .map(jsTrim)
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Ordered Docker ignore rules. A directory match applies to all descendants;
/// later negations may re-include a descendant, so traversal is never pruned.
List<String> _normalizePatterns(List<String> patterns, String context) =>
    patterns.map((pattern) {
      var value = jsTrim(pattern);
      final negated = value.startsWith('!');
      if (negated) value = jsTrim(value.substring(1));
      if (p.isAbsolute(value)) {
        final relative = p.relative(value, from: context);
        if (relative != '.' &&
            relative != '..' &&
            !relative.startsWith('..${p.separator}') &&
            !p.isAbsolute(relative)) {
          value = relative;
        }
      }
      return '${negated ? '!' : ''}$value';
    }).toList();

Future<List<String>> selectTemplateFiles(
    String context, String src, List<String> ignorePatterns) async {
  context = p.absolute(context);
  final selected = <String>{};
  final matcher = DockerIgnoreMatcher(
      _normalizePatterns(ignorePatterns, context),
      backslashIsSeparator: p.separator == r'\');
  final matches = src == '.' || src == './'
      ? <FileSystemEntity>[Directory(context)]
      : await Glob(src).list(root: context, followLinks: false).toList();
  for (final entity in matches) {
    final path = p.absolute(entity.path);
    final relative = p.relative(path, from: context);
    final relativePosix =
        relative == '.' ? '' : p.posix.joinAll(p.split(relative));
    if ((relativePosix.isEmpty || !matcher.matches(relativePosix))) {
      selected.add(path);
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await for (final child
          in Directory(path).list(recursive: true, followLinks: false)) {
        final childRelative =
            p.posix.joinAll(p.split(p.relative(child.path, from: context)));
        if (!matcher.matches(childRelative)) {
          selected.add(p.absolute(child.path));
        }
      }
    }
  }
  return selected.toList()..sort();
}

/// SHA-256 byte sequence used by the pinned JS implementation. Directory sizes,
/// uid/gid and timestamps are intentionally excluded from cache identity.
Future<String> calculateTemplateFilesHash(String context, String src,
    String dest, List<String> ignorePatterns, bool resolveSymlinks) async {
  final files = await selectTemplateFiles(context, src, ignorePatterns);
  if (files.isEmpty) {
    throw TemplateException('No files found in ${p.join(context, src)}');
  }
  final output = _DigestSink();
  final hash = sha256.startChunkedConversion(output);
  void text(String value) => hash.add(utf8.encode(value));
  text('COPY $src $dest');
  for (final file in files) {
    final relative = p.relative(file, from: p.absolute(context));
    text(relative == '.' ? '' : p.posix.joinAll(p.split(relative)));
    final type = FileSystemEntity.typeSync(file, followLinks: false);
    final stat = FileStat.statSync(file);
    if (type == FileSystemEntityType.link &&
        (!resolveSymlinks ||
            (stat.type != FileSystemEntityType.file &&
                stat.type != FileSystemEntityType.directory))) {
      final target = Link(file).targetSync();
      // Dart's FileStat follows links. Obtain the link's own mode/size; macOS
      // links can have 0755 permissions, unlike Linux's usual 0777.
      final result = await Process.run('stat',
          Platform.isMacOS ? ['-f', '%p %z', file] : ['-c', '%f %s', file]);
      if (result.exitCode != 0) {
        throw TemplateException(
            'Cannot stat symbolic link $file: ${result.stderr}');
      }
      final fields = result.stdout.toString().trim().split(RegExp(r'\s+'));
      text('${int.parse(fields[0], radix: Platform.isMacOS ? 8 : 16)}');
      text(fields[1]);
      text(target);
      continue;
    }
    text('${stat.mode}');
    if (stat.type != FileSystemEntityType.directory) text('${stat.size}');
    if (stat.type == FileSystemEntityType.file) {
      await for (final chunk in File(file).openRead()) {
        hash.add(chunk);
      }
    }
  }
  hash.close();
  return output.value!.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class TemplateArchive {
  final Directory directory;
  final File file;
  final int size;
  TemplateArchive(this.directory, this.file, this.size);
  Future<void> cleanup() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {/* Already removed. */}
  }
}

/// Spool an archive to disk, with no recursive tar traversal: file selection
/// already applied ignore rules, including explicit descendant re-inclusions.
Future<TemplateArchive> spoolTemplateArchive(String context, String src,
    List<String> ignorePatterns, bool resolveSymlinks, bool gzip) async {
  final paths = await selectTemplateFiles(context, src, ignorePatterns);
  final temp = await Directory.systemTemp.createTemp('e2b-template-');
  try {
    final listing = File(p.join(temp.path, 'files.list'));
    await listing.writeAsBytes(utf8.encode(
        '${paths.map((f) => p.relative(f, from: p.absolute(context))).join('\x00')}\x00'));
    final file = File(p.join(temp.path, 'context.tar${gzip ? '.gz' : ''}'));
    final result = await Process.run('tar', [
      if (Platform.isMacOS) ...['--no-xattrs', '--no-acls', '--no-fflags'],
      '--no-recursion',
      if (resolveSymlinks) '-h',
      if (gzip) '-z',
      '-cf',
      file.path,
      '-C',
      p.absolute(context),
      '--null',
      '-T',
      listing.path,
    ], environment: {
      'COPYFILE_DISABLE': '1'
    });
    if (result.exitCode != 0) {
      throw FileUploadException('Failed to create archive: ${result.stderr}');
    }
    return TemplateArchive(temp, file, await file.length());
  } catch (_) {
    await temp.delete(recursive: true);
    rethrow;
  }
}

Future<void> uploadTemplateFiles(
    http.Client client,
    Uri url,
    Map<String, String> headers,
    String context,
    String src,
    List<String> ignorePatterns,
    bool resolveSymlinks,
    bool gzip,
    RequestOptions? options) async {
  TemplateArchive? archive;
  final abort = Completer<void>();
  void stop() {
    if (!abort.isCompleted) abort.complete();
  }

  StreamSubscription<List<int>>? producer;
  void Function()? remove;
  try {
    archive = await spoolTemplateArchive(
        context, src, ignorePatterns, resolveSymlinks, gzip);
    options?.signal?.throwIfCanceled();
    remove = options?.signal?.listen(stop);
    final request =
        http.AbortableStreamedRequest('PUT', url, abortTrigger: abort.future)
          ..headers.addAll({
            for (final e in headers.entries)
              if (e.key.toLowerCase() != 'content-length') e.key: e.value
          })
          ..contentLength = archive.size;
    final pending = (() async {
      final completion = Completer<void>();
      producer = archive!.file.openRead().listen(request.sink.add,
          onError: (Object error, StackTrace stack) {
        stop();
        if (!completion.isCompleted) completion.completeError(error, stack);
        unawaited(request.sink.close());
      }, onDone: () {
        if (!completion.isCompleted) completion.complete();
        unawaited(request.sink.close());
      });
      // Observe producer failure even when the HTTP peer rejects early.
      unawaited(completion.future
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      final response =
          await http.Response.fromStream(await client.send(request));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FileUploadException(
            'Failed to upload file: ${response.reasonPhrase ?? response.statusCode}');
      }
      await completion.future;
    })();
    final timeout = options?.requestTimeout ?? const Duration(hours: 1);
    await (timeout == Duration.zero ? pending : pending.timeout(timeout));
    options?.signal?.throwIfCanceled();
  } catch (error) {
    if (error is FileUploadException) rethrow;
    throw FileUploadException('Failed to upload file: $error');
  } finally {
    stop();
    remove?.call();
    await producer?.cancel();
    await archive?.cleanup();
  }
}
