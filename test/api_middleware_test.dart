import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('global then local requests, reverse responses, request replacement',
      () async {
    final events = <String>[];
    final ids = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          events.add('fetch');
          expect(request.url.path, '/changed');
          expect(request.headers['x-added'], 'yes');
          return http.Response('original', 200);
        }));
    final global = ApiMiddleware(onRequest: (context) {
      events.add('global-request');
      ids.add(context.id);
      expect(context.schemaPath, '/original');
      return http.Request('GET', context.request.url.replace(path: '/changed'))
        ..headers.addAll(context.request.headers)
        ..headers['x-added'] = 'yes';
    }, onResponse: (context) {
      events.add('global-response');
      ids.add(context.id);
      return http.Response('${context.response!.body}:global', 200);
    });
    client.api.use([global]);
    try {
      final response =
          await client.api.GET('/original', parseAs: 'text', middleware: [
        ApiMiddleware(onRequest: (context) {
          events.add('local-request');
          ids.add(context.id);
          expect(context.request.url.path, '/changed');
          return null;
        }, onResponse: (context) {
          events.add('local-response');
          ids.add(context.id);
          return http.Response('${context.response!.body}:local', 200);
        })
      ]);
      expect(response.data, 'original:local:global');
      expect(events, [
        'global-request',
        'local-request',
        'fetch',
        'local-response',
        'global-response'
      ]);
      expect(ids.toSet().length, 1);
      client.api.eject([global]);
      expect(
          () => client.api.use([const ApiMiddleware()]), throwsArgumentError);
    } finally {
      client.close();
    }
  });

  test('request short circuit skips later request and all response hooks',
      () async {
    final events = <String>[];
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          fail('short circuit must not send');
        }));
    try {
      final result = await client.api.GET('/cached', middleware: [
        ApiMiddleware(onRequest: (_) {
          events.add('request');
          return http.Response('{"cached":true}', 200);
        }, onResponse: (_) {
          events.add('response');
          return null;
        }),
        ApiMiddleware(onRequest: (_) {
          events.add('later');
          return null;
        }),
      ]);
      expect(result.data, {'cached': true});
      expect(events, ['request']);
    } finally {
      client.close();
    }
  });

  test('error hooks reverse, replacement then recovery, followed by responses',
      () async {
    final events = <String>[];
    final original = StateError('network');
    final replacement = StateError('replacement');
    final client = ApiClient(
        apiKey: 'key',
        retries: 0,
        httpClient: MockClient((_) async => throw original));
    try {
      final result = await client.api.GET('/test', middleware: [
        ApiMiddleware(onError: (context) {
          events.add('first-error');
          expect(context.error, same(replacement));
          return http.Response('{"recovered":true}', 200);
        }, onResponse: (_) {
          events.add('first-response');
          return null;
        }),
        ApiMiddleware(onError: (context) {
          events.add('last-error');
          expect(context.error, same(original));
          return replacement;
        }, onResponse: (_) {
          events.add('last-response');
          return null;
        }),
      ]);
      expect(result.data, {'recovered': true});
      expect(events,
          ['last-error', 'first-error', 'last-response', 'first-response']);
      await expectLater(
          client.api.GET('/test',
              middleware: [ApiMiddleware(onError: (_) => replacement)]),
          throwsA(same(replacement)));
    } finally {
      client.close();
    }
  });

  test('request hook exceptions bypass error hooks and transport', () async {
    final failure = StateError('hook');
    final client = ApiClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          fail('must not send');
        }));
    try {
      await expectLater(
          client.api.GET('/test', middleware: [
            ApiMiddleware(
                onRequest: (_) => throw failure,
                onError: (_) {
                  fail('hook errors do not enter transport error hooks');
                })
          ]),
          throwsA(same(failure)));
      await expectLater(
          client.api
              .GET('/test', middleware: [ApiMiddleware(onRequest: (_) => 123)]),
          throwsArgumentError);
    } finally {
      client.close();
    }
  });
}
