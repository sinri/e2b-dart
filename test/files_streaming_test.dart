import 'dart:convert';
import 'dart:io' as io;
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:e2b/src/upload_body_web.dart' as web;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('file text reads replace malformed UTF-8 and strip initial BOM',
      () async {
    var bytes = <int>[];
    final client = MockClient((_) async => http.Response.bytes(bytes, 200));
    addTearDown(client.close);
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('https://sandbox.test'), {}, const Duration(seconds: 5)));
    for (final vector in <List<int>, String>{
      [255, 97]: '\uFFFDa',
      [226, 130]: '\uFFFD',
      [239, 187, 191, 97]: 'a',
      [192, 175]: '\uFFFD\uFFFD',
    }.entries) {
      bytes = vector.key;
      expect(await files.read('/a'), vector.value);
      expect(await files.readBytes('/a'), bytes);
    }
  });

  test('native HTTP gzip downloads decode text bytes and stream formats',
      () async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final client = http.Client();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    final payload = utf8.encode('真实 gzip 数据 🌍\n' * 1000);
    final compressed = io.gzip.encode(payload);
    var requests = 0;
    final serving = server.listen((request) async {
      requests++;
      expect(request.uri.path, '/files');
      expect(request.uri.queryParameters['path'], '/compressed');
      expect(request.headers.value('accept-encoding'), 'gzip');
      request.response.headers.set('content-encoding', 'gzip');
      request.response.headers.contentType = io.ContentType.binary;
      request.response.contentLength = compressed.length;
      final middle = compressed.length ~/ 2;
      request.response.add(compressed.sublist(0, middle));
      await request.response.flush();
      request.response.add(compressed.sublist(middle));
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final files = Filesystem(EnvdTransport(
        client,
        Uri.parse('http://127.0.0.1:${server.port}'),
        {},
        const Duration(seconds: 5)));
    expect(await files.read('/compressed', gzip: true), utf8.decode(payload));
    expect(await files.readBytes('/compressed', gzip: true), payload);
    expect(
        await files
            .readStream('/compressed', gzip: true)
            .expand((chunk) => chunk)
            .toList(),
        payload);
    expect(requests, 3);
  });

  test('Web upload preparation buffers stream input and emits valid gzip',
      () async {
    final body = await web.prepareUpload(
        Stream<List<int>>.fromIterable([
          [0, 255],
          [1]
        ]),
        gzip: true);
    expect(body.streamed, isFalse);
    expect(io.gzip.decode(body.data as List<int>), [0, 255, 1]);
    final plain = await web.prepareUpload(Stream.value([0, 255]));
    expect(plain.streamed, isFalse);
    expect(plain.data, [0, 255]);
  });
  for (final version in ['0.5.6', '0.5.7']) {
    test('gzip implies octet upload only on supported envd $version', () async {
      final client = E2BClient(
          apiKey: 'key',
          httpClient: MockClient((r) async {
            if (r.url.host.startsWith('api.')) {
              return http.Response(
                  jsonEncode({'sandboxID': 's', 'envdVersion': version}), 200);
            }
            if (version == '0.5.7') {
              expect(r.headers['Content-Encoding'], 'gzip');
              expect(r.headers['Content-Type'], 'application/octet-stream');
              expect(io.gzip.decode(r.bodyBytes), utf8.encode('hello 中文'));
            } else {
              expect(r.headers['Content-Encoding'], isNull);
              expect(r.headers['Content-Type'],
                  startsWith('multipart/form-data;'));
              expect(utf8.decode(r.bodyBytes), contains('hello 中文'));
            }
            return http.Response('[{"path":"/a"}]', 200);
          }));
      final files = (await client.create()).files;
      await files.write('/a', 'hello 中文', gzip: true, useOctetStream: false);
    });
  }
  test('batch multipart omits path and applies metadata to every entry',
      () async {
    var uploads = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.host.startsWith('api.')) {
            return http.Response(
                '{"sandboxID":"s","envdVersion":"0.6.4"}', 200);
          }
          uploads++;
          expect(r.url.queryParameters.containsKey('path'), isFalse);
          expect(r.headers['X-Metadata-source'], 'test');
          expect(r.headers['Content-Type'], startsWith('multipart/form-data;'));
          expect(r.body, contains('name="file"; filename="/a"'));
          expect(r.body, contains('name="file"; filename="/b"'));
          return http.Response('[{"path":"/a"},{"path":"/b"}]', 200);
        }));
    final files = (await client.create()).files;
    final result = await files.writeFiles([
      const WriteEntry('/a', 'one'),
      const WriteEntry('/b', [2])
    ], metadata: {
      'source': 'test'
    });
    expect(result.map((e) => e.path), ['/a', '/b']);
    expect(await files.writeFiles([], metadata: {'invalid key': 'ignored'}),
        isEmpty);
    expect(uploads, 1);
  });
  test('batch octet uploads run concurrently and return input order', () async {
    final paths = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.host.startsWith('api.')) {
            return http.Response(
                '{"sandboxID":"s","envdVersion":"0.6.4"}', 200);
          }
          final path = r.url.queryParameters['path']!;
          paths.add(path);
          expect(r.headers['Content-Type'], 'application/octet-stream');
          if (path == '/a') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return http.Response(
              jsonEncode([
                {'path': path}
              ]),
              200);
        }));
    final files = (await client.create()).files;
    final result = await files.writeFiles([
      const WriteEntry('/a', 'one'),
      WriteEntry('/b', Stream.value([2]))
    ]);
    expect(result.map((e) => e.path), ['/a', '/b']);
    expect(paths, ['/a', '/b']);
  });
  test('metadata invalid characters and unsupported envd reject before upload',
      () async {
    var uploads = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.host.startsWith('api.')) {
            return http.Response(
                '{"sandboxID":"s","envdVersion":"0.6.1"}', 200);
          }
          uploads++;
          return http.Response('[]', 200);
        }));
    final files = (await client.create()).files;
    for (final metadata in [
      {'bad key': 'v'},
      {'': 'v'},
      {'key': '中文'},
      {'key': 'a\nb'}
    ]) {
      await expectLater(files.write('/a', 'data', metadata: metadata),
          throwsA(isA<InvalidArgumentException>()));
    }
    await expectLater(files.write('/a', 'data', metadata: {'key': 'valid'}),
        throwsA(isA<TemplateException>()));
    expect(uploads, 0);
  });
  for (final version in ['0.5.6', '0.5.7']) {
    test('streamed file upload selects supported transport for envd $version',
        () async {
      final client = E2BClient(
          apiKey: 'key',
          httpClient: MockClient((r) async {
            if (r.url.host.startsWith('api.')) {
              return http.Response(
                  jsonEncode({'sandboxID': 's', 'envdVersion': version}), 200);
            }
            if (version == '0.5.7') {
              expect(r.headers['Content-Type'], 'application/octet-stream');
              expect(r.bodyBytes, [0, 255, 1]);
            } else {
              expect(r.headers['Content-Type'],
                  startsWith('multipart/form-data;'));
              expect(r.bodyBytes, contains(255));
            }
            return http.Response(
                '[{"name":"a","path":"/a","type":"file"}]', 200);
          }));
      final sandbox = await client.create();
      final entry = await sandbox.files.write(
          '/a',
          Stream<List<int>>.fromIterable([
            [0],
            [255, 1]
          ]));
      expect(entry.type, FileType.file);
    });
  }
  test(
      'file content can be read as a byte stream with request timeout disabled',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        requestTimeout: Duration.zero,
        httpClient: MockClient((r) async {
          if (r.url.host.startsWith('api.')) {
            return http.Response(
                '{"sandboxID":"s","envdVersion":"0.6.4"}', 200);
          }
          return http.Response.bytes([0, 255, 1], 200);
        }));
    final sandbox = await client.create();
    final chunks = await sandbox.files.readStream('/a').toList();
    expect(chunks.expand((c) => c).toList(), [0, 255, 1]);
    expect(await sandbox.files.readBytes('/a'), [0, 255, 1]);
  });
  test('per-call canceled file request makes no network call', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          calls++;
          return http.Response('{"sandboxID":"s","envdVersion":"0.6.4"}', 200);
        }));
    final sandbox = await client.create();
    final signal = CancellationSignal()..cancel();
    await expectLater(
        sandbox.files
            .write('/a', 'data', options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    await expectLater(
        sandbox.files.readBytes('/a', options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    expect(calls, 1);
  });
  test('new symlink flag maps target type to SDK symlink type', () {
    final info = EntryInfo({'type': 'FILE_TYPE_FILE', 'isSymlink': true});
    expect(info.type, FileType.symlink);
    expect(FilesystemEvent({'type': 'EVENT_TYPE_RENAME'}).eventType,
        FilesystemEventType.rename);
  });
}
