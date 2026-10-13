import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/connection_error_io.dart';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/api.dart' show isReplayable, parseRetryAfter;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class AbortClient extends http.BaseClient {
  bool aborted = false;
  final sent = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.complete();
    await (request as http.Abortable).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  test('HTTP version environment fallback preserves source-specific errors',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('e2b-version-probe-');
    addTearDown(() => temporary.delete(recursive: true));
    Future<ProcessResult> runProbe(List<String> arguments,
        {Map<String, String>? environment}) async {
      final process = await Process.start(
          Platform.resolvedExecutable, arguments,
          environment: environment);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode
          .timeout(const Duration(seconds: 60), onTimeout: () {
        process.kill();
        throw TimeoutException('Probe process timed out');
      });
      return ProcessResult(process.pid, exitCode, await stdout, await stderr);
    }

    final kernel = '${temporary.path}/probe.dill';
    final compiled = await runProbe([
      'compile',
      'kernel',
      'test/fixtures/http_version_probe.dart',
      '-o',
      kernel
    ]);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
    for (final entry in <MapEntry<String, String>>[
      MapEntry('', '2'),
      MapEntry('1.1', '1.1'),
      MapEntry('2', '2'),
      MapEntry('3', "E2B_HTTP_VERSION must be '1.1' or '2', got '3'"),
      MapEntry(' 2', "E2B_HTTP_VERSION must be '1.1' or '2', got ' 2'"),
    ]) {
      final result = await runProbe([kernel],
          environment: {'E2B_HTTP_VERSION': entry.key});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((result.stdout as String).trim(), entry.value);
    }
    final result = await runProbe([kernel, '1.1'],
        environment: {'E2B_HTTP_VERSION': 'invalid'});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect((result.stdout as String).trim(), '1.1');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('HTTP version values resolve and survive binding and overrides',
      () async {
    expect(resolveHttpVersion('1.1'), '1.1');
    expect(resolveHttpVersion('2'), '2');
    for (final value in ['', 'HTTP/2', '2.0', ' 2', '3']) {
      final matcher = throwsA(isA<InvalidArgumentException>().having(
          (error) => error.message,
          'message',
          "httpVersion must be '1.1' or '2', got '$value'"));
      expect(() => ConnectionConfig(httpVersion: value), matcher);
      final options = RequestOptions(httpVersion: value);
      final client = E2B(apiKey: 'key');
      try {
        await expectLater(
            client.requestResponse('GET', '/health', options: options),
            matcher);
        expect(() => client.httpClientFor(options), matcher);
      } finally {
        client.close();
      }
    }
    final client =
        E2B.fromOptions(E2BClientOpts(apiKey: 'key', httpVersion: '1.1'));
    addTearDown(client.close);
    expect(client.config.httpVersion, '1.1');
    expect(client.withOptions(RequestOptions()).config.httpVersion, '1.1');
    expect(
        client.withOptions(RequestOptions(httpVersion: '2')).config.httpVersion,
        '2');
    expect(
        RequestOptions.merge(
                RequestOptions(httpVersion: '1.1'), RequestOptions())!
            .httpVersion,
        '1.1');
    final volume = Volume(client,
        VolumeAndToken({'volumeID': 'vol', 'name': 'name', 'token': 'token'}));
    expect(volume.httpVersion, '1.1');
    expect(
        Volume(
                client,
                VolumeAndToken(
                    {'volumeID': 'vol', 'name': 'name', 'token': 'token'}),
                httpVersion: '2')
            .httpVersion,
        '2');
  });

  test('retry count follows JS integer validation and exact error text',
      () async {
    for (final value in <num>[0, 0.0, 1.0, 3, 1e21]) {
      expect(ConnectionConfig(retries: value).retries, value);
      expect(RequestOptions(retries: value).retries, value);
      final client = E2B(apiKey: 'key', retries: value);
      expect(client.config.retries, value);
      client.close();
    }
    for (final entry in <MapEntry<num, String>>[
      MapEntry(-1, '-1'),
      MapEntry(0.5, '0.5'),
      MapEntry(double.nan, 'NaN'),
      MapEntry(double.infinity, 'Infinity'),
      MapEntry(double.negativeInfinity, '-Infinity'),
    ]) {
      final matcher = throwsA(isA<InvalidArgumentException>().having(
          (error) => error.message,
          'message',
          'Invalid retries=${entry.value}: expected a non-negative integer.'));
      expect(() => ConnectionConfig(retries: entry.key), matcher);
      final options = RequestOptions(retries: entry.key);
      final merged = RequestOptions.merge(RequestOptions(retries: 0), options)!;
      var requests = 0;
      final client = E2B(
          apiKey: 'key',
          httpClient: MockClient((_) async {
            requests++;
            return http.Response('[]', 200);
          }));
      try {
        await expectLater(
            client.requestResponse('GET', '/sandboxes', options: merged),
            matcher);
        expect(requests, 0);
        expect(() => client.withOptions(merged), matcher);
      } finally {
        client.close();
      }
      expect(() => E2B(apiKey: 'key', retries: entry.key), matcher);
    }
  });

  test('low-level client validates at construction unless explicitly disabled',
      () async {
    expect(
        () => ApiClient(apiKey: ''), throwsA(isA<AuthenticationException>()));
    final client = ApiClient(
        apiKey: '',
        requireApiKey: false,
        httpClient: MockClient((request) async {
          expect(request.headers.containsKey('X-API-Key'), false);
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    await client.requestResponse('GET', '/health');
  });

  test('missing API key reports official guidance before sending HTTP',
      () async {
    var calls = 0;
    final client = ApiClient(
        apiKey: '',
        deferApiKeyValidation: true,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    await expectLater(
        client.requestResponse('POST', '/sandboxes'),
        throwsA(isA<AuthenticationException>().having(
            (error) => error.message,
            'message',
            'API key is required, please visit the API Keys tab at https://e2b.dev/dashboard?tab=keys to get your API key. '
                'You can either set the environment variable `E2B_API_KEY` '
                "or you can pass it directly to the sandbox like Sandbox.create({ apiKey: 'e2b_...' })")));
    expect(calls, 0);
    await client.requestResponse('GET', '/sandboxes',
        options: RequestOptions(apiKey: 'per-call-key'));
    expect(calls, 1);
  });

  test('per-call apiHeaders merge over deprecated headers and clear bindings',
      () async {
    final seen = <Map<String, String>>[];
    final client = ApiClient(
        apiKey: 'key',
        headers: {'Bound': 'default'},
        httpClient: MockClient((request) async {
          seen.add({...request.headers});
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    final options = RequestOptions(
        headers: {'X-Test': 'old', 'Legacy': 'yes'},
        apiHeaders: {'X-Test': 'new'});
    expect(options.headers, {'X-Test': 'new', 'Legacy': 'yes'});
    await client.request('GET', '/test', options: options);
    expect(seen.last['X-Test'], 'new');
    expect(seen.last['Legacy'], 'yes');
    expect(seen.last['Bound'], 'default');
    final merged = RequestOptions.merge(
        RequestOptions(headers: {'Bound': 'default'}),
        RequestOptions(apiHeaders: {}));
    expect(merged!.hasHeadersOverride, isTrue);
    expect(merged.headers, {'Bound': 'default'});
    expect(const <Username>['user', 'root'], ['user', 'root']);
  });

  test('native HTTP client retains refused-connection classification',
      () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final client = http.Client();
    addTearDown(client.close);
    try {
      await client.get(Uri.parse('http://127.0.0.1:$port'));
      fail('Expected refused connection');
    } catch (error) {
      expect(error, isA<http.ClientException>());
      expect(isConnectionEstablishmentError(error), true);
    }
  });

  test('connection failure classification excludes post-write errors', () {
    expect(
        isConnectionEstablishmentError(
            const SocketException("Failed host lookup: 'example.invalid'")),
        true);
    expect(
        isConnectionEstablishmentError(
            const SocketException('connection lost')),
        false);
    final refused = Platform.isWindows
        ? 10061
        : Platform.isMacOS
            ? 61
            : 111;
    final reset = Platform.isWindows
        ? 10054
        : Platform.isMacOS
            ? 54
            : 104;
    expect(
        isConnectionEstablishmentError(
            SocketException('refused', osError: OSError('refused', refused))),
        true);
    expect(
        isConnectionEstablishmentError(
            SocketException('reset', osError: OSError('reset', reset))),
        false);
    expect(
        isConnectionEstablishmentError(http.ClientException('refused')), false);
  });

  test('resource creation retries DNS failure but never opaque connection loss',
      () async {
    for (final established in [false, true]) {
      var calls = 0;
      final failure = established
          ? http.ClientException('connection lost')
          : const SocketException("Failed host lookup: 'example.invalid'");
      final client = ApiClient(
          apiKey: 'key',
          retries: 1,
          httpClient: MockClient((_) async {
            calls++;
            if (calls == 1) throw failure;
            return http.Response('{}', 200);
          }));
      addTearDown(client.close);
      if (established) {
        await expectLater(
            client.request('POST', '/v2/sandboxes'), throwsA(same(failure)));
        expect(calls, 1);
      } else {
        expect(await client.request('POST', '/v2/sandboxes'), {});
        expect(calls, 2);
      }
    }
  });

  test('retry classification follows official management replay allowlist', () {
    expect(isReplayable('POST', '/v2/sandboxes'), false);
    expect(isReplayable('POST', '/sandboxes/s/fork'), false);
    expect(isReplayable('POST', '/secrets/a'), false);
    expect(isReplayable('POST', '/sandboxes/s/timeout'), true);
    expect(isReplayable('POST', '/v2/sandboxes/s/connect'), true);
    expect(isReplayable('POST', '/v2/templates/t/builds/b'), true);
    expect(isReplayable('GET', '/secrets'), true);
    expect(isReplayable('POST', '/nodes/node-id'), true);
    expect(isReplayable('POST', '/admin/teams/team-id/builds/cancel'), true);
    expect(parseRetryAfter(' 12 '), 12);
    for (final value in [
      '-1',
      '0.1',
      'tomorrow',
      '2147484',
      '999999999999999999999'
    ]) {
      expect(parseRetryAfter(value), isNull);
    }
  });
  test('429 Retry-After and 503 retry, 429 without header does not', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        retries: 3,
        httpClient: MockClient((r) async {
          calls++;
          if (calls == 1) {
            return http.Response('', 429, headers: {'retry-after': '0'});
          }
          if (calls == 2) {
            return http.Response('', 503, headers: {'retry-after': '0'});
          }
          return http.Response('{}', 200);
        }));
    await client.request('GET', '/anything');
    expect(calls, 3);
    calls = 0;
    final limited = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 429);
        }));
    await expectLater(limited.request('GET', '/anything'),
        throwsA(isA<RateLimitException>()));
    expect(calls, 1);
  });
  test('502 must not replay sandbox creation but can replay GET', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          calls++;
          return calls % 2 == 1
              ? http.Response('', 502, headers: {'retry-after': '0'})
              : http.Response('{}', 200);
        }));
    await expectLater(
        client.request('POST', '/v2/sandboxes', body: {'templateID': 'base'}),
        throwsA(isA<E2BException>()));
    expect(calls, 1);
    calls = 0;
    await client.request('GET', '/sandboxes/s');
    expect(calls, 2);
  });
  test('safe POST replay sends byte-identical body', () async {
    final bodies = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((r) async {
          bodies.add(r.body);
          return bodies.length == 1
              ? http.Response('', 502, headers: {'retry-after': '0'})
              : http.Response('', 204);
        }));
    await client.setTimeout('s', const Duration(seconds: 12));
    expect(bodies, ['{"timeout":12}', '{"timeout":12}']);
  });
  test('cancellation aborts HTTP transport and preserves supplied reason',
      () async {
    final httpClient = AbortClient();
    final signal = CancellationSignal();
    final client = E2BClient(apiKey: 'key', httpClient: httpClient);
    final pending = client.request('GET', '/sandboxes/s',
        options: RequestOptions(signal: signal));
    final assertion =
        expectLater(pending, throwsA(isA<CancellationException>()));
    await httpClient.sent.future;
    signal.cancel();
    await assertion;
    expect(httpClient.aborted, true);
  });
  test('timeout aborts HTTP transport rather than just abandoning Future',
      () async {
    final httpClient = AbortClient();
    final client = E2BClient(
        apiKey: 'key',
        httpClient: httpClient,
        requestTimeout: const Duration(milliseconds: 20));
    await expectLater(client.request('GET', '/sandboxes/s'),
        throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(httpClient.aborted, true);
  });
  test('already canceled request makes no network call', () async {
    var calls = 0;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    final signal = CancellationSignal()..cancel();
    await expectLater(
        client.request('GET', '/anything',
            options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    expect(calls, 0);
  });
  test('backoff is cancellable and obeys total request deadline', () async {
    var calls = 0;
    final signal = CancellationSignal();
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('', 503, headers: {'retry-after': '1'});
        }));
    final assertion = expectLater(
        client.request('GET', '/a', options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    Timer(const Duration(milliseconds: 20), signal.cancel);
    await assertion;
    expect(calls, 1);
    calls = 0;
    await expectLater(
        client.request('GET', '/a',
            options: RequestOptions(
                requestTimeout: const Duration(milliseconds: 10))),
        throwsA(isA<ServiceBusyException>()));
    expect(calls, 1);
  });
  test('per-call headers and credentials do not mutate client or caller map',
      () async {
    final original = {'X-Test': 'base'};
    final seen = <http.Request>[];
    final client = E2BClient(
        apiKey: 'base',
        headers: original,
        httpClient: MockClient((r) async {
          seen.add(r);
          return http.Response('{}', 200);
        }));
    original['X-Test'] = 'mutated';
    await client.request('GET', '/a',
        options:
            RequestOptions(apiKey: 'override', headers: {'X-Test': 'call'}));
    await client.request('GET', '/b');
    expect(seen[0].headers['X-API-Key'], 'override');
    expect(seen[0].headers['X-Test'], 'call');
    expect(seen[1].headers['X-API-Key'], 'base');
    expect(seen[1].headers['X-Test'], 'base');
  });
}
