import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, dynamic> sandboxData = {
  'sandboxID': 'sb-123',
  'envdVersion': '0.6.4',
  'domain': 'e2b.app',
  'envdAccessToken': 'envd-secret'
};
http.Response jsonResponse(Object value,
        [int status = 200, Map<String, String>? headers]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json', ...?headers});
List<int> endEnvelope() => envelope({})..[0] = 2;

void main() {
  test('health transport failures probe once and preserve original causes',
      () async {
    for (final scenario in ['stopped', 'running', 'unknown', 'unreachable']) {
      var requests = 0;
      final failure = http.ClientException('network error');
      final client = E2BClient(
          apiKey: 'key',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/connect')) {
              return jsonResponse(sandboxData);
            }
            requests++;
            if (requests == 1) throw failure;
            expect(requests, 2);
            if (scenario == 'unreachable') {
              throw http.ClientException('probe failed');
            }
            if (scenario == 'stopped') {
              return jsonResponse({'message': 'sandbox was not found'}, 502);
            }
            return http.Response('', scenario == 'running' ? 200 : 500);
          }));
      final sandbox = await client.connect('sb-123');
      try {
        if (scenario == 'stopped') {
          await expectLater(
              sandbox.isRunning(),
              throwsA(isA<SandboxNotRunningException>()
                  .having((e) => e.cause, 'cause', same(failure))));
        } else if (scenario == 'unreachable') {
          await expectLater(
              sandbox.isRunning(),
              throwsA(isA<SandboxUnreachableException>()
                  .having((e) => e.cause, 'cause', same(failure))));
        } else {
          await expectLater(sandbox.isRunning(), throwsA(same(failure)));
        }
        expect(requests, 2);
      } finally {
        client.close();
      }
    }
  });

  test('health logger and pre-canceled signal follow per-call options',
      () async {
    final bound = <List<Object?>>[];
    final local = <List<Object?>>[];
    var healthRequests = 0;
    final client = E2BClient(
        apiKey: 'key',
        logger: Logger(info: bound.add),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/connect')) {
            return jsonResponse(sandboxData);
          }
          healthRequests++;
          return http.Response('', 200, reasonPhrase: 'OK');
        }));
    addTearDown(client.close);
    final sandbox = await client.connect('sb-123');
    bound.clear();
    await sandbox.isRunning(
        options: RequestOptions(logger: Logger(info: local.add)));
    expect(local.first.single, contains('Request GET'));
    expect(local.last, ['Response:', 200, 'OK']);
    expect(bound, isEmpty);
    final signal = CancellationSignal();
    final reason = StateError('user canceled');
    signal.cancel(reason);
    await expectLater(
        sandbox.isRunning(options: RequestOptions(signal: signal)),
        throwsA(same(reason)));
    expect(healthRequests, 1);
    await sandbox.isRunning();
    expect(healthRequests, 2);
    expect(bound.last, ['Response:', 200, 'OK']);
  });

  test('health status errors use envd REST mapping and reason fallback',
      () async {
    var status = 200;
    String body = '';
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/connect')) {
            return jsonResponse(sandboxData);
          }
          expect(request.url.path, '/health');
          return http.Response(body, status,
              reasonPhrase: 'Fallback',
              headers: {'content-type': 'application/json'});
        }));
    addTearDown(client.close);
    final sandbox = await client.connect('sb-123');
    expect(await sandbox.isRunning(), isTrue);
    status = 502;
    body = 'unavailable';
    expect(await sandbox.isRunning(), isFalse);
    for (final entry in <(int, Type)>[
      (400, InvalidArgumentException),
      (401, AuthenticationException),
      (404, NotFoundException),
      (429, RateLimitException),
      (507, NotEnoughSpaceException),
      (500, SandboxException),
    ]) {
      status = entry.$1;
      for (final content in ['', '{"message":""}', '{"message":"detail"}']) {
        body = content;
        final message = content.contains('detail') ? 'detail' : 'Fallback';
        await expectLater(
            sandbox.isRunning(),
            throwsA(isA<E2BException>()
                .having((e) => e.runtimeType, 'type', entry.$2)
                .having(
                    (e) => e.message,
                    'message',
                    status == 429
                        ? '$message: The requests are being rate limited.'
                        : status == 500
                            ? '500: $message'
                            : message)));
      }
    }
  });

  test('Sandbox host formatting and unsecured URL diagnostic follow JS',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async => jsonResponse({
              'sandboxID': 'sb-123',
              'envdVersion': '0.6.4',
              'domain': 'e2b.app'
            })));
    addTearDown(client.close);
    final sandbox = await client.connect('sb-123');
    for (final entry in <(num, String)>[
      (0, '0'),
      (-1, '-1'),
      (65536, '65536'),
      (1.5, '1.5'),
      (-0.0, '0'),
      (double.infinity, 'Infinity'),
      (double.nan, 'NaN'),
    ]) {
      expect(sandbox.getHost(entry.$1), '${entry.$2}-sb-123.e2b.app');
      expect(ConnectionConfig(debug: true).getHost('sb', entry.$1),
          'localhost:${entry.$2}');
    }
    for (final action in [
      () => sandbox.uploadUrl(useSignatureExpiration: 0),
      () => sandbox.downloadUrl('/file', useSignatureExpiration: 0),
    ]) {
      expect(
          action,
          throwsA(isA<InvalidArgumentException>().having(
              (error) => error.message,
              'message',
              'Signature expiration can be used only when sandbox is created as secured.')));
    }
  });

  test('per-call routing resolves empty values and retains explicit API URLs',
      () async {
    final hosts = <String>[];
    final httpClient = MockClient((request) async {
      hosts.add(request.url.host);
      return http.Response('[]', 200);
    });
    final client = E2BClient(
        apiKey: 'key',
        domain: 'bound.test',
        apiUrl: Uri.parse('https://control.test'),
        httpClient: httpClient);
    addTearDown(client.close);
    await client.secrets
        .list(options: RequestOptions(domain: 'other.test'))
        .nextItems();
    await client.secrets.list(options: RequestOptions(debug: true)).nextItems();
    await client.secrets
        .list(
            options:
                RequestOptions(apiUrl: Uri.parse(''), domain: 'reset.test'))
        .nextItems();
    expect(hosts, ['control.test', 'control.test', 'api.reset.test']);
  });

  test(
      'derived routing retains explicit API URL across domain and debug changes',
      () {
    final client = E2BClient(
        apiKey: 'key',
        domain: 'bound.test',
        apiUrl: Uri.parse('https://control.test'));
    addTearDown(client.close);
    expect(client.withOptions(RequestOptions(domain: 'other.test')).apiUrl.host,
        'control.test');
    expect(client.withOptions(RequestOptions(debug: true)).apiUrl.host,
        'control.test');
    final defaults = E2BClient(apiKey: 'key', domain: 'bound.test');
    addTearDown(defaults.close);
    expect(
        defaults.withOptions(RequestOptions(domain: 'other.test')).apiUrl.host,
        'api.other.test');
    expect(defaults.withOptions(RequestOptions(debug: true)).apiUrl.toString(),
        'http://localhost:3000');
    final derived = defaults.withOptions(RequestOptions(headers: {}));
    expect(derived.config.explicitApiUrl, isNull);
    final changed = derived.withOptions(RequestOptions(domain: 'second.test'));
    expect(changed.apiUrl.host, 'api.second.test');
    expect(changed.config.explicitApiUrl, isNull);
    final local = changed.withOptions(RequestOptions(debug: true));
    expect(local.apiUrl.toString(), 'http://localhost:3000');
    expect(local.withOptions(RequestOptions(debug: false)).apiUrl.host,
        'api.second.test');
    expect(
        client
            .withOptions(RequestOptions(headers: {}))
            .withOptions(RequestOptions(domain: 'third.test', debug: true))
            .apiUrl
            .host,
        'control.test');
  });

  test('derived client replaces explicit headers and inherits omitted headers',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        headers: {'X-Bound': 'bound'},
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    for (final options in [
      RequestOptions(),
      RequestOptions(headers: {}),
      RequestOptions(apiHeaders: {'X-Call': 'call'})
    ]) {
      await client.withOptions(options).secrets.list().nextItems();
    }
    expect(requests[0].headers['X-Bound'], 'bound');
    expect(requests[1].headers['X-Bound'], isNull);
    expect(requests[2].headers['X-Bound'], isNull);
    expect(requests[2].headers['X-Call'], 'call');
    await client.secrets.list().nextItems();
    expect(requests.last.headers['X-Bound'], 'bound');
  });

  test('MCP token retries empty reads and caches a nonempty token', () async {
    var reads = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/connect')) {
            return jsonResponse(sandboxData);
          }
          expect(request.url.path, '/files');
          expect(
              request.url.queryParameters['path'], '/etc/mcp-gateway/.token');
          expect(request.url.queryParameters['username'], 'root');
          reads++;
          return http.Response(reads == 1 ? '' : 'token\n', 200);
        }));
    addTearDown(client.close);
    final sandbox = await client.connect('sb-123');
    expect(await sandbox.getMcpToken(), '');
    expect(await sandbox.getMcpToken(), 'token\n');
    expect(await sandbox.getMcpToken(), 'token\n');
    expect(reads, 2);
  });

  test('MCP chooses gateway template unless caller supplies one', () async {
    final templates = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          templates
              .add((jsonDecode(request.body) as Map)['templateID'] as String);
          return jsonResponse(
              {...sandboxData, 'domain': '', 'trafficAccessToken': ''});
        }));
    addTearDown(client.close);
    final plain = await client.create();
    final mcp = await client.create(mcp: {});
    await client.create(mcp: {}, template: 'custom');
    expect(templates, ['base', 'mcp-gateway', 'custom']);
    expect(plain.sandboxDomain, 'e2b.app');
    expect(mcp.trafficAccessToken, isNull);
  });

  test('connect maps a missing sandbox to its specific error', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async =>
            jsonResponse({'code': 404, 'message': 'missing sandbox'}, 404)));
    addTearDown(client.close);
    await expectLater(
        client.connect('missing'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.statusCode, 'status', 404)));
  });

  test('create kills incompatible envd before reporting template error',
      () async {
    final paths = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          paths.add('${request.method} ${request.url.path}');
          if (request.method == 'DELETE') return http.Response('', 204);
          return jsonResponse({...sandboxData, 'envdVersion': '0.0.9'});
        }));
    addTearDown(client.close);
    await expectLater(client.create(), throwsA(isA<TemplateException>()));
    expect(paths, ['POST /v2/sandboxes', 'DELETE /sandboxes/sb-123']);
  });

  test('debug lifecycle needs no API key and skips control plane', () async {
    final client = E2BClient(
        debug: true,
        httpClient: MockClient((request) async {
          expect(request.url.host, 'localhost');
          expect(request.url.port, 49983);
          expect(request.url.path, '/health');
          expect(request.headers.keys.map((s) => s.toLowerCase()),
              isNot(contains('x-api-key')));
          return http.Response('', 200);
        }));
    addTearDown(client.close);
    final created = await client.create();
    expect(created.sandboxId, 'debug_sandbox_id');
    expect(created.envdVersion, '99.99.99');
    final connected = await client.connect('local-id');
    expect(connected.sandboxId, 'local-id');
    expect(await connected.connect(), same(connected));
    await connected.setTimeout(Duration.zero);
    expect(await connected.kill(), true);
    expect(await client.kill('local-id'), true);
    expect(await connected.getMetrics(), isEmpty);
    expect(await connected.isRunning(), true);
  });

  test('per-call debug override creates local sandbox without mutating client',
      () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        debug: false,
        httpClient: MockClient((_) async {
          calls++;
          return jsonResponse(sandboxData);
        }));
    addTearDown(client.close);
    final local = await client.create(options: RequestOptions(debug: true));
    expect(local.sandboxId, 'debug_sandbox_id');
    expect(local.getHost(8080), 'localhost:8080');
    expect(calls, 0);
    expect(client.config.debug, false);
    expect((await client.create()).sandboxId, 'sb-123');
    expect(calls, 1);
  });

  test('debug hosts and deprecated key validation match official behavior',
      () async {
    final client = E2BClient(
        apiKey: 'custom-key-format',
        validateApiKey: true,
        debug: true,
        httpClient: MockClient((request) async {
          expect(request.url.host, 'localhost');
          expect(request.url.port, 3000);
          return jsonResponse(sandboxData);
        }));
    final sandbox = await client.connect('sb-123');
    expect(sandbox.getHost(8080), 'localhost:8080');
    final overridden =
        client.withOptions(RequestOptions(validateApiKey: false));
    expect(overridden.config.validateApiKey, false);
    expect(client.config.validateApiKey, true);
    // The official constructor accepts whitespace keys without format checks.
    final whitespaceKeyClient = E2BClient(apiKey: ' ', validateApiKey: true);
    addTearDown(whitespaceKeyClient.close);
    expect(whitespaceKeyClient.apiKey, ' ');
  });

  test('create serializes options and isolates control credentials', () async {
    final client = E2BClient(
        apiKey: 'control-secret',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            expect(request.url.path, '/v2/sandboxes');
            expect(request.headers['X-API-Key'], 'control-secret');
            expect(jsonDecode(request.body), containsPair('timeout', 2));
            expect(jsonDecode(request.body),
                containsPair('envVars', {'FOO': 'bar'}));
            return jsonResponse(sandboxData);
          }
          expect(request.headers.keys.map((e) => e.toLowerCase()),
              isNot(contains('x-api-key')));
          expect(request.headers['X-Access-Token'], 'envd-secret');
          expect(request.url.path, '/filesystem.Filesystem/Stat');
          expect(request.headers['Authorization'],
              'Basic ${base64Encode(utf8.encode('root:'))}');
          return jsonResponse({
            'entry': {
              'name': 'a',
              'path': '/a',
              'type': 'FILE_TYPE_FILE',
              'size': '9007199254740993'
            }
          });
        }));
    final sandbox = await client.create(
        timeout: const Duration(milliseconds: 1500), envs: {'FOO': 'bar'});
    expect(sandbox.getHost(8080), '8080-sb-123.e2b.app');
    expect((await sandbox.files.getInfo('/a', user: 'root')).size,
        9007199254740993);
  });

  test('connect resumes through v2 and timeout uses seconds', () async {
    final paths = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/connect')) {
            return jsonResponse(sandboxData);
          }
          expect(jsonDecode(request.body)['timeout'], 120);
          return http.Response('', 204);
        }));
    final sandbox = await client.connect('sb-123');
    await sandbox.setTimeout(const Duration(minutes: 2));
    expect(
        paths, ['/v2/sandboxes/sb-123/connect', '/sandboxes/sb-123/timeout']);
  });

  test('pagination follows response header and encodes metadata', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          calls++;
          if (calls == 1) {
            expect(request.url.queryParameters['metadata'], 'a%2520b=x%2526y');
            return jsonResponse(
                [sandboxData], 200, {'x-next-token': 'next +/&'});
          }
          expect(request.url.queryParameters['nextToken'], 'next +/&');
          return jsonResponse([sandboxData]);
        }));
    expect(await client.listAll(metadata: {'a b': 'x&y'}).length, 2);
    expect(calls, 2);
  });

  test('API errors and not-found semantics', () async {
    var status = 401;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async =>
            jsonResponse({'code': status, 'message': 'denied'}, status)));
    await expectLater(client.create(), throwsA(isA<AuthenticationException>()));
    status = 429;
    await expectLater(client.create(), throwsA(isA<RateLimitException>()));
    status = 404;
    expect(await client.kill('missing'), false);
  });

  test('file read and multipart upload preserve binary and paths', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            return jsonResponse(sandboxData);
          }
          expect(request.url.queryParameters['path'], '/tmp/a &中.bin');
          if (request.method == 'GET') {
            return http.Response.bytes([0, 255, 1], 200);
          }
          expect(request.headers['content-type'],
              startsWith('multipart/form-data; boundary='));
          expect(request.bodyBytes, contains(255));
          return jsonResponse([
            {'name': 'a', 'path': '/tmp/a &中.bin', 'type': 'FILE_TYPE_FILE'}
          ]);
        }));
    final sandbox = await client.create();
    expect(await sandbox.files.readBytes('/tmp/a &中.bin'), [0, 255, 1]);
    expect((await sandbox.files.write('/tmp/a &中.bin', [0, 255, 1])).path,
        '/tmp/a &中.bin');
  });

  test('filesystem only treats not_found as absence', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            return jsonResponse(sandboxData);
          }
          if (request.url.path.endsWith('MakeDir')) {
            return jsonResponse({'code': 'already_exists'}, 409);
          }
          return jsonResponse({'code': 'not_found'}, 404);
        }));
    final sandbox = await client.create();
    expect(await sandbox.files.exists('/missing'), false);
    expect(await sandbox.files.makeDir('/exists'), false);
  });

  test('commands decode split UTF-8 bytes and send real Connect request',
      () async {
    final bytes = utf8.encode('你好🌍');
    final callbacks = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            return jsonResponse(sandboxData);
          }
          expect(request.url.path, '/process.Process/Start');
          expect(request.headers['Content-Type'], 'application/connect+json');
          final body =
              jsonDecode(utf8.decode(request.bodyBytes.sublist(5))) as Map;
          expect(body['process']['args'], ['-l', '-c', 'echo hi']);
          return http.Response.bytes([
            ...envelope({
              'event': {
                'start': {'pid': 42}
              }
            }),
            for (final byte in bytes)
              ...envelope({
                'event': {
                  'data': {
                    'stdout': base64Encode([byte])
                  }
                }
              }),
            ...envelope({
              'event': {
                'data': {'stderr': base64Encode(utf8.encode('warning'))}
              }
            }),
            ...envelope({
              'event': {
                'end': {'exitCode': 0}
              }
            }),
            ...endEnvelope(),
          ], 200);
        }));
    final result = await (await client.create())
        .commands
        .run('echo hi', onStdout: callbacks.add);
    expect(result.pid, 42);
    expect(result.stdout, '你好🌍');
    expect(result.stderr, 'warning');
    expect(callbacks.join(), '你好🌍');
  });

  test('nonzero process exit retains stdout and stderr', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            return jsonResponse(sandboxData);
          }
          return http.Response.bytes([
            ...envelope({
              'event': {
                'start': {'pid': 1}
              }
            }),
            ...envelope({
              'event': {
                'data': {'stderr': base64Encode(utf8.encode('bad'))}
              }
            }),
            ...envelope({
              'event': {
                'end': {'exitCode': 7}
              }
            }),
            ...endEnvelope(),
          ], 200);
        }));
    final sandbox = await client.create();
    await expectLater(
        sandbox.commands.run('exit 7'),
        throwsA(isA<CommandExitException>()
            .having((e) => e.exitCode, 'exit code', 7)
            .having((e) => e.stderr, 'stderr', 'bad')));
  });

  test('command rejects premature EOF', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.host == 'api.e2b.app') {
            return jsonResponse(sandboxData);
          }
          return http.Response.bytes([
            ...envelope({
              'event': {
                'start': {'pid': 1}
              }
            }),
            ...endEnvelope()
          ], 200);
        }));
    final sandbox = await client.create();
    await expectLater(
        sandbox.commands.run('sleep'), throwsA(isA<E2BException>()));
  });

  test('client construction permits empty keys for environment fallback', () {
    final emptyKeyClient = E2BClient(apiKey: '');
    addTearDown(emptyKeyClient.close);
    final client = E2BClient(apiKey: 'key');
    addTearDown(client.close);
    expect(client.apiKey, 'key');
  });
}
