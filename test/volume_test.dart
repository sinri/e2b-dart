import 'dart:async';
import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:e2b/src/upload_body_web.dart' as web;

Map<String, dynamic> get entry => {
      'name': 'a',
      'path': '/a',
      'type': 'file',
      'size': 3,
      'mode': 420,
      'uid': 1000,
      'gid': 1000,
      'atime': '2026-10-12T00:00:00Z',
      'mtime': '2026-10-12T00:00:00Z',
      'ctime': '2026-10-12T00:00:00Z'
    };
http.Response json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});
Map<String, dynamic> get volume => {
      'volumeID': 'v',
      'name': 'data',
      'token': 'volume-only',
      'domain': 'byoc.test'
    };

class StreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  StreamClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  test('bound management headers stay separate from explicit content headers',
      () async {
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'management-key',
        headers: {'Legacy': 'management'},
        apiHeaders: {'Modern': 'management', 'Authorization': 'management'},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
              request.url.path == '/volumes'
                  ? jsonEncode({
                      'volumeID': 'v',
                      'name': 'name',
                      'token': 'content-token',
                      'domain': 'storage.test'
                    })
                  : 'text',
              200);
        }));
    addTearDown(client.close);
    final volume = await client.Volume.create('name');
    expect(requests.last.headers['Modern'], 'management');
    expect(requests.last.headers['Authorization'], 'management');
    expect(await volume.readFile('/a'), 'text');
    expect(requests.last.url.host, 'api.storage.test');
    expect(requests.last.headers['Authorization'], 'Bearer content-token');
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.headers['Modern'], isNull);
    expect(requests.last.headers['X-API-Key'], isNull);
    await volume.readFile('/a',
        options: VolumeRequestOptions(
            headers: {'Authorization': 'explicit', 'Content-Custom': 'yes'}));
    expect(requests.last.headers['Authorization'], 'explicit');
    expect(requests.last.headers['Content-Custom'], 'yes');
    await volume.readFile('/a');
    expect(requests.last.headers['Authorization'], 'Bearer content-token');
    expect(requests.last.headers['Content-Custom'], isNull);
  });

  test('volume write options preserve zero and false and omit absent values',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/volumes/v') return json(volume);
          requests.add(request);
          return json(entry);
        }));
    addTearDown(client.close);
    final vol = await client.volumes.connect('v');
    await vol.makeDir('/a');
    await vol.writeFile('/a', '');
    for (final request in requests) {
      expect(request.url.queryParameters, {'path': '/a'});
    }
    requests.clear();
    for (final force in [false, true]) {
      await vol.makeDir('/a', uid: 0, gid: 0, mode: 0, force: force);
      await vol.writeFile('/a', '', uid: 0, gid: 0, mode: 0, force: force);
      for (final request in requests) {
        expect(request.url.queryParameters, {
          'path': '/a',
          'uid': '0',
          'gid': '0',
          'mode': '0',
          'force': '$force'
        });
      }
      requests.clear();
    }
    await vol.updateMetadata('/a');
    expect(jsonDecode(requests.single.body), isEmpty);
  });

  test('volume text decoding matches fetch replacement and BOM behavior',
      () async {
    var bytes = <int>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async =>
            request.url.path == '/volumes/v'
                ? json(volume)
                : http.Response.bytes(bytes, 200)));
    addTearDown(client.close);
    final vol = await client.volumes.connect('v');
    for (final vector in <List<int>, String>{
      [255, 97]: '\uFFFDa',
      [226, 130]: '\uFFFD',
      [239, 187, 191, 97]: 'a',
      [192, 175]: '\uFFFD\uFFFD',
    }.entries) {
      bytes = vector.key;
      expect(await vol.readFile('/a'), vector.value);
      expect(await vol.readBytes('/a'), bytes);
    }
  });

  test('volume dates match JS UTC millisecond precision across the epoch', () {
    final info = VolumeEntryStat({
      ...entry,
      'atime': '2026-10-12T08:00:00.123456+08:00',
      'mtime': '1969-12-31T23:59:59.999999Z',
      'ctime': '2026-10-12T00:00:00.987654Z',
    });
    expect(info.atime.toIso8601String(), '2026-10-12T00:00:00.123Z');
    expect(info.mtime.toIso8601String(), '1969-12-31T23:59:59.999Z');
    expect(info.ctime.toIso8601String(), '2026-10-12T00:00:00.987Z');
  });

  test('volume empty overrides fall back and empty token omits authorization',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('abc', 200);
        }));
    addTearDown(client.close);
    final vol = Volume(client, VolumeAndToken(volume));
    await vol.readFile('/a',
        options:
            VolumeRequestOptions(domain: '', token: '', apiUrl: Uri.parse('')));
    expect(requests.last.url.host, 'api.byoc.test');
    expect(requests.last.headers['Authorization'], 'Bearer volume-only');
    await vol.readFile('/a',
        options: VolumeRequestOptions(
            domain: 'override.test', token: 'override-token'));
    expect(requests.last.url.host, 'api.override.test');
    expect(requests.last.headers['Authorization'], 'Bearer override-token');
    final anonymous = Volume(client, VolumeAndToken({...volume, 'token': ''}));
    await anonymous.readFile('/a');
    expect(requests.last.headers['Authorization'], isNull);
    await anonymous.readFile('/a',
        options: VolumeRequestOptions(headers: {'Authorization': 'custom'}));
    expect(requests.last.headers['Authorization'], 'custom');
  });

  test('volume operations report missing required response data', () async {
    var missingCreate = true;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/volumes' && !missingCreate) {
            return json(volume);
          }
          return http.Response('', 204);
        }));
    addTearDown(client.close);
    final missing = throwsA(isA<E2BException>()
        .having((e) => e.message, 'message', 'Response data is missing'));
    await expectLater(client.volumes.create('data'), missing);
    missingCreate = false;
    final vol = await client.volumes.create('data');
    await expectLater(vol.makeDir('/a'), missing);
    await expectLater(vol.getInfo('/a'), missing);
    await expectLater(vol.updateMetadata('/a', mode: 420), missing);
    await expectLater(vol.writeFile('/a', 'abc'), missing);
    // Empty bodies are valid for file reads and deletion.
    expect(await vol.readBytes('/a'), isEmpty);
    await vol.remove('/a');
  });

  test('browser volume upload preparation buffers byte streams', () async {
    final body = await web.prepareUpload(Stream<List<int>>.fromIterable([
      [0, 255],
      [1, 2]
    ]));
    expect(body.streamed, isFalse);
    expect(body.data, [0, 255, 1, 2]);
  });

  test('native volume stream upload ignores client request timeout', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.method == 'POST') return json(volume);
          expect(request.bodyBytes, [1, 2]);
          return json(entry);
        }));
    addTearDown(client.close);
    final vol = await client.volumes.create('data');
    final input = Stream<List<int>>.fromFuture(
        Future.delayed(const Duration(milliseconds: 50), () => [1, 2]));
    expect(
        (await vol.writeFile('/a', input,
                options: VolumeRequestOptions(
                    requestTimeout: const Duration(milliseconds: 1))))
            .path,
        '/a');
  });

  for (final value in <Object?>[
    null,
    {},
    {'message': ''},
    [1, null, 'x'],
    []
  ]) {
    test('volume error content conversion ${jsonEncode(value)}', () async {
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((request) async {
            if (request.method == 'POST') return json(volume);
            return http.Response(value == null ? '' : jsonEncode(value), 403,
                reasonPhrase: 'Forbidden');
          }));
      addTearDown(client.close);
      final vol = await client.volumes.create('data');
      final detail = value == null
          ? 'Forbidden'
          : value is Map
              ? '[object Object]'
              : (value as List).isEmpty
                  ? ''
                  : '1,,x';
      final matcher = isA<VolumeException>()
          .having((e) => e.message, 'message', '403: $detail');
      await expectLater(client.volumes.list(), throwsA(matcher));
      await expectLater(vol.readFile('/a'), throwsA(matcher));
      await expectLater(vol.readStream('/a').toList(), throwsA(matcher));
    });
  }

  for (final status in [400, 401, 403, 429, 500, 503]) {
    test('volume management and content error mapping status=$status',
        () async {
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((request) async {
            if (request.method == 'POST') return json(volume);
            return json(
                {'message': 'detail', 'code': 'permission_denied'}, status);
          }));
      addTearDown(client.close);
      final vol = await client.volumes.create('data');
      final String message;
      final Type type;
      switch (status) {
        case 401:
          message = 'Unauthorized, please check your credentials. - detail';
          type = AuthenticationException;
        case 429:
          message = 'Rate limit exceeded, please try again later - detail';
          type = RateLimitException;
        case 503:
          message = 'Service temporarily unavailable, please retry - detail';
          type = ServiceBusyException;
        default:
          message = '$status: detail';
          type = VolumeException;
      }
      final matcher = isA<E2BException>()
          .having((e) => e.runtimeType, 'type', type)
          .having((e) => e.message, 'message', message);
      await expectLater(client.volumes.list(), throwsA(matcher));
      await expectLater(vol.readFile('/a'), throwsA(matcher));
      await expectLater(vol.readStream('/a').toList(), throwsA(matcher));
    });
  }

  test('volume listing tolerates missing data and empty domain falls back',
      () async {
    var listing = false;
    final client = E2BClient(
        apiKey: 'key',
        domain: 'custom.test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/volumes' && request.method == 'POST') {
            return json({...volume, 'domain': ''});
          }
          if (request.url.path == '/volumes') return http.Response('', 204);
          expect(request.url.host, 'api.custom.test');
          if (listing) return json({'unexpected': true});
          return http.Response('', 204);
        }));
    addTearDown(client.close);
    final vol = await client.volumes.create('data');
    expect(await client.volumes.list(), isEmpty);
    expect(await vol.list('/'), isEmpty);
    listing = true;
    expect(await vol.list('/'), isEmpty);
  });

  test('volume content metadata and per-call logger match API middleware',
      () async {
    final logs = <List<Object?>>[];
    var boundLogs = 0;
    final client = E2BClient(
        apiKey: 'key',
        logger: Logger(info: (_) => boundLogs++),
        httpClient: MockClient((request) async {
          if (request.url.path == '/volumes') return json(volume);
          expect(request.headers['lang'], 'dart');
          expect(request.headers['publisher'], 'custom');
          expect(request.headers['package_version'], '0.1.0');
          return http.Response('abc', 200, reasonPhrase: 'OK');
        }));
    addTearDown(client.close);
    final vol = await client.volumes.create('data');
    final managementLogs = boundLogs;
    final options = VolumeRequestOptions(
        headers: {'publisher': 'custom'},
        logger: Logger(info: logs.add, error: logs.add));
    expect(await vol.readFile('/a', options: options), 'abc');
    expect(
        await vol
            .readStream('/a', options: options)
            .expand((bytes) => bytes)
            .toList(),
        utf8.encode('abc'));
    expect(boundLogs, managementLogs);
    expect(logs, [
      ['Request GET https://api.byoc.test/volumecontent/v/file?path=%2Fa'],
      ['Response:', 200, 'OK'],
      ['Request GET https://api.byoc.test/volumecontent/v/file?path=%2Fa'],
      ['Response:', 200, 'OK'],
    ]);
  });

  test('volume debug mode inherits create/connect and allows false override',
      () async {
    final urls = <Uri>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/volumes' ||
              request.url.path == '/volumes/v') {
            return json(volume);
          }
          urls.add(request.url);
          return json(entry);
        }));
    addTearDown(client.close);
    final created = await client.volumes
        .create('data', options: RequestOptions(debug: true));
    expect(created.debug, isTrue);
    await created.getInfo('/a');
    await created.getInfo('/a', options: VolumeRequestOptions(debug: false));
    final connected =
        await client.volumes.connect('v', options: RequestOptions(debug: true));
    await connected.getInfo('/a');
    await connected.getInfo('/a',
        options: VolumeRequestOptions(
            debug: true, apiUrl: Uri.parse('https://explicit.test')));
    expect(urls.map((url) => url.origin), [
      'http://localhost:8080',
      'https://api.byoc.test',
      'http://localhost:8080',
      'https://explicit.test',
    ]);
  });

  test('volume CRUD and BYOC content credentials stay isolated', () async {
    final client = E2BClient(
        apiKey: 'management-only',
        httpClient: MockClient((r) async {
          if (r.url.host == 'api.e2b.app') {
            expect(r.headers['X-API-Key'], 'management-only');
            if (r.method == 'POST') {
              expect(jsonDecode(r.body), {'name': 'data'});
            }
            if (r.method == 'DELETE') return http.Response('', 204);
            if (r.method == 'GET' && r.url.path == '/volumes') {
              return json([volume]);
            }
            return json(volume);
          }
          expect(r.url.host, 'api.byoc.test');
          expect(r.url.path, '/volumecontent/v/path');
          expect(r.headers['Authorization'], 'Bearer volume-only');
          expect(r.headers.keys.map((k) => k.toLowerCase()),
              isNot(contains('x-api-key')));
          return json(entry);
        }));
    final created = await client.volumes.create('data');
    expect(created.name, 'data');
    expect((await created.getInfo('/a')).mtime.isUtc, true);
    expect((await client.volumes.connect('v')).token, 'volume-only');
    expect((await client.volumes.list()).single.volumeId, 'v');
    expect(await client.volumes.destroy('v'), true);
  });

  test(
      'volume list, directory creation, metadata and remove use content schema',
      () async {
    final paths = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.path == '/volumes') return json(volume);
          paths.add('${r.method} ${r.url.path}');
          expect(r.url.queryParameters['path'], '/a');
          if (r.method == 'GET') {
            expect(r.url.queryParameters['depth'], '2');
            return json([entry]);
          }
          if (r.method == 'POST') {
            expect(r.url.queryParameters, {
              'path': '/a',
              'uid': '0',
              'gid': '1',
              'mode': '493',
              'force': 'false'
            });
          }
          if (r.method == 'PATCH') {
            expect(jsonDecode(r.body), {'uid': 0, 'mode': 384});
          }
          if (r.method == 'DELETE') return http.Response('', 204);
          return json(entry);
        }));
    final vol = await client.volumes.create('data');
    expect((await vol.list('/a', depth: 2)).single.type, VolumeFileType.file);
    await vol.makeDir('/a', uid: 0, gid: 1, mode: 493, force: false);
    await vol.updateMetadata('/a', uid: 0, mode: 384);
    await vol.remove('/a');
    expect(paths, [
      'GET /volumecontent/v/dir',
      'POST /volumecontent/v/dir',
      'PATCH /volumecontent/v/path',
      'DELETE /volumecontent/v/path'
    ]);
  });

  test('volume binary and streamed writes are sent as raw octets', () async {
    final uploads = <List<int>>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.path == '/volumes') return json(volume);
          expect(r.url.path, '/volumecontent/v/file');
          if (r.method == 'GET') return http.Response.bytes([0, 255, 1], 200);
          expect(r.headers['Content-Type'], 'application/octet-stream');
          uploads.add(r.bodyBytes);
          return json(entry);
        }));
    final vol = await client.volumes.create('data');
    expect(await vol.readBytes('/a'), [0, 255, 1]);
    await vol.writeFile('/a', [0, 255, 1]);
    await vol.writeFile(
        '/a',
        Stream<List<int>>.fromIterable([
          [0],
          [255, 1]
        ]));
    expect(uploads, [
      [0, 255, 1],
      [0, 255, 1]
    ]);
  });

  test('volume and path not-found classes are distinct', () async {
    var missingVolume = false;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async =>
            r.url.path == '/volumes/v' && !missingVolume
                ? json(volume)
                : json({'message': 'missing'}, 404)));
    final vol = await client.volumes.connect('v');
    expect(await vol.exists('/gone'), false);
    await expectLater(
        vol.readBytes('/gone'),
        throwsA(isA<VolumePathNotFoundException>()
            .having((e) => e.message, 'message', 'Path /gone not found')));
    await expectLater(
        vol.readStream('/gone').toList(),
        throwsA(isA<VolumePathNotFoundException>()
            .having((e) => e.message, 'message', 'Path /gone not found')));
    missingVolume = true;
    await expectLater(
        client.volumes.getInfo('v'),
        throwsA(isA<VolumeNotFoundException>()
            .having((e) => e.message, 'message', 'Volume v not found')));
    expect(await client.volumes.destroy('v'), false);
  });

  test('volume file reads allow cancellation and release idle connections',
      () async {
    var canceled = false;
    final source = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final client = E2BClient(
        apiKey: 'key',
        httpClient: StreamClient((r) async {
          if (r.url.path == '/volumes') {
            return http.StreamedResponse(
                Stream.value(utf8.encode(jsonEncode(volume))), 200);
          }
          return http.StreamedResponse(source.stream, 200);
        }));
    final vol = await client.volumes.create('data');
    await expectLater(
        vol
            .readStream('/a', idleTimeout: const Duration(milliseconds: 20))
            .toList(),
        throwsA(isA<TimeoutException>()));
    expect(canceled, true);
    await source.close();
  });

  test('volume stream cancellation works while server produces no bytes',
      () async {
    var canceled = false;
    final source = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final ready = Completer<void>();
    final client = E2BClient(
        apiKey: 'key',
        httpClient: StreamClient((r) async {
          if (r.url.path == '/volumes') {
            return http.StreamedResponse(
                Stream.value(utf8.encode(jsonEncode(volume))), 200);
          }
          ready.complete();
          return http.StreamedResponse(source.stream, 200);
        }));
    final vol = await client.volumes.create('data');
    final subscription = vol.readStream('/a').listen((_) {});
    await ready.future;
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(canceled, true);
    await source.close();
  });

  test('Volume object can be used as a sandbox mount', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.url.path == '/volumes') return json(volume);
          expect(jsonDecode(r.body)['volumeMounts'], [
            {'path': '/mnt/data', 'name': 'data'}
          ]);
          return json({'sandboxID': 's', 'envdVersion': '0.6.4'});
        }));
    final vol = await client.volumes.create('data');
    await client.create(volumeMounts: {'/mnt/data': vol});
  });
}
