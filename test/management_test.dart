import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response json(Object value,
        [int status = 200, Map<String, String>? headers]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json', ...?headers});
Map<String, dynamic> get sandboxResponse =>
    {'sandboxID': 'sb', 'envdVersion': '0.6.4', 'envdAccessToken': 'token'};
Map<String, dynamic> secretResponse([int version = 1]) => {
      'secretID': 'secret-id',
      'name': 'api-key',
      'currentVersion': version,
      'createdAt': '2026-10-12T00:00:00Z',
      'updatedAt': '2026-10-12T01:00:00Z',
      'metadata': {'a': 'b'}
    };

void main() {
  test('create accepts ignored secure option and converts timeout like JS',
      () async {
    final bodies = <Map>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map);
          return json(sandboxResponse);
        }));
    addTearDown(client.close);
    for (final secure in <bool?>[null, false, true]) {
      await client.create(secure: secure);
      expect(bodies.last, {'templateID': 'base'});
    }
    for (final entry in <int, int>{
      -1501: -1,
      -1000: -1,
      -1: 0,
      0: 0,
      1: 1,
      1001: 2
    }.entries) {
      await client.create(timeout: Duration(milliseconds: entry.key));
      expect(bodies.last['timeout'], entry.value);
    }
  });

  test('create omits API-owned defaults but preserves explicit empty options',
      () async {
    final bodies = <Map>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map);
          return json(sandboxResponse);
        }));
    addTearDown(client.close);
    await client.create();
    expect(bodies.single, {'templateID': 'base'});
    await client.create(
        timeout: Duration.zero,
        metadata: {},
        envs: {},
        allowInternetAccess: false,
        volumeMounts: {});
    expect(bodies.last, {
      'templateID': 'base',
      'timeout': 0,
      'metadata': {},
      'envVars': {},
      'allow_internet_access': false,
      'volumeMounts': []
    });
  });

  test(
      'create API fallback and fork empty special errors match official messages',
      () async {
    var status = 403;
    Object payload = {'message': 'denied'};
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => json(payload, status)));
    addTearDown(client.close);
    for (final code in [400, 403, 404, 409, 500]) {
      status = code;
      await expectLater(
          client.create(),
          throwsA(isA<SandboxException>()
              .having((e) => e.message, 'message', '$code: denied')));
    }
    status = 200;
    payload = [
      for (final code in [401, 429, 503])
        {
          'error': {'code': code, 'message': null}
        }
    ];
    final results = await client.fork('sb');
    expect(results.map((e) => e.error!.message), [
      'Unauthorized, please check your credentials.',
      'Rate limit exceeded, please try again later',
      'Service temporarily unavailable, please retry'
    ]);
  });

  test('fork uses HTTP404 for source and typed errors for individual results',
      () async {
    var status = 404;
    Object? payload;
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => payload == null
            ? http.Response('', status)
            : json(payload, status)));
    addTearDown(client.close);
    await expectLater(
        client.fork('sb'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.message, 'message', 'Sandbox sb not found')));
    payload = {'message': ''};
    await expectLater(
        client.fork('sb'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.message, 'message', '')));
    status = 204;
    payload = null;
    expect(await client.fork('sb'), isEmpty);
    status = 200;
    payload = [
      {},
      {
        'error': {'code': 403, 'message': 'denied'}
      },
      {
        'error': {'code': 404, 'message': 'snapshot'}
      },
      {
        'error': {'code': 429, 'message': 'limit'}
      }
    ];
    final results = await client.fork('sb');
    expect(
        results[0].error,
        isA<SandboxException>().having(
            (e) => e.message, 'message', 'Failed to start forked sandbox'));
    expect(
        results[1].error,
        isA<SandboxException>()
            .having((e) => e.message, 'message', '403: denied'));
    expect(
        results[2].error,
        isA<NotFoundException>()
            .having((e) => e.message, 'message', '404: snapshot'));
    expect(
        results[3].error,
        isA<RateLimitException>().having((e) => e.message, 'message',
            'Rate limit exceeded, please try again later - limit'));
  });

  test('delete methods return false only for numeric response code404',
      () async {
    for (final snapshot in [false, true]) {
      var status = 404;
      Object? payload = {'message': 'missing'};
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((_) async => payload == null
              ? http.Response('', status)
              : json(payload, status)));
      addTearDown(client.close);
      Future<bool> invoke() =>
          snapshot ? client.deleteSnapshot('id') : client.kill('id');
      await expectLater(invoke(), throwsA(isA<SandboxException>()));
      payload = {'code': '404'};
      await expectLater(invoke(), throwsA(isA<SandboxException>()));
      payload = null;
      await expectLater(invoke(), throwsA(isA<SandboxException>()));
      payload = {'code': 404};
      expect(await invoke(), isFalse);
      status = 204;
      payload = null;
      expect(await invoke(), isTrue);
    }
  });

  test('connect and info distinguish code404 and missing info data', () async {
    var status = 404;
    Object? payload = {'message': 'detail'};
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => payload == null
            ? http.Response('', status)
            : json(payload, status)));
    addTearDown(client.close);
    for (final connect in [false, true]) {
      Future<Object> invoke() =>
          connect ? client.connect('sb') : client.getInfo('sb');
      payload = {'message': 'detail'};
      await expectLater(
          invoke(),
          throwsA(isA<SandboxException>()
              .having((e) => e.message, 'message', '404: detail')));
      payload = {'code': 404};
      await expectLater(
          invoke(),
          throwsA(isA<SandboxNotFoundException>().having(
              (e) => e.message,
              'message',
              connect
                  ? 'Paused sandbox sb not found'
                  : 'Sandbox sb not found')));
    }
    status = 204;
    payload = null;
    await expectLater(
        client.getInfo('sb'),
        throwsA(isA<E2BException>()
            .having((e) => e.message, 'message', 'Sandbox not found')));
  });

  test('pause requires numeric response code for already-paused handling',
      () async {
    Object? payload = {'message': 'conflict'};
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async =>
            payload == null ? http.Response('', 409) : json(payload, 409)));
    addTearDown(client.close);
    await expectLater(
        client.pause('sb'),
        throwsA(isA<SandboxException>()
            .having((e) => e.message, 'message', '409: conflict')));
    payload = {'code': '409', 'message': 'conflict'};
    await expectLater(client.pause('sb'), throwsA(isA<SandboxException>()));
    payload = null;
    await expectLater(client.pause('sb'), throwsA(isA<SandboxException>()));
    payload = {'code': 409};
    expect(await client.pause('sb'), isFalse);
    payload = {'code': 404};
    await expectLater(
        client.pause('sb'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.message, 'message', 'Sandbox sb not found')));
  });

  test('timeout and network updates share official single-sandbox errors',
      () async {
    for (final network in [false, true]) {
      var status = 404;
      Object payload = {'message': 'detail'};
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((request) async {
            expect(request.method, network ? 'PUT' : 'POST');
            expect(request.url.path,
                '/sandboxes/sb/${network ? 'network' : 'timeout'}');
            return json(payload, status);
          }));
      addTearDown(client.close);
      Future<void> invoke() => network
          ? client.updateNetwork('sb', SandboxNetwork())
          : client.setTimeout('sb', const Duration(seconds: 5));
      for (final code in [400, 403, 404, 409, 500]) {
        status = code;
        await expectLater(
            invoke(),
            throwsA(isA<SandboxException>()
                .having((e) => e.message, 'message', '$code: detail')));
      }
      status = 404;
      payload = {'code': 404, 'message': 'ignored'};
      await expectLater(
          invoke(),
          throwsA(isA<SandboxNotFoundException>()
              .having((e) => e.message, 'message', 'Sandbox sb not found')));
    }
  });

  test('snapshot errors follow official resource status and code branches',
      () async {
    var status = 400;
    Object payload = {'message': 'detail'};
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => json(payload, status)));
    addTearDown(client.close);
    for (final code in [400, 403, 404, 409, 500]) {
      status = code;
      await expectLater(
          client.createSnapshot('source'),
          throwsA(isA<SandboxException>()
              .having((e) => e.message, 'message', '$code: detail')
              .having((e) => e.statusCode, 'status', code)));
    }
    payload = {'code': 404, 'message': 'ignored'};
    status = 404;
    await expectLater(
        client.createSnapshot('source'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.message, 'message', 'Sandbox source not found')));
    payload = {'message': 'detail'};
    status = 429;
    await expectLater(
        client.createSnapshot('source'),
        throwsA(isA<RateLimitException>().having((e) => e.message, 'message',
            'Rate limit exceeded, please try again later - detail')));
  });

  test('metrics errors distinguish API code 404 from HTTP status', () async {
    var status = 404;
    Object? payload = {'message': 'missing'};
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => payload == null
            ? http.Response('', status)
            : json(payload, status)));
    addTearDown(client.close);
    await expectLater(
        client.getMetrics('sb'),
        throwsA(isA<SandboxException>()
            .having((e) => e.message, 'message', '404: missing')));
    payload = {'code': 404, 'message': 'server text'};
    await expectLater(
        client.getMetrics('sb'),
        throwsA(isA<SandboxNotFoundException>()
            .having((e) => e.message, 'message', 'Sandbox sb not found')));
    status = 403;
    payload = {'message': 'forbidden'};
    await expectLater(
        client.getMetrics('sb'),
        throwsA(isA<SandboxException>()
            .having((e) => e.message, 'message', '403: forbidden')));
    status = 401;
    payload = null;
    await expectLater(
        client.getMetrics('sb'),
        throwsA(isA<AuthenticationException>().having((e) => e.message,
            'message', 'Unauthorized, please check your credentials.')));
  });

  test('metrics match JS rounding around epoch and accept empty success',
      () async {
    final times = <int, int>{
      -1501: -2,
      -1500: -1,
      -1499: -1,
      -501: -1,
      -500: 0,
      -499: 0,
      499: 0,
      500: 1,
      501: 1
    };
    int? expected;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/sandboxes/sb/metrics');
          expect(
              request.url.queryParameters,
              expected == null
                  ? isEmpty
                  : {'start': '$expected', 'end': '$expected'});
          return http.Response('', 204);
        }));
    addTearDown(client.close);
    for (final entry in times.entries) {
      expected = entry.value;
      final date = DateTime.fromMillisecondsSinceEpoch(entry.key, isUtc: true);
      expect(await client.getMetrics('sb', start: date, end: date), isEmpty);
    }
    expected = null;
    expect(await client.getMetrics('sb'), isEmpty);
  });

  test(
      'betaPause forwards legacy memory and pause conflict rejects before HTTP',
      () async {
    final bodies = <Object?>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          bodies.add(jsonDecode(r.body));
          return http.Response('', 204);
        }));
    for (final memory in [false, true]) {
      expect(await client.betaPause('sb', keepMemory: memory), isTrue);
      expect(bodies.last, {'memory': memory});
    }
    await expectLater(
        client.pause('sb', mode: SnapshotMode.full, keepMemory: true),
        throwsA(isA<InvalidArgumentException>().having(
            (e) => e.message,
            'message',
            'Pass either mode or the deprecated keepMemory, not both.')));
    expect(bodies, hasLength(2));
    client.close();
  });

  test(
      'secret timestamps match JS UTC millisecond precision and metadata default',
      () {
    final data = secretResponse()..remove('metadata');
    data['createdAt'] = '2026-10-12T08:00:00.123456+08:00';
    data['updatedAt'] = '2026-10-12T00:00:00.987654Z';
    final info = SecretInfo(data);
    expect(info.metadata, isEmpty);
    expect(info.createdAt.toIso8601String(), '2026-10-12T00:00:00.123Z');
    expect(info.updatedAt.toIso8601String(), '2026-10-12T00:00:00.987Z');
  });

  test('secret placeholder validation preserves official error message', () {
    for (final name in ['', '{bad}', 'a\n', '\u0085']) {
      expect(
          () => Secret.fill(name),
          throwsA(isA<InvalidArgumentException>().having(
              (e) => e.message,
              'message',
              "secret name ${jsonEncode(name)} is not usable: a secret name cannot be empty or contain '{', '}' or control characters, because it is interpolated into the '\${e2b.secrets.<name>}' placeholder the runtime resolves.")));
    }
    expect(Secret.fill('a.b 空格'), r'${e2b.secrets.a.b 空格}');
  });

  test('Secret CRUD, metadata replacement, and write-only models', () async {
    final seen = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          seen.add(r);
          if (r.method == 'DELETE') return http.Response('', 204);
          return json(secretResponse(r.url.path == '/secrets' ? 1 : 2));
        }));
    final created = await client.secrets
        .create('api-key', 'secret-value', metadata: {'a': 'b'});
    expect(created.secretId, 'secret-id');
    expect(created.version, 1);
    expect(jsonDecode(seen.first.body), {
      'name': 'api-key',
      'value': 'secret-value',
      'metadata': {'a': 'b'}
    });
    final updated =
        await client.secrets.update('api-key', 'new-value', metadata: {});
    expect(updated.version, 2);
    expect(jsonDecode(seen[1].body)['metadata'], isEmpty);
    expect((await client.secrets.getInfo('api-key')).metadata, {'a': 'b'});
    expect(await client.secrets.destroy('api-key'), true);
  });

  test('Secret not-found semantics and path encoding', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          expect(r.url.pathSegments.last, 'name/a b');
          return json({'message': 'gone'}, 404);
        }));
    await expectLater(client.secrets.getInfo('name/a b'),
        throwsA(isA<SecretNotFoundException>()));
    expect(await client.secrets.exists('name/a b'), false);
    expect(await client.secrets.destroy('name/a b'), false);
  });

  test('Secret paginator consumes cursor only on successful pages', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          calls++;
          if (calls == 1) {
            return json([secretResponse()], 200, {'x-next-token': 'page2'});
          }
          expect(r.url.queryParameters['nextToken'], 'page2');
          if (calls == 2) return json({'message': 'slow down'}, 429);
          return json([secretResponse(2)]);
        }));
    final paginator = client.secrets.list(limit: 1);
    expect((await paginator.nextItems()).single.version, 1);
    await expectLater(
        paginator.nextItems(), throwsA(isA<RateLimitException>()));
    expect(paginator.hasNext, true);
    expect((await paginator.nextItems()).single.version, 2);
    expect(paginator.hasNext, false);
    await expectLater(paginator.nextItems(), throwsStateError);
  });

  test('placeholder grammar handles Unicode and rejects all control ranges',
      () {
    expect(Secret.fill('密钥-key'), r'${e2b.secrets.密钥-key}');
    for (final value in ['', '{x}', 'a\n', 'a\u007f', 'a\u0085', 'a\u009f']) {
      expect(
          () => Secret.fill(value), throwsA(isA<InvalidArgumentException>()));
      expect(
          () => SandboxIam(tokens: {
                value: const IamToken(audience: 'a', tokenType: 'JWT-SVID')
              }).toJson(),
          throwsA(isA<InvalidArgumentException>()));
    }
  });

  test('create materializes network selectors and validates IAM placeholders',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          final body = jsonDecode(r.body);
          expect(body['iam'], {
            'tokens': {
              'aws': {'audience': 'sts.amazonaws.com', 'tokenType': 'JWT-SVID'}
            }
          });
          expect(body['network'], {
            'allowOut': ['api.example.com'],
            'denyOut': [allTraffic],
            'rules': {
              'api.example.com': [
                {
                  'transform': {
                    'headers': {
                      'Authorization': r'Bearer ${e2b.identity.tokens.aws}'
                    }
                  }
                }
              ]
            },
            'egressProxy': {
              'address': 'proxy:1080',
              'username': 'u',
              'password': 'p'
            },
            'allowPublicTraffic': false,
            'httpsPorts': [443],
          });
          return json(sandboxResponse);
        }));
    await client.create(
        iam: SandboxIam(tokens: {
          'aws': Secret.iamToken(
              audience: 'sts.amazonaws.com', tokenType: 'JWT-SVID')
        }),
        network: SandboxNetwork(
            allowOutResolver: (ctx) => ctx.rules.keys.toList(),
            denyOutResolver: (ctx) => [ctx.allTraffic],
            rules: {
              'api.example.com': [
                NetworkRule(
                    transform: (ctx) =>
                        {'Authorization': 'Bearer ${ctx.tokens['aws']}'})
              ]
            },
            egressProxy: const EgressProxy(
                address: 'proxy:1080', username: 'u', password: 'p'),
            allowPublicTraffic: false,
            httpsPorts: [443]));
    await expectLater(
        client.create(
            network: SandboxNetwork(rules: {
          'api.example.com': [
            NetworkRule(
                transform: (ctx) => {'Authorization': ctx.tokens['unknown']})
          ]
        })),
        throwsA(isA<InvalidArgumentException>()));
  });

  test('network update accepts unknown token references and replaces config',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          expect(r.method, 'PUT');
          expect(r.url.path, '/sandboxes/sb/network');
          expect(jsonDecode(r.body), {
            'rules': {
              'host': [
                {
                  'transform': {
                    'headers': {'X-Token': r'${e2b.identity.tokens.any}'}
                  }
                }
              ]
            },
            'allow_internet_access': false
          });
          return http.Response('', 204);
        }));
    await client.updateNetwork(
        'sb',
        SandboxNetwork(allowInternetAccess: false, rules: {
          'host': [
            NetworkRule(transform: (ctx) => {'X-Token': ctx.tokens['any']})
          ]
        }));
  });

  test(
      'lifecycle fields preserve unspecified defaults and reject invalid mixes',
      () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          final body = jsonDecode(r.body) as Map;
          if (calls++ == 0) {
            expect(body.containsKey('autoPause'), false);
            expect(body.containsKey('autoResume'), false);
          } else {
            expect(body['autoPause'], true);
            expect(body['autoPauseMemory'], false);
            expect(body['autoResume'], {'enabled': false});
          }
          return json(sandboxResponse);
        }));
    await client.create();
    await client.create(
        lifecycle: const SandboxLifecycle(
            onTimeout: TimeoutAction.pause,
            mode: SnapshotMode.filesystem,
            autoResume: false));
    await expectLater(
        client.create(
            lifecycle: const SandboxLifecycle(
                onTimeout: TimeoutAction.kill, autoResume: true)),
        throwsA(isA<InvalidArgumentException>()));
    await expectLater(
        client.create(
            lifecycle: const SandboxLifecycle(
                onTimeout: TimeoutAction.pause,
                mode: SnapshotMode.filesystem,
                autoResume: true)),
        throwsA(isA<InvalidArgumentException>()));
    expect(calls, 2);
  });

  test('pause conflict is false, filesystem pause and reboot use memory=false',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          expect(jsonDecode(r.body)['memory'], false);
          if (r.url.path.endsWith('pause')) {
            return json({'code': 409, 'message': 'already paused'}, 409);
          }
          return json(sandboxResponse);
        }));
    expect(await client.pause('sb', mode: SnapshotMode.filesystem), false);
    await client.connect('sb', onResume: OnResume.reboot);
    await expectLater(
        client.pause('sb', mode: SnapshotMode.full, keepMemory: true),
        throwsA(isA<InvalidArgumentException>()));
  });

  test('fork preserves per-item successes and typed failures', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          expect(jsonDecode(r.body), {'count': 3, 'timeout': 2});
          return json([
            {'sandbox': sandboxResponse},
            {
              'error': {'code': 429, 'message': 'limit'}
            },
            {
              'error': {'code': 404, 'message': 'snapshot gone'}
            }
          ]);
        }));
    final results = await client.fork('sb',
        count: 3, timeout: const Duration(milliseconds: 1501));
    expect(results[0].sandbox!.sandboxId, 'sb');
    expect(results[1].error, isA<RateLimitException>());
    expect(results[2].error, isA<NotFoundException>());
    await expectLater(
        client.fork('sb', count: 21),
        throwsA(isA<InvalidArgumentException>().having((e) => e.message,
            'message', 'count must be an integer between 1 and 20')));
  });

  test('snapshot creation, listing and deletion use official paths', () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          if (r.method == 'POST') {
            expect(r.url.path, '/sandboxes/sb/snapshots');
            expect(jsonDecode(r.body), {'name': 'snap', 'memory': false});
            return json({
              'snapshotID': 'snap-id',
              'names': ['snap']
            });
          }
          if (r.method == 'GET') {
            expect(r.url.path, '/snapshots');
            expect(r.url.queryParameters['sandboxID'], 'sb');
            return json([
              {'snapshotID': 'snap-id'}
            ]);
          }
          expect(r.url.path, '/templates/snap-id');
          return json({'code': 404}, 404);
        }));
    expect(
        (await client.createSnapshot('sb',
                name: 'snap', mode: SnapshotMode.filesystem))
            .names,
        ['snap']);
    expect(
        (await client.listSnapshots(sandboxId: 'sb').nextItems())
            .single
            .snapshotId,
        'snap-id');
    expect(await client.deleteSnapshot('snap-id'), false);
  });

  test('signed URLs match fixed cross-language SHA256 vectors', () {
    for (final vector in <num, String>{
      0.5: 'v1_V0nulSjPa52CP1g//0I1hwy3A7wvGvTJTpNBH5qgxAY',
      1e-7: 'v1_SXvcqxrOE3aRvD8urHGYPpwyltfB1w4KKsONfI5MGdc',
      1e-6: 'v1_H0hG6BvR/2yvy0R+ywoWSu65hH0wEEWsHEFDfZoJg34',
      1e20: 'v1_qJ2GoNI2TGoxthL95s7LOHb88IqSFGCLvlbhdMabMN0',
      1e21: 'v1_aGFUj89oAZ7K2S4pB3pd5nugSmR85Wbwbk9VCdzjatU',
      double.infinity: 'v1_OEok/6tjFaBG4CE9CKffU7wW0BwmAKqqfK22Wz07iO0',
      double.negativeInfinity: 'v1_j8UkYYqXhZKTe24gJZnXhmOBiZhe4YRfttHv2Bqo7qY',
      -0.5: 'v1_/kbb+KeBN1BmU68xMwG3SwjEfxb4qv5Str2N6sTHGp0',
      1.0: 'v1_PFNSZK1gcbV+9lw0lE2pF/ekBIDd+kw2wxClXMh5ymU',
    }.entries) {
      final result = getSignature(
          path: '/a',
          operation: 'read',
          envdAccessToken: 'token',
          expirationInSeconds: vector.key,
          now: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(result.expiration, vector.key);
      expect(result.signature, vector.value);
    }
    expect(
        getSignature(path: '/a', operation: 'custom', envdAccessToken: 'token')
            .signature,
        'v1_lBAg9OMLLtxRtogH1p7kx6Dq2o0cNSh7cMlvxKqHOrA');
    expect(
        () => getSignature(path: '/a', operation: 'read', envdAccessToken: ''),
        throwsA(isA<E2BException>().having((e) => e.message, 'message',
            'Access token is not set and signature cannot be generated!')));
    final vectors =
        jsonDecode(File('test/signature_vectors.json').readAsStringSync())
            as List;
    for (final vector in vectors) {
      final signature = getSignature(
          path: vector['path'] as String,
          operation: vector['operation'] as String,
          user: vector['user'] as String?,
          envdAccessToken: vector['token'] as String,
          expirationInSeconds: vector['expiration'] as int?,
          now: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
      expect(signature.signature, vector['signature']);
      expect(signature.expiration, vector['expiration']);
    }
  });

  test('file URLs use token signature rather than including token or API key',
      () async {
    final client = E2BClient(
        apiKey: 'management-secret',
        httpClient: MockClient((_) async => json(sandboxResponse)));
    final sandbox = await client.create();
    final uri = sandbox.downloadUrl('/tmp/你好 &.txt');
    expect(uri.host, '49983-sb.e2b.app');
    expect(uri.queryParameters['path'], '/tmp/你好 &.txt');
    expect(
        uri.queryParameters['signature'],
        getSignature(
                path: '/tmp/你好 &.txt',
                operation: 'read',
                envdAccessToken: 'token')
            .signature);
    expect(uri.queryParameters.keys, isNot(contains('token')));
    expect(sandbox.getMcpUrl(), 'https://50005-sb.e2b.app/mcp');
  });

  test(
      'creation call overrides persist on resulting sandbox but not original client',
      () async {
    final client = E2BClient(
        apiKey: 'default',
        httpClient: MockClient((r) async {
          if (r.url.path == '/health') {
            expect(r.headers['X-API-Key'], isNull);
            expect(r.url.host, contains('alternate.test'));
            return json({});
          }
          expect(r.headers['X-API-Key'],
              r.url.host == 'api.alternate.test' ? 'alternate' : 'default');
          if (r.method == 'POST') return json(sandboxResponse);
          return json({...sandboxResponse, 'state': 'running'});
        }));
    final sandbox = await client.create(
        options: RequestOptions(apiKey: 'alternate', domain: 'alternate.test'));
    expect(sandbox.sandboxDomain, 'alternate.test');
    expect(await sandbox.isRunning(), true);
    expect((await client.getInfo('sb')).state, 'running');
  });
}
