import 'envd_api_error.dart';
import 'upload_body_web.dart' if (dart.library.io) 'upload_body_io.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'errors.dart';
import 'models.dart';
import 'transport.dart';
import 'content_transport.dart';
import 'connection.dart';

class Filesystem {
  final EnvdTransport _transport;
  Filesystem(this._transport);
  Future<Map<String, dynamic>> _rpc(
      String method, Map<String, dynamic> body, String? user,
      [RequestOptions? options]) async {
    try {
      return await _transport
          .withOptions(options)
          .rpc('filesystem.Filesystem', method, body, user: user);
    } on NotFoundException catch (error) {
      throw FileNotFoundException(error.message,
          code: error.code, statusCode: error.statusCode);
    }
  }

  ContentTransport _content(RequestOptions? options) {
    final transport = _transport.withOptions(options);
    return ContentTransport(transport.restClient, transport.baseUrl,
        transport.headers, transport.requestTimeout,
        signal: transport.signal,
        logger: transport.logger,
        responseError: _httpError,
        resolveError: transport.resolveError);
  }

  Object _httpError(int status, Object? body, String? reason) =>
      envdApiError(status, body, reason, fileNotFound: true);

  Map<String, String> _query(String path, String? user) => {
        'path': path,
        if (user ?? _transport.defaultUser case final username?)
          'username': username
      };
  Future<Uint8List> readBytes(String path,
          {String? user, bool gzip = false, RequestOptions? options}) async =>
      (await _content(options).request('GET', '/files',
              query: _query(path, user),
              extraHeaders: {if (gzip) 'Accept-Encoding': 'gzip'}))
          .bodyBytes;
  Future<String> read(String path,
          {String? user, bool gzip = false, RequestOptions? options}) async =>
      utf8.decode(
          await readBytes(path, user: user, gzip: gzip, options: options),
          allowMalformed: true);
  Stream<List<int>> readStream(String path,
          {String? user,
          bool gzip = false,
          Duration? idleTimeout,
          RequestOptions? options}) =>
      _content(options).readStream('/files',
          query: _query(path, user),
          idleTimeout: idleTimeout,
          extraHeaders: {if (gzip) 'Accept-Encoding': 'gzip'});

  void _validateMetadata(Map<String, String> metadata) {
    for (final entry in metadata.entries) {
      if (!RegExp(r"^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$").hasMatch(entry.key)) {
        throw InvalidArgumentException(
            'Invalid metadata key ${jsonEncode(entry.key)}: keys must be non-empty and use only HTTP token characters (letters, digits and !#\$%&\'*+-.^_`|~).');
      }
      if (!RegExp(r'^[\x20-\x7e]*$').hasMatch(entry.value)) {
        throw InvalidArgumentException(
            'Invalid metadata value for key ${jsonEncode(entry.key)}: values must be printable US-ASCII.');
      }
    }
    if (metadata.isNotEmpty && !_transport.supports('0.6.2')) {
      throw const TemplateException(
          'File metadata requires envd 0.6.2 or later.');
    }
  }

  List<EntryInfo> _writeResults(http.Response response) {
    final entries = jsonDecode(response.body) as List;
    if (entries.isEmpty) {
      throw const E2BException(
          'Expected to receive information about written file');
    }
    return entries.map((e) => EntryInfo(e as Map<String, dynamic>)).toList();
  }

  /// Upload a single file, creating its parent directories as necessary.
  Future<EntryInfo> write(String path, Object data,
          {String? user,
          Map<String, String> metadata = const {},
          bool? useOctetStream,
          bool gzip = false,
          RequestOptions? options}) async =>
      (await _write([WriteEntry(path, data)],
              path: path,
              user: user,
              metadata: metadata,
              useOctetStream: useOctetStream,
              gzip: gzip,
              options: options))
          .first;

  /// Upload multiple files. Metadata is applied to every file in the request.
  Future<List<EntryInfo>> writeFiles(List<WriteEntry> files,
          {String? user,
          Map<String, String> metadata = const {},
          bool? useOctetStream,
          bool gzip = false,
          RequestOptions? options}) =>
      _write(files,
          user: user,
          metadata: metadata,
          useOctetStream: useOctetStream,
          gzip: gzip,
          options: options);

  Future<List<EntryInfo>> _write(List<WriteEntry> files,
      {String? path,
      String? user,
      required Map<String, String> metadata,
      bool? useOctetStream,
      bool gzip = false,
      RequestOptions? options}) async {
    if (files.isEmpty) return [];
    _validateMetadata(metadata);
    final headers = {
      for (final e in metadata.entries) 'X-Metadata-${e.key}': e.value
    };
    final octet = ((useOctetStream ??
                (supportsStreamingUploads &&
                    files.any((f) => f.data is Stream<List<int>>))) ||
            gzip) &&
        _transport.supports('0.5.7');
    if (octet) {
      final batches = await Future.wait(files.map((file) async {
        final body = await prepareUpload(file.data,
            gzip: gzip, signal: options?.signal ?? _transport.signal);
        return _writeResults(await _content(options).request('POST', '/files',
            query: _query(file.path, user),
            data: body.data,
            streamed: body.streamed,
            extraHeaders: {
              'Content-Type': 'application/octet-stream',
              if (gzip) 'Content-Encoding': 'gzip',
              ...headers
            }));
      }));
      return batches.expand((b) => b).toList();
    }
    final transport = _transport.withOptions(options);
    transport.signal?.throwIfCanceled();
    final parts = <http.MultipartFile>[];
    for (final file in files) {
      var data = file.data;
      if (data is Stream<List<int>>) {
        data = await collectUploadBytes(data, signal: transport.signal);
      }
      final bytes = switch (data) {
        String text => utf8.encode(text),
        List<int> bytes => bytes,
        _ => throw const InvalidArgumentException(
            'data must be String, List<int>, or Stream<List<int>>')
      };
      parts.add(
          http.MultipartFile.fromBytes('file', bytes, filename: file.path));
    }
    transport.signal?.throwIfCanceled();
    final abort = Completer<void>();
    final remove = transport.signal?.listen(() {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableMultipartRequest(
          'POST',
          transport.uri('/files', {
            if (path != null) 'path': path,
            if (user ?? transport.defaultUser case final username?)
              'username': username,
          }),
          abortTrigger: abort.future)
        ..headers.addAll({...transport.headers, ...headers})
        ..files.addAll(parts);
      transport.logger?.info?.call(['Request POST ${request.url}']);
      final pending = (() async {
        final response = await transport.restClient.send(request);
        try {
          final log = response.statusCode >= 400
              ? transport.logger?.error
              : transport.logger?.info;
          log?.call(
              ['Response:', response.statusCode, response.reasonPhrase ?? '']);
        } catch (_) {
          await response.stream.listen((_) {}).cancel();
          rethrow;
        }
        return http.Response.fromStream(response);
      })();
      final timeout = transport.requestTimeout;
      final response = timeout == Duration.zero
          ? await pending
          : await pending.timeout(timeout);
      transport.signal?.throwIfCanceled();
      if (response.statusCode >= 300) {
        throw _httpError(response.statusCode, decodeBody(response.body),
            response.reasonPhrase);
      }
      return _writeResults(response);
    } catch (error, stack) {
      transport.signal?.throwIfCanceled();
      Error.throwWithStackTrace(await transport.resolveError(error), stack);
    } finally {
      if (!abort.isCompleted) abort.complete();
      remove?.call();
    }
  }

  Future<List<EntryInfo>> list(String path,
      {int depth = 1, String? user, RequestOptions? options}) async {
    if (depth < 1) {
      throw const InvalidArgumentException('depth should be at least one');
    }
    final response =
        await _rpc('ListDir', {'path': path, 'depth': depth}, user, options);
    return (response['entries'] as List? ?? [])
        .map((e) => EntryInfo(e as Map<String, dynamic>))
        .toList();
  }

  Future<EntryInfo> getInfo(String path,
      {String? user, RequestOptions? options}) async {
    final entry = (await _rpc('Stat', {'path': path}, user, options))['entry'];
    if (entry == null) {
      throw const E2BException(
          'Expected to receive information about the file or directory');
    }
    return EntryInfo(entry as Map<String, dynamic>);
  }

  Future<bool> exists(String path,
      {String? user, RequestOptions? options}) async {
    try {
      await getInfo(path, user: user, options: options);
      return true;
    } on NotFoundException {
      return false;
    }
  }

  Future<bool> makeDir(String path,
      {String? user, RequestOptions? options}) async {
    try {
      await _rpc('MakeDir', {'path': path}, user, options);
      return true;
    } on E2BException catch (e) {
      if (e.code == 'already_exists') return false;
      rethrow;
    }
  }

  Future<void> remove(String path,
      {String? user, RequestOptions? options}) async {
    await _rpc('Remove', {'path': path}, user, options);
  }

  Future<EntryInfo> rename(String oldPath, String newPath,
      {String? user, RequestOptions? options}) async {
    final entry = (await _rpc('Move',
        {'source': oldPath, 'destination': newPath}, user, options))['entry'];
    if (entry == null) {
      throw const E2BException(
          'Expected to receive information about moved object');
    }
    return EntryInfo(entry as Map<String, dynamic>);
  }

  /// Cancel the stream subscription to stop watching.
  Stream<FilesystemEvent> watchDir(String path,
          {bool recursive = false,
          bool includeEntry = false,
          bool allowNetworkMounts = false,
          String? user,
          Duration? timeout,
          RequestOptions? options}) =>
      _watchEvents(path,
              recursive: recursive,
              includeEntry: includeEntry,
              allowNetworkMounts: allowNetworkMounts,
              user: user,
              timeout: timeout,
              options: options)
          .where((event) => event['filesystem'] is Map<String, dynamic>)
          .map((event) =>
              FilesystemEvent(event['filesystem'] as Map<String, dynamic>));

  Stream<Map<String, dynamic>> _watchEvents(String path,
      {required bool recursive,
      required bool includeEntry,
      required bool allowNetworkMounts,
      String? user,
      Duration? timeout,
      RequestOptions? options}) {
    void requireVersion(bool enabled, String version, String message) {
      if (enabled &&
          _transport.version.isNotEmpty &&
          !_transport.supports(version)) {
        throw TemplateException(message);
      }
    }

    requireVersion(recursive, '0.1.4',
        'You need to update the template to use recursive watching.');
    requireVersion(includeEntry, '0.6.3',
        'You need to update the template to include entry info in watch events.');
    requireVersion(allowNetworkMounts, '0.6.4',
        'You need to update the template to watch directories on network mounts.');
    return _transport.withOptions(options).stream(
        'filesystem.Filesystem',
        'WatchDir',
        {
          'path': path,
          'recursive': recursive,
          'includeEntry': includeEntry,
          'allowNetworkMounts': allowNetworkMounts,
        },
        user: user,
        timeout: timeout);
  }

  /// Callback-based official watch lifecycle. Resolves after the start event.
  Future<WatchHandle> watch(
      String path, FutureOr<void> Function(FilesystemEvent) onEvent,
      {FutureOr<void> Function(Object? error)? onExit,
      bool recursive = false,
      bool includeEntry = false,
      bool allowNetworkMounts = false,
      String? user,
      Duration timeout = const Duration(seconds: 60),
      RequestOptions? options}) async {
    final events = StreamIterator(_watchEvents(path,
        recursive: recursive,
        includeEntry: includeEntry,
        allowNetworkMounts: allowNetworkMounts,
        user: user,
        timeout: timeout,
        options: options));
    final requestTimeout = options?.requestTimeout ?? _transport.requestTimeout;
    Future<void> started() async {
      if (!await events.moveNext() || events.current['start'] == null) {
        throw const E2BException('Expected start event');
      }
    }

    try {
      if (requestTimeout == Duration.zero) {
        await started();
      } else {
        await started().timeout(requestTimeout);
      }
    } catch (_) {
      await events.cancel();
      rethrow;
    }
    return WatchHandle._(events, onEvent, onExit);
  }
}

class WatchHandle {
  final StreamIterator<Map<String, dynamic>> _events;
  final FutureOr<void> Function(FilesystemEvent) _onEvent;
  final FutureOr<void> Function(Object?)? _onExit;
  bool _stopped = false;
  late final Future<void> done;
  WatchHandle._(this._events, this._onEvent, this._onExit) {
    done = _run();
  }
  Future<void> stop() async {
    _stopped = true;
    await _events.cancel();
  }

  Future<void> _run() async {
    Object? failure;
    try {
      while (await _events.moveNext()) {
        final raw = _events.current['filesystem'];
        if (raw is! Map<String, dynamic>) continue;
        final event = FilesystemEvent(raw);
        if (event.eventType == FilesystemEventType.unknown) continue;
        try {
          await _onEvent(event);
        } catch (error) {
          failure = error;
          break;
        }
      }
    } catch (error) {
      if (!_stopped) failure = error;
    }
    try {
      await _onExit?.call(failure);
    } catch (_) {
    } finally {
      await _events.cancel();
    }
  }
}

/// A file in a batch upload. Data is text, bytes, or a byte stream.
class WriteEntry {
  final String path;
  final Object data;
  const WriteEntry(this.path, this.data);
}
