import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/template_files_io.dart';
import 'package:e2b/e2b.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('dockerignore file parsing matches Node trim and comment ordering', () {
    final directory = Directory.systemTemp.createTempSync('e2b-ignore-lines-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('${directory.path}/.dockerignore').writeAsStringSync(
        '\uFEFF#first\n#comment\n #indented\n\u0085\n\uFEFFpattern\uFEFF\n'
        '\u2007space\u2007\n\n');
    expect(readDockerignore(directory.path),
        ['#indented', '\u0085', 'pattern', 'space']);
  });

  late Directory context;
  setUp(() async {
    context = await Directory.systemTemp.createTemp('e2b-template-files-');
    await Directory(p.join(context.path, 'nested')).create();
    await File(p.join(context.path, 'a.txt')).writeAsString('hello 中文');
    await File(p.join(context.path, 'nested', 'b.bin')).writeAsBytes([0, 255]);
    await Link(p.join(context.path, 'alias')).create('a.txt');
    await Link(p.join(context.path, 'broken')).create('missing');
  });
  tearDown(() => context.delete(recursive: true));
  test('COPY upload rejection prevents build trigger', () async {
    var triggered = false;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/v3/templates') {
            return http.Response('{"templateID":"t","buildID":"b"}', 200);
          }
          if (request.url.path.startsWith('/templates/t/files/')) {
            return http.Response(
                '{"present":false,"url":"https://storage.example/upload"}',
                200);
          }
          if (request.method == 'PUT') return http.Response('rejected', 403);
          triggered = true;
          return http.Response('{}', 200);
        }));
    await expectLater(
        client.templates.buildInBackground(
            Template(fileContextPath: context.path).copy('a.txt', '/dest'),
            'name'),
        throwsA(isA<FileUploadException>()));
    expect(triggered, isFalse);
    client.close();
  });
  test(
      'COPY archive preserves links and excludes ignored entries without recursion',
      () async {
    final spool = await spoolTemplateArchive(
        context.path, '.', ['nested', '!nested/b.bin'], false, true);
    try {
      final archive = TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(await spool.file.readAsBytes()));
      final names = archive.files
          .map((f) => f.name.replaceFirst(RegExp(r'^\./'), ''))
          .toList();
      expect(names, containsAll(['a.txt', 'alias', 'broken', 'nested/b.bin']));
      expect(names, isNot(contains('nested/')));
      final alias = archive.files.firstWhere((f) => f.name.endsWith('alias'));
      expect(alias.isSymbolicLink, isTrue);
      expect(alias.nameOfLinkedFile, 'a.txt');
      expect(spool.size, await spool.file.length());
    } finally {
      await spool.cleanup();
    }
    expect(await spool.directory.exists(), isFalse);
  });
  for (final scenario in [(false, false), (true, false), (true, true)]) {
    final (present, force) = scenario;
    test('COPY build cache=$present force=$force uploads before trigger',
        () async {
      final calls = <String>[];
      final client = E2BClient(
          apiKey: 'secret',
          httpClient: MockClient((request) async {
            calls.add(
                '${request.method} ${request.url.host}${request.url.path}');
            if (request.url.path == '/v3/templates') {
              return http.Response('{"templateID":"t","buildID":"b"}', 200);
            }
            if (request.url.path.startsWith('/templates/t/files/')) {
              return http.Response(
                  jsonEncode({
                    'present': present,
                    'url': 'https://storage.example/upload',
                    'headers': {'x-signed': 'value', 'Content-Length': '1'}
                  }),
                  200);
            }
            if (request.method == 'PUT') {
              expect(request.headers['X-API-Key'], isNull);
              expect(request.headers['x-signed'], 'value');
              expect(request.contentLength, request.bodyBytes.length);
              expect(request.bodyBytes.length, greaterThan(1));
              final archive = TarDecoder()
                  .decodeBytes(GZipDecoder().decodeBytes(request.bodyBytes));
              expect(archive.files.single.name, 'a.txt');
              expect(utf8.decode(archive.files.single.content as List<int>),
                  'hello 中文');
              return http.Response('', 200);
            }
            final data = jsonDecode(request.body);
            expect(data['steps'][0]['filesHash'], hasLength(64));
            return http.Response('{}', 200);
          }));
      await client.templates.buildInBackground(
          Template(fileContextPath: context.path)
              .copy('a.txt', '/dest', forceUpload: force),
          'name');
      expect(calls.first, contains('/v3/templates'));
      expect(calls.last, contains('/v2/templates/t/builds/b'));
      expect(calls.where((c) => c.startsWith('PUT')).length,
          present && !force ? 0 : 1);
      client.close();
    });
  }
  test('Template JSON computes COPY hashes by default without mutating steps',
      () async {
    final template =
        Template(fileContextPath: context.path).copy('a.txt', '/dest');
    final data = jsonDecode(await Template.toJSON(template));
    expect(
        data['steps'][0]['filesHash'],
        await calculateTemplateFilesHash(
            context.path, 'a.txt', '/dest', [], false));
    expect(template.instructions.single.filesHash, isNull);
    final raw =
        jsonDecode(await Template.toJSON(template, computeHashes: false));
    expect(raw['steps'][0].containsKey('filesHash'), isFalse);
    final missing =
        Template(fileContextPath: context.path).copy('missing', '/dest');
    await expectLater(
        Template.toJSON(missing), throwsA(isA<TemplateException>()));
    expect(await Template.toJSON(missing, computeHashes: false),
        contains('missing'));
  });
  test('COPY hash matches Node SHA256 for files directories and links',
      () async {
    for (final resolve in [false, true]) {
      final paths = await selectTemplateFiles(context.path, '.', []);
      final oracle = await Process.run('node', [
        '-e',
        r'''
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const context=process.argv[1], files=JSON.parse(process.argv[2]), follow=process.argv[3]==='true';
const hash=crypto.createHash('sha256'); hash.update('COPY . /dest');
for(const file of files) {
  hash.update(path.relative(context,file).split(path.sep).join('/'));
  const lstat=fs.lstatSync(file); let stat=fs.statSync(file,{throwIfNoEntry:false});
  const link=lstat.isSymbolicLink() && !(follow && (stat?.isFile() || stat?.isDirectory()));
  if(link) stat=lstat;
  hash.update(stat.mode.toString());
  if(!stat.isDirectory()) hash.update(stat.size.toString());
  if(link) hash.update(fs.readlinkSync(file));
  else if(stat.isFile()) hash.update(fs.readFileSync(file));
}
console.log(hash.digest('hex'));
''',
        context.path,
        jsonEncode(paths),
        '$resolve'
      ]);
      expect(oracle.exitCode, 0, reason: '${oracle.stderr}');
      expect(
          await calculateTemplateFilesHash(
              context.path, '.', '/dest', [], resolve),
          oracle.stdout.toString().trim());
    }
  });
  test('ignore rules preserve last-match wins and do not prune reinclusions',
      () async {
    final paths = await selectTemplateFiles(
        context.path, '.', ['nested', '!nested/b.bin', '*.txt']);
    final relative =
        paths.map((f) => p.relative(f, from: context.path)).toList();
    expect(relative, ['.', 'alias', 'broken', 'nested/b.bin']);
  });
  test('dockerignore strips BOM and column-zero comments', () async {
    await File(p.join(context.path, '.dockerignore'))
        .writeAsString('\uFEFF#comment\n \n *.txt \n!a.txt\n  #literal\n');
    expect(readDockerignore(context.path), ['*.txt', '!a.txt', '#literal']);
  });
  test('hash excludes mtime and changes with contents and destination',
      () async {
    final first = await calculateTemplateFilesHash(
        context.path, 'a.txt', '/dest', [], false);
    await File(p.join(context.path, 'a.txt'))
        .setLastModified(DateTime.utc(2000));
    expect(
        await calculateTemplateFilesHash(
            context.path, 'a.txt', '/dest', [], false),
        first);
    expect(
        await calculateTemplateFilesHash(
            context.path, 'a.txt', '/other', [], false),
        isNot(first));
    await File(p.join(context.path, 'a.txt')).writeAsString('changed');
    expect(
        await calculateTemplateFilesHash(
            context.path, 'a.txt', '/dest', [], false),
        isNot(first));
  });
}
