import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('bound template serialization helpers work detached without HTTP',
      () async {
    final client = E2B(httpClient: MockClient((request) async {
      fail('serialization must not send HTTP');
    }));
    addTearDown(client.close);
    final template =
        client.Template().fromPythonImage('3.12').runCmd('echo ok');
    final toJSON = client.Template.toJSON;
    final toDockerfile = client.Template.toDockerfile;
    expect(await toJSON(template, computeHashes: false),
        await Template.toJSON(template, computeHashes: false));
    expect(toDockerfile(template), Template.toDockerfile(template));
    expect(toDockerfile(template), contains('FROM python:3.12'));
    expect(() => toDockerfile(client.Template().fromTemplate('base')),
        throwsA(isA<E2BException>()));
  });

  test(
      'fork accepts integer doubles and rejects non-integer numbers before HTTP',
      () async {
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    for (final count in [1.0, 20.0]) {
      await client.Sandbox.fork('s', count: count);
      expect(jsonDecode(requests.last.body)['count'], count.toInt());
      expect(requests.last.body, isNot(contains('.0')));
    }
    for (final count in [0, 21, 1.5, double.nan, double.infinity, -1]) {
      await expectLater(
          client.Sandbox.fork('s', count: count),
          throwsA(isA<InvalidArgumentException>().having((e) => e.message,
              'message', 'count must be an integer between 1 and 20')));
    }
    expect(requests, hasLength(2));
  });

  test('retries reuse one header snapshot while later calls observe changes',
      () async {
    final bound = {'Bound': 'initial'};
    final perCall = {'Call': 'initial'};
    final seen = <Map<String, String>>[];
    final client = E2B(
        apiKey: 'key',
        headers: bound,
        httpClient: MockClient((request) async {
          seen.add({...request.headers});
          if (seen.length == 1) {
            bound['Bound'] = 'updated';
            perCall['Call'] = 'updated';
            return http.Response('', 503, headers: {'retry-after': '0'});
          }
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    final options = RequestOptions(apiHeaders: perCall);
    await client.Volume.list(options: options);
    expect(seen, hasLength(2));
    expect(seen[0]['Bound'], 'initial');
    expect(seen[1]['Bound'], 'initial');
    expect(seen[1]['Call'], 'initial');
    await client.Volume.list(options: options);
    expect(seen.last['Bound'], 'updated');
    expect(seen.last['Call'], 'updated');
  });

  test('paginator options keep nested header references between requests',
      () async {
    final legacy = {'Legacy': 'initial', 'Removed': 'yes'};
    final modern = {'Modern': 'initial'};
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200, headers: {'x-next-token': 'next'});
        }));
    addTearDown(client.close);
    final options = RequestOptions(headers: legacy, apiHeaders: modern);
    final snapshot = options.headers;
    final paginator = client.Secret.list(options: options);
    legacy['Legacy'] = 'updated';
    legacy.remove('Removed');
    modern['Modern'] = 'updated';
    await paginator.nextItems();
    expect(requests.last.headers['Legacy'], 'updated');
    expect(requests.last.headers['Modern'], 'updated');
    expect(requests.last.headers['Removed'], isNull);
    expect(snapshot['Legacy'], 'initial');
    modern.clear();
    legacy['Added'] = 'later';
    await paginator.nextItems();
    expect(requests.last.headers['Modern'], isNull);
    expect(requests.last.headers['Added'], 'later');
  });

  test('paginator preserves independent header defaults across pages',
      () async {
    final legacy = {'Legacy': 'initial'};
    final modern = {'Modern': 'initial'};
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'key',
        headers: legacy,
        apiHeaders: modern,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200,
              headers: {'x-next-token': 'page-${requests.length}'});
        }));
    addTearDown(client.close);
    final paginator = client.Secret.list(options: RequestOptions(headers: {}));
    modern['Modern'] = 'updated';
    legacy['Legacy'] = 'updated';
    await paginator.nextItems();
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.headers['Modern'], 'updated');
    await paginator.nextItems(options: RequestOptions(apiHeaders: {}));
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.headers['Modern'], isNull);
    expect(requests.last.url.queryParameters['nextToken'], 'page-1');
    await paginator.nextItems();
    expect(requests.last.headers['Modern'], 'updated');
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.url.queryParameters['nextToken'], 'page-2');
  });

  test('sandbox keeps management headers out of envd requests', () async {
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'key',
        headers: {'Legacy': 'bound'},
        apiHeaders: {'Modern': 'bound', 'User-Agent': 'integration'},
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/files') {
            return http.Response('content', 200);
          }
          return http.Response(
              jsonEncode({
                'sandboxID': 's',
                'envdVersion': '0.6.4',
                'envdAccessToken': 'envd-token'
              }),
              200);
        }));
    addTearDown(client.close);
    final sandbox = await client.Sandbox.create(
        options: RequestOptions(
            headers: {}, sandboxUrl: Uri.parse('https://envd.test')));
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.headers['Modern'], 'bound');
    expect(await sandbox.files.read('/a'), 'content');
    expect(requests.last.url.host, 'envd.test');
    expect(requests.last.headers['Legacy'], isNull);
    expect(requests.last.headers['Modern'], isNull);
    expect(requests.last.headers['User-Agent'], 'integration');
    expect(requests.last.headers['X-Access-Token'], 'envd-token');
    expect(requests.last.headers['E2b-Sandbox-Id'], 's');
    await sandbox.getInfo();
    expect(requests.last.headers['Modern'], 'bound');
    expect(requests.last.headers['Legacy'], isNull);
  });

  test('header fields override independently for calls and derived clients',
      () async {
    final seen = <Map<String, String>>[];
    final client = E2B(
        apiKey: 'key',
        headers: {'Legacy': 'bound', 'Shared': 'legacy'},
        apiHeaders: {'Modern': 'bound', 'Shared': 'modern'},
        httpClient: MockClient((request) async {
          seen.add({...request.headers});
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    for (final derived in [false, true]) {
      for (final options in [
        RequestOptions(headers: {}),
        RequestOptions(apiHeaders: {}),
        RequestOptions(headers: {}, apiHeaders: {}),
        RequestOptions(headers: {'Shared': 'call'}),
      ]) {
        await (derived ? client.withOptions(options) : client)
            .Volume
            .list(options: derived ? null : options);
      }
      final rows = seen.sublist(seen.length - 4);
      expect(rows[0]['Legacy'], isNull);
      expect(rows[0]['Modern'], 'bound');
      expect(rows[1]['Legacy'], 'bound');
      expect(rows[1]['Modern'], isNull);
      expect(rows[1]['Shared'], 'legacy');
      expect(rows[2]['Legacy'], isNull);
      expect(rows[2]['Modern'], isNull);
      expect(rows[2]['Shared'], isNull);
      expect(rows[3]['Shared'], 'modern');
    }
  });

  test('bound nested headers remain live until each request is created',
      () async {
    for (final structured in [false, true]) {
      final legacy = {'Legacy': 'first', 'Removed': 'yes'};
      final modern = {'Modern': 'first', 'Legacy': 'wins'};
      final seen = <Map<String, String>>[];
      final httpClient = MockClient((request) async {
        seen.add({...request.headers});
        return http.Response('[]', 200);
      });
      final client = structured
          ? E2B.fromOptions(
              E2BClientOpts(apiKey: 'key', headers: legacy, apiHeaders: modern),
              httpClient: httpClient)
          : E2B(
              apiKey: 'key',
              headers: legacy,
              apiHeaders: modern,
              httpClient: httpClient);
      addTearDown(client.close);
      await client.Volume.list();
      legacy.remove('Removed');
      modern['Modern'] = 'second';
      modern.remove('Legacy');
      legacy['Legacy'] = 'updated';
      await client.Volume.list();
      expect(seen.first['Legacy'], 'wins');
      expect(seen.last['Legacy'], 'updated');
      expect(seen.last['Modern'], 'second');
      expect(seen.last['Removed'], isNull);
    }
  });

  test('detached resource methods retain defaults and per-call cancellation',
      () async {
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'bound',
        domain: 'bound.test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
              request.url.path.startsWith('/templates/') ? '{}' : '[]', 200);
        }));
    addTearDown(client.close);
    final sandboxList = client.Sandbox.list;
    final secretList = client.Secret.list;
    final volumeList = client.Volume.list;
    final templateExists = client.Template.exists;
    final canceled = CancellationSignal();
    canceled.cancel();
    await expectLater(volumeList(options: RequestOptions(signal: canceled)),
        throwsA(isA<Exception>()));
    expect(requests, isEmpty);
    await sandboxList().nextItems();
    await secretList().nextItems();
    await volumeList();
    expect(await templateExists('name'), isTrue);
    expect(requests, hasLength(4));
    expect(requests.every((r) => r.url.host == 'api.bound.test'), isTrue);
    expect(requests.every((r) => r.headers['X-API-Key'] == 'bound'), isTrue);
  });

  test('structured E2B defaults and derived clients retain resource factories',
      () async {
    final requests = <http.Request>[];
    final client = E2B.fromOptions(
        E2BClientOpts(
            apiKey: 'bound', domain: 'bound.test', headers: {'X-Bound': 'yes'}),
        httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response('[]', 200);
    }));
    addTearDown(client.close);
    expect(identical(client.withOptions(null), client), isTrue);
    final derived = client.withOptions(
        RequestOptions(apiKey: 'derived', domain: 'derived.test', headers: {}));
    await derived.Secret.list().nextItems();
    await client.Secret.list().nextItems();
    expect(requests.first.url.host, 'api.derived.test');
    expect(requests.first.headers['X-API-Key'], 'derived');
    expect(requests.first.headers['X-Bound'], isNull);
    expect(requests.last.url.host, 'api.bound.test');
    expect(requests.last.headers['X-Bound'], 'yes');
    expect(derived.Template(), isA<Template>());
  });

  test(
      'bound Sandbox factories forward create connect snapshot and fork options',
      () async {
    final requests = <http.Request>[];
    final sandbox = {'sandboxID': 's', 'envdVersion': '0.6.4'};
    final client = E2B(
        apiKey: 'bound',
        httpClient: MockClient((request) async {
          requests.add(request);
          final Object response = request.url.path.endsWith('/snapshots')
              ? {
                  'snapshotID': 'snap',
                  'names': ['name']
                }
              : request.url.path.endsWith('/fork')
                  ? [
                      {'sandbox': sandbox}
                    ]
                  : sandbox;
          return http.Response(jsonEncode(response), 200);
        }));
    addTearDown(client.close);
    final options = RequestOptions(
        apiKey: 'call', sandboxUrl: Uri.parse('https://envd.test'));
    final created = await client.Sandbox.create(
        template: 'custom',
        timeout: const Duration(milliseconds: 1500),
        metadata: {},
        envs: {},
        allowInternetAccess: false,
        volumeMounts: {},
        options: options);
    expect(created.sandboxId, 's');
    expect(created.downloadUrl('/a').host, 'envd.test');
    expect(jsonDecode(requests.last.body), {
      'templateID': 'custom',
      'timeout': 2,
      'metadata': {},
      'envVars': {},
      'allow_internet_access': false,
      'volumeMounts': []
    });
    final connected = await client.Sandbox.connect('s/a',
        timeout: const Duration(seconds: 3),
        onResume: OnResume.reboot,
        options: options);
    expect(connected.downloadUrl('/a').host, 'envd.test');
    expect(jsonDecode(requests.last.body), {'timeout': 3, 'memory': false});
    expect(
        requests.last.url.pathSegments, ['v2', 'sandboxes', 's/a', 'connect']);
    expect(
        (await client.Sandbox.createSnapshot('s',
                name: 'name', mode: SnapshotMode.filesystem, options: options))
            .snapshotId,
        'snap');
    expect(jsonDecode(requests.last.body), {'name': 'name', 'memory': false});
    final forked = await client.Sandbox.fork('s',
        count: 1, timeout: const Duration(seconds: 4), options: options);
    expect(forked.single.sandbox!.downloadUrl('/a').host, 'envd.test');
    expect(jsonDecode(requests.last.body), {'count': 1, 'timeout': 4});
    expect(requests.every((r) => r.headers['X-API-Key'] == 'call'), isTrue);
  });

  test('bound Sandbox management forwards bodies filters and credentials',
      () async {
    final requests = <http.Request>[];
    final client = E2B(
        apiKey: 'bound',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(request.method == 'GET' ? '[]' : '',
              request.method == 'GET' ? 200 : 204);
        }));
    addTearDown(client.close);
    final options = RequestOptions(apiKey: 'call');
    expect(
        await client.Sandbox.pause('s/a', keepMemory: false, options: options),
        isTrue);
    await client.Sandbox.setTimeout('s/a', const Duration(milliseconds: 1500),
        options: options);
    await client.Sandbox.updateNetwork('s/a', SandboxNetwork(denyOut: ['host']),
        options: options);
    expect(await client.Sandbox.getMetrics('s/a', options: options), isEmpty);
    expect(
        await client.Sandbox.listSnapshots(
                sandboxId: 's/a', name: 'snap', limit: 2, options: options)
            .nextItems(),
        isEmpty);
    expect(await client.Sandbox.deleteSnapshot('snap/a', options: options),
        isTrue);
    expect(jsonDecode(requests[0].body), {'memory': false});
    expect(jsonDecode(requests[1].body), {'timeout': 2});
    expect(jsonDecode(requests[2].body), {
      'denyOut': ['host']
    });
    expect(requests[0].url.pathSegments, ['sandboxes', 's/a', 'pause']);
    expect(requests[4].url.queryParameters,
        {'sandboxID': 's/a', 'name': 'snap', 'limit': '2'});
    expect(requests.every((r) => r.headers['X-API-Key'] == 'call'), isTrue);
  });

  test('E2B resource entry points bind isolated client configuration',
      () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      return http.Response('[]', 200);
    });
    final first =
        E2B(apiKey: 'first', domain: 'first.test', httpClient: transport);
    final second =
        E2B(apiKey: 'second', domain: 'second.test', httpClient: transport);
    addTearDown(first.close);
    addTearDown(second.close);
    await first.Secret.list().nextItems();
    await second.Volume.list();
    await first.Sandbox.list()
        .nextItems(options: RequestOptions(apiKey: 'call'));
    await first.Secret.list().nextItems();
    expect(requests.map((r) => r.headers['X-API-Key']),
        ['first', 'second', 'call', 'first']);
    expect(requests.map((r) => r.url.host), [
      'api.first.test',
      'api.second.test',
      'api.first.test',
      'api.first.test'
    ]);
    final builder = first.Template(
        fileContextPath: '/context',
        fileIgnorePatterns: ['*.tmp']).fromPythonImage('3');
    expect(builder.fileContextPath, '/context');
    expect(builder.fileIgnorePatterns, ['*.tmp']);
    expect(second.Template().instructions, isEmpty);
    expect(first.Secret.fill('name'), Secret.fill('name'));
    expect(
        first.Secret.iamToken(audience: 'service', tokenType: 'JWT-SVID')
            .tokenType,
        'JWT-SVID');
    expect(
        () => first.Secret.fill(''), throwsA(isA<InvalidArgumentException>()));
  });
}
