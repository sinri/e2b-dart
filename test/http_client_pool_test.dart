import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/http_client_pool.dart';
import 'package:e2b/src/http_dispatch_config.dart';
import 'package:e2b/src/transport.dart';
import 'package:e2b/src/http2_client_io.dart';
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('native pool caches direct transports by protocol and proxy', () {
    final pool = HttpClientPool();
    addTearDown(pool.close);
    final h2 = pool.get(null, httpVersion: '2');
    final h1 = pool.get(null, httpVersion: '1.1');
    expect(h2, isA<Http2Client>());
    expect(h1, isA<IOClient>());
    expect(pool.get(null, httpVersion: '2'), same(h2));
    expect(pool.get(null, httpVersion: '1.1'), same(h1));
    final proxy = pool.get('http://localhost:1234', httpVersion: '2');
    expect(proxy, isA<Http2Client>());
    expect(proxy, isNot(same(h1)));
    expect(pool.get('http://localhost:1234', httpVersion: '2'), same(proxy));
    expect(() => pool.get(null, httpVersion: '3'), throwsArgumentError);
    pool.close();
    expect(() => pool.get(null), throwsStateError);
  });

  test('API per-call version selects transport without changing its default',
      () {
    final client = ApiClient(apiKey: 'test', httpVersion: '1.1');
    addTearDown(client.close);
    final initial = client.httpClient;
    expect(initial, isA<IOClient>());
    expect(client.httpClientFor(RequestOptions(httpVersion: '2')),
        isA<Http2Client>());
    expect(client.httpClientFor(null), same(initial));
  });

  test('management REST and RPC keep independent pools and option routing', () {
    final api = ApiClient(apiKey: 'test');
    addTearDown(api.close);
    final management = api.httpClient;
    final rest = api.envdHttpClientFor(null);
    final rpc = api.envdHttpClientFor(null, rpc: true);
    expect(rest, isNot(same(management)));
    expect(rpc, isNot(same(rest)));
    expect(api.envdHttpClientFor(null), same(rest));
    final transport = EnvdTransport(
        rpc, Uri.parse('https://test.invalid'), {}, const Duration(seconds: 1),
        restClient: rest,
        clientResolver: (options) => api.envdHttpClientFor(options, rpc: true),
        restClientResolver: api.envdHttpClientFor);
    final options = RequestOptions(httpVersion: '1.1');
    final derived = transport.withOptions(options);
    expect(derived.client, same(api.envdHttpClientFor(options, rpc: true)));
    expect(derived.restClient, same(api.envdHttpClientFor(options)));
    expect(derived.client, isNot(same(derived.restClient)));
    expect(transport.client, same(rpc));
    expect(transport.restClient, same(rest));
    expect(inflightLimitFor(HttpDispatchScope.envdRest), 2000);
    expect(inflightLimitFor(HttpDispatchScope.envdRpc), 2000);
  });

  test('root clients share transports and close only their final lease',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final keys = <String?>[];
    server.listen((request) async {
      keys.add(request.headers.value('x-api-key'));
      request.response.write('{}');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    final first = ApiClient(apiKey: 'first', apiUrl: uri, retries: 0);
    final second = ApiClient(apiKey: 'second', apiUrl: uri, retries: 0);
    addTearDown(first.close);
    addTearDown(second.close);
    final transport = first.httpClient;
    expect(second.httpClient, same(transport));
    expect(first.envdHttpClientFor(null), same(second.envdHttpClientFor(null)));
    expect(first.envdHttpClientFor(null, rpc: true),
        same(second.envdHttpClientFor(null, rpc: true)));
    await first.requestResponse('GET', '/');
    first.close();
    first.close();
    await second.requestResponse('GET', '/');
    expect(keys, ['first', 'second']);
    second.close();
    final third = ApiClient(apiKey: 'third', apiUrl: uri, retries: 0);
    addTearDown(third.close);
    expect(third.httpClient, isNot(same(transport)));
    await third.requestResponse('GET', '/');
    expect(keys, ['first', 'second', 'third']);
  });

  test('explicit transport remains authoritative for either version', () async {
    final transport = MockClient((request) async => http.Response('{}', 200));
    final client = ApiClient(apiKey: 'test', httpClient: transport);
    expect(client.httpClientFor(RequestOptions(httpVersion: '1.1')),
        same(transport));
    expect(client.httpClientFor(RequestOptions(httpVersion: '2')),
        same(transport));
    client.close();
    expect((await transport.get(Uri.parse('https://example.test'))).statusCode,
        200);
    transport.close();
  });
}
