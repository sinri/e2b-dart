import 'dart:async';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class TrackedPageClient extends ApiClient {
  bool closed = false;
  TrackedPageClient(http.Client client)
      : super(apiKey: 'key', retries: 0, httpClient: client);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('pagination limits preserve JavaScript number range and formatting',
      () async {
    final seen = <String?>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          seen.add(request.url.queryParameters['limit']);
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    for (final entry in <MapEntry<num, String>>[
      const MapEntry(0.5, '0.5'),
      const MapEntry(-1.5, '-1.5'),
      const MapEntry(1.0, '1'),
      const MapEntry(1e21, '1e+21'),
      const MapEntry(double.nan, 'NaN'),
      const MapEntry(double.infinity, 'Infinity'),
    ]) {
      await client.listPaginator(limit: entry.key).nextItems();
      await client.secrets.list(limit: entry.key).nextItems();
      await client.listSnapshots(limit: entry.key).nextItems();
      expect(seen.sublist(seen.length - 3), List.filled(3, entry.value));
    }
  });

  test(
      'per-page factory clients close on success and error without losing cursor',
      () async {
    final clients = <TrackedPageClient>[];
    final pages = Paginator<int>(null, '/secrets', (data) => data['id'] as int,
        nextToken: 'initial', clientFactory: () {
      final call = clients.length;
      final client = TrackedPageClient(MockClient((request) async {
        expect(request.url.queryParameters['nextToken'],
            call == 0 ? 'initial' : 'next');
        return call == 1
            ? http.Response('{"message":"failed"}', 403)
            : http.Response('[{"id":1}]', 200,
                headers: call == 0 ? {'x-next-token': 'next'} : {});
      }));
      clients.add(client);
      return client;
    });
    expect(await pages.nextItems(), [1]);
    expect(clients.single.closed, isTrue);
    await expectLater(pages.nextItems(), throwsA(isA<E2BException>()));
    expect(pages.nextToken, 'next');
    expect(clients.last.closed, isTrue);
    expect(await pages.nextItems(), [1]);
    expect(pages.hasNext, isFalse);
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('single-page list shares paginator defaults and API error mapping',
      () async {
    var status = 200;
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
              status == 200 ? '[]' : '{"message":"detail"}', status);
        }));
    addTearDown(client.close);
    await client.list();
    expect(requests.last.url.queryParameters.containsKey('limit'), isFalse);
    for (final limit in [0, -1, 101]) {
      await client.list(limit: limit);
      expect(requests.last.url.queryParameters['limit'], '$limit');
    }
    status = 403;
    await expectLater(
        client.list(),
        throwsA(isA<SandboxException>()
            .having((e) => e.message, 'message', '403: detail')));
  });

  test('concurrent page responses update state in completion order', () async {
    for (final lateFailure in [false, true]) {
      final responses = [
        Completer<http.Response>(),
        Completer<http.Response>()
      ];
      final bothStarted = Completer<void>();
      var calls = 0;
      final client = ApiClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((request) {
            expect(request.url.queryParameters['nextToken'], 'initial');
            final response = responses[calls++];
            if (calls == 2) bothStarted.complete();
            return response.future;
          }));
      addTearDown(client.close);
      final pages = Paginator<int>(
          client, '/secrets', (data) => data['id'] as int,
          nextToken: 'initial');
      final first = pages.nextItems();
      final second = pages.nextItems();
      await bothStarted.future;
      responses[1].complete(http.Response('[{"id":2}]', 200));
      expect(await second, [2]);
      expect(pages.hasNext, isFalse);
      expect(pages.nextToken, isNull);
      if (lateFailure) {
        final failure = expectLater(first, throwsA(isA<E2BException>()));
        responses[0].complete(http.Response('{"message":"failed"}', 500,
            headers: {'x-next-token': 'ignored'}));
        await failure;
        expect(pages.hasNext, isFalse);
        expect(pages.nextToken, isNull);
      } else {
        responses[0].complete(http.Response('[{"id":1}]', 200,
            headers: {'x-next-token': 'late'}));
        expect(await first, [1]);
        expect(pages.hasNext, isTrue);
        expect(pages.nextToken, 'late');
      }
    }
  });

  test('successful pages advance before model conversion errors', () async {
    for (final token in ['next', '']) {
      var calls = 0;
      final client = ApiClient(
          apiKey: 'key',
          httpClient: MockClient((request) async {
            expect(request.url.queryParameters['nextToken'],
                calls++ == 0 ? 'initial' : 'next');
            return http.Response('[{}]', 200, headers: {'x-next-token': token});
          }));
      addTearDown(client.close);
      final failure = StateError('conversion failed');
      final pages = Paginator<int>(client, '/secrets', (_) => throw failure,
          nextToken: 'initial');
      await expectLater(pages.nextItems(), throwsA(same(failure)));
      expect(pages.nextToken, token.isEmpty ? null : token);
      expect(pages.hasNext, token.isNotEmpty);
      if (token.isNotEmpty) {
        // The next call uses the cursor from the successful response.
        await expectLater(pages.nextItems(), throwsA(same(failure)));
        expect(calls, 2);
      } else {
        await expectLater(pages.nextItems(), throwsStateError);
        expect(calls, 1);
      }
    }
  });

  test('sandbox and snapshot pages preserve cursors on official API errors',
      () async {
    for (final snapshots in [false, true]) {
      var status = 403;
      final client = E2BClient(
          apiKey: 'key',
          retries: 0,
          httpClient: MockClient((request) async {
            expect(request.url.queryParameters['nextToken'], 'initial');
            return http.Response('{"code":404,"message":"detail"}', status,
                headers: {
                  'content-type': 'application/json',
                  'x-next-token': 'bad'
                });
          }));
      addTearDown(client.close);
      final Paginator<dynamic> pages = snapshots
          ? client.listSnapshots(nextToken: 'initial')
          : client.listPaginator(nextToken: 'initial');
      for (final code in [400, 403, 404, 409, 500]) {
        status = code;
        await expectLater(
            pages.nextItems(),
            throwsA(isA<SandboxException>()
                .having((e) => e.message, 'message', '$code: detail')));
        expect(pages.nextToken, 'initial');
        expect(pages.hasNext, isTrue);
      }
      status = 429;
      await expectLater(pages.nextItems(), throwsA(isA<RateLimitException>()));
      expect(pages.nextToken, 'initial');
    }
  });

  test('snapshot pages retain filters and advance only from response cursors',
      () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          final query = request.url.queryParameters;
          expect(request.url.path, '/snapshots');
          expect(query['sandboxID'], 'source');
          expect(query['name'], 'project/snapshot:v1');
          expect(query['limit'], '2');
          expect(query['nextToken'], calls == 0 ? 'initial' : 'second');
          return http.Response('[{"snapshotID":"snap"}]', 200,
              headers: calls++ == 0 ? {'x-next-token': 'second'} : {});
        }));
    addTearDown(client.close);
    final pages = client.listSnapshots(
        sandboxId: 'source',
        name: 'project/snapshot:v1',
        limit: 2,
        nextToken: 'initial');
    expect((await pages.nextItems()).single.names, isEmpty);
    expect(pages.hasNext, isTrue);
    expect(pages.nextToken, 'second');
    expect((await pages.nextItems()).single.snapshotId, 'snap');
    expect(pages.hasNext, isFalse);
    expect(pages.nextToken, isNull);
    await expectLater(pages.nextItems(), throwsA(isA<StateError>()));
    expect(calls, 2);
  });

  test('sandbox paginator reads mutated filter collections for each page',
      () async {
    final requests = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('[]', 200, headers: {'x-next-token': 'next'});
        }));
    addTearDown(client.close);
    final metadata = {'team': 'first'};
    final states = <SandboxState>['running'];
    final pages =
        client.listPaginator(metadata: metadata, state: states, limit: 7);
    metadata['team'] = 'before';
    await pages.nextItems();
    metadata['team'] = 'after';
    states.add('paused');
    await pages.nextItems();
    expect(requests.first.url.queryParameters['metadata'], 'team=before');
    expect(requests.last.url.queryParameters['metadata'], 'team=after');
    expect(requests.first.url.queryParameters['state'], 'running');
    expect(requests.last.url.queryParameters['state'], 'running,paused');
    expect(requests.last.url.queryParameters['limit'], '7');
    expect(requests.last.url.queryParameters['nextToken'], 'next');
  });

  test('sandbox paginator omits empty template and forwards sort and cursor',
      () async {
    final seen = <http.Request>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response('[]', 200);
        }));
    addTearDown(client.close);
    const SandboxListOrder order = 'desc';
    const SandboxState state = 'paused';
    await client
        .listPaginator(
            template: '',
            order: order,
            state: [state],
            limit: 5,
            nextToken: 'cursor')
        .nextItems();
    expect(seen.single.url.queryParameters, {
      'order': 'desc',
      'state': 'paused',
      'limit': '5',
      'nextToken': 'cursor'
    });
    await client.list(template: '');
    expect(seen.last.url.queryParameters.containsKey('template'), isFalse);
    await client.listPaginator(template: 'base').nextItems();
    expect(seen.last.url.queryParameters['template'], 'base');
  });

  test('sandbox list filters serialize timestamps at JS millisecond precision',
      () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['startedAfter'],
              '2026-01-02T03:04:05.123Z');
          expect(request.url.queryParameters['state'], 'running,paused');
          return http.Response('', 204);
        }));
    addTearDown(client.close);
    final time = DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456);
    final page =
        await client.list(startedAfter: time, state: ['running', 'paused']);
    expect(page.items, isEmpty);
    expect(page.hasNext, false);
    final pages =
        client.listPaginator(startedAfter: time, state: ['running', 'paused']);
    expect(await pages.nextItems(), isEmpty);
    expect(pages.hasNext, false);
    expect(calls, 2);
  });

  test('page call inherits credentials while replacing explicit headers',
      () async {
    final seen = <http.Request>[];
    final client = E2BClient(
        apiKey: 'client-key',
        retries: 0,
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response('[]', 200, headers: {'x-next-token': 'next'});
        }));
    addTearDown(client.close);
    final pages = client.listPaginator(
        options:
            RequestOptions(apiKey: 'bound-key', headers: {'X-Bound': 'bound'}));
    await pages.nextItems(
        options: RequestOptions(requestTimeout: const Duration(seconds: 1)));
    await pages.nextItems(options: RequestOptions(headers: {}));
    expect(seen.first.headers['X-API-Key'], 'bound-key');
    expect(seen.first.headers['X-Bound'], 'bound');
    expect(seen.last.headers['X-API-Key'], 'bound-key');
    expect(seen.last.headers['X-Bound'], isNull);
    expect(seen.last.url.queryParameters['nextToken'], 'next');
  });

  test('empty successful page terminates and failed requests preserve cursor',
      () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['nextToken'], 'initial');
          calls++;
          return calls == 1
              ? http.Response('failure', 500)
              : http.Response('', 204);
        }));
    addTearDown(client.close);
    final pages = client.listPaginator(nextToken: 'initial');
    await expectLater(pages.nextItems(), throwsA(isA<E2BException>()));
    expect(pages.hasNext, true);
    expect(pages.nextToken, 'initial');
    expect(await pages.nextItems(), isEmpty);
    expect(pages.hasNext, false);
    await expectLater(pages.nextItems(), throwsStateError);
    expect(calls, 2);
  });
}
