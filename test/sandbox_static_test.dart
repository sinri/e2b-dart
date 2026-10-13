import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('direct snapshot paginator retries failed cursor with per-call options',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final keys = <String?>[];
    var calls = 0;
    server.listen((request) async {
      keys.add(request.headers.value('x-api-key'));
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/sandboxes/sb') {
        request.response.write(jsonEncode({'sandboxID': 'sb'}));
      } else {
        expect(request.uri.path, '/snapshots');
        expect(request.uri.queryParameters,
            {'sandboxID': '', 'name': '', 'nextToken': 'initial'});
        calls++;
        if (calls == 1) {
          request.response.statusCode = 500;
          request.response.write(jsonEncode({'code': 500, 'message': 'retry'}));
        } else {
          request.response.write(jsonEncode([
            {'snapshotID': 'snap'}
          ]));
        }
      }
      await request.response.close();
    });
    final client = E2BClient(
        apiKey: 'bound-key',
        retries: 0,
        apiUrl: Uri.parse('http://localhost:${server.port}'));
    addTearDown(client.close);
    final pages = SnapshotPaginator(
        client: client, sandboxId: '', name: '', nextToken: 'initial');
    await expectLater(pages.nextItems(), throwsA(isA<SandboxException>()));
    expect(pages.nextToken, 'initial');
    expect(pages.hasNext, isTrue);
    final items =
        await pages.nextItems(options: RequestOptions(apiKey: 'override-key'));
    expect(items.single.names, isEmpty);
    expect(pages.nextToken, isNull);
    expect(pages.hasNext, isFalse);
    await expectLater(pages.nextItems(), throwsStateError);
    // ignore: deprecated_member_use_from_same_package
    expect((await Sandbox.getFullInfo('sb', client: client)).sandboxId, 'sb');
    await client.getInfo('sb');
    expect(keys, ['bound-key', 'override-key', 'bound-key', 'bound-key']);
    expect(calls, 2);
  });

  test('static metrics and snapshots coexist with instance operations',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final routes = <String>[];
    server.listen((request) async {
      routes.add('${request.method} ${request.uri.path}');
      expect(request.headers.value('x-api-key'), 'snapshot-key');
      request.response.headers.contentType = ContentType.json;
      Object body = {'sandboxID': 'sb', 'envdVersion': '0.6.4'};
      if (request.uri.path.endsWith('/metrics')) {
        expect(request.uri.queryParameters, {'start': '1', 'end': '2'});
        body = [];
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/snapshots')) {
        expect(jsonDecode(await utf8.decoder.bind(request).join()),
            {'name': 'named', 'memory': true});
        body = {
          'snapshotID': 'snap',
          'names': ['named']
        };
      } else if (request.uri.path == '/snapshots') {
        expect(request.uri.queryParameters,
            {'sandboxID': 'sb', 'name': 'named', 'limit': '2'});
        body = [
          {
            'snapshotID': 'snap',
            'names': ['named']
          }
        ];
      } else {
        await request.drain<void>();
      }
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final options = RequestOptions(
        apiKey: 'snapshot-key',
        retries: 0,
        apiUrl: Uri.parse('http://localhost:${server.port}'));
    final start = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    final end = DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true);
    expect(
        await Sandbox.getMetrics('sb',
            start: start, end: end, options: options),
        isEmpty);
    expect(
        (await Sandbox.createSnapshot('sb',
                name: 'named', mode: SnapshotMode.full, options: options))
            .snapshotId,
        'snap');
    final pages = Sandbox.listSnapshots(
        sandboxId: 'sb', name: 'named', limit: 2, options: options);
    expect(routes, hasLength(2));
    expect((await pages.nextItems()).single.snapshotId, 'snap');
    expect(pages.hasNext, isFalse);
    expect(await Sandbox.deleteSnapshot('snap', options: options), isTrue);
    final sandbox = await Sandbox.connect('sb', options: options);
    addTearDown(sandbox.close);
    await sandbox.getMetrics(start: start, end: end);
    await sandbox.createSnapshot(name: 'named', mode: SnapshotMode.full);
    await sandbox.listSnapshots(name: 'named', limit: 2).nextItems();
    expect(routes, [
      'GET /sandboxes/sb/metrics',
      'POST /sandboxes/sb/snapshots',
      'GET /snapshots',
      'DELETE /templates/snap',
      'POST /v2/sandboxes/sb/connect',
      'GET /sandboxes/sb/metrics',
      'POST /sandboxes/sb/snapshots',
      'GET /snapshots',
    ]);
  });

  test('static management methods preserve routes and injected ownership',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    final bodies = <String>[];
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      bodies.add(await utf8.decoder.bind(request).join());
      expect(request.headers.value('x-api-key'), 'manage-key');
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(jsonEncode({'sandboxID': 'sb', 'envdVersion': '0.6.4'}));
      await request.response.close();
    });
    final options = RequestOptions(
        apiKey: 'manage-key',
        retries: 0,
        apiUrl: Uri.parse('http://localhost:${server.port}'));
    expect((await Sandbox.getInfo('sb', options: options)).sandboxId, 'sb');
    expect(await Sandbox.kill('sb', options: options), isTrue);
    expect(await Sandbox.pause('sb', mode: SnapshotMode.full, options: options),
        isTrue);
    expect(await Sandbox.betaPause('sb', keepMemory: false, options: options),
        isTrue);
    await Sandbox.setTimeout('sb', const Duration(seconds: 90),
        options: options);
    await Sandbox.updateNetwork('sb', SandboxNetwork(), options: options);
    final client =
        E2BClient(apiKey: 'manage-key', retries: 0, apiUrl: options.apiUrl);
    addTearDown(client.close);
    await Sandbox.kill('sb', client: client);
    await client.getInfo('sb');
    final sandbox = await Sandbox.connect('sb', client: client);
    await sandbox.setTimeout(const Duration(seconds: 30));
    await sandbox.pause();
    await sandbox.betaPause();
    await sandbox.updateNetwork(SandboxNetwork());
    await sandbox.kill();
    expect(requests.take(6), [
      'GET /sandboxes/sb',
      'DELETE /sandboxes/sb',
      'POST /sandboxes/sb/pause',
      'POST /sandboxes/sb/pause',
      'POST /sandboxes/sb/timeout',
      'PUT /sandboxes/sb/network',
    ]);
    expect(jsonDecode(bodies[2]), {'memory': true});
    expect(jsonDecode(bodies[3]), {'memory': false});
    expect(jsonDecode(bodies[4]), {'timeout': 90});
    expect(requests.skip(8), [
      'POST /v2/sandboxes/sb/connect',
      'POST /sandboxes/sb/timeout',
      'POST /sandboxes/sb/pause',
      'POST /sandboxes/sb/pause',
      'PUT /sandboxes/sb/network',
      'DELETE /sandboxes/sb',
    ]);
  });

  test('static fork returns ordered handles and errors with shared ownership',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Object?>[];
    server.listen((request) async {
      expect(request.headers.value('x-api-key'), 'fork-key');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        expect(request.uri.path,
            anyOf('/sandboxes/source/fork', '/sandboxes/last/fork'));
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
        request.response.write(jsonEncode([
          {
            'sandbox': {'sandboxID': 'first', 'envdVersion': '0.6.4'}
          },
          {
            'error': {'code': 404, 'message': 'missing'}
          },
          {
            'sandbox': {'sandboxID': 'last', 'envdVersion': '0.6.4'}
          },
        ]));
      } else {
        request.response.write(jsonEncode({'sandboxID': 'last'}));
      }
      await request.response.close();
    });
    final results = await Sandbox.fork('source',
        count: 3,
        timeout: const Duration(seconds: 60),
        options: RequestOptions(
            apiKey: 'fork-key',
            retries: 0,
            apiUrl: Uri.parse('http://localhost:${server.port}')));
    expect(results, hasLength(3));
    final first = results.first as Sandbox;
    final last = results.last as Sandbox;
    addTearDown(first.close);
    addTearDown(last.close);
    expect(first.sandboxId, 'first');
    expect(results[1], isA<NotFoundException>());
    expect(last.sandboxId, 'last');
    expect(bodies.single, {'count': 3, 'timeout': 60});
    first.close();
    first.close();
    await last.getInfo();
    final nested = await last.fork(count: 3);
    expect(nested[0], isA<Sandbox>());
    expect(nested[1], isA<NotFoundException>());
    (nested.first as Sandbox).close();
    await last.getInfo();
    last.close();
    await expectLater(last.getInfo(), throwsStateError);
  });

  test('static Sandbox.list is lazy and preserves pagination options',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final queries = <Map<String, String>>[];
    server.listen((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/v2/sandboxes');
      expect(request.headers.value('x-api-key'), 'list-key');
      queries.add(request.uri.queryParameters);
      request.response.headers.contentType = ContentType.json;
      if (queries.length == 1) {
        request.response.headers.set('x-next-token', 'page-2');
      }
      request.response.write(jsonEncode([
        {'sandboxID': 'sb-${queries.length}', 'envdVersion': '0.6.4'}
      ]));
      await request.response.close();
    });
    final pages = Sandbox.list(
        limit: 2,
        nextToken: 'initial',
        state: ['running'],
        metadata: {'team': 'sdk'},
        template: 'base',
        startedAfter: DateTime.utc(2026, 1, 1),
        order: 'desc',
        options: RequestOptions(
            apiKey: 'list-key',
            retries: 0,
            apiUrl: Uri.parse('http://localhost:${server.port}')));
    expect(queries, isEmpty);
    expect(pages.hasNext, isTrue);
    expect((await pages.nextItems()).single.sandboxId, 'sb-1');
    expect(pages.nextToken, 'page-2');
    expect((await pages.nextItems()).single.sandboxId, 'sb-2');
    expect(pages.hasNext, isFalse);
    expect(queries.first, {
      'limit': '2',
      'nextToken': 'initial',
      'state': 'running',
      'metadata': 'team=sdk',
      'template': 'base',
      'startedAfter': '2026-01-01T00:00:00.000Z',
      'order': 'desc',
    });
    expect(queries.last, {...queries.first, 'nextToken': 'page-2'});
  });

  test('static Sandbox factories and instance reconnect coexist', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      expect(request.headers.value('x-api-key'), 'test-key');
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'sandboxID': 'sb-static',
        'envdVersion': '0.6.4',
        'domain': 'e2b.app',
      }));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final options = RequestOptions(
        apiKey: 'test-key',
        retries: 0,
        apiUrl: Uri.parse('http://localhost:${server.port}'));
    final sandbox = await Sandbox.create(template: 'base', options: options);
    addTearDown(sandbox.close);
    expect(sandbox.sandboxId, 'sb-static');
    expect(identical(await sandbox.connect(), sandbox), isTrue);
    await sandbox.getInfo();
    sandbox.close();
    sandbox.close();
    await expectLater(sandbox.getInfo(), throwsStateError);
    final connected = await Sandbox.connect('sb-static', options: options);
    addTearDown(connected.close);
    expect(connected.sandboxId, 'sb-static');
    connected.close();
    final client =
        E2BClient(apiKey: 'test-key', retries: 0, apiUrl: options.apiUrl);
    addTearDown(client.close);
    final injected = await Sandbox.connect('sb-static', client: client);
    injected.close();
    await injected.getInfo();
    expect(requests, [
      'POST /v2/sandboxes',
      'POST /v2/sandboxes/sb-static/connect',
      'GET /sandboxes/sb-static',
      'POST /v2/sandboxes/sb-static/connect',
      'POST /v2/sandboxes/sb-static/connect',
      'GET /sandboxes/sb-static',
    ]);
  });
}
