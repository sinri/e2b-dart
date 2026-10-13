import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => ConnectionConfig.setIntegration(null));

  test('User-Agent refreshes SDK values and preserves explicit overrides', () {
    final caller = <String, String>{'X-Test': 'value'};
    ConnectionConfig.setIntegration('wrapper/1.0');
    final first = ConnectionConfig(headers: caller);
    expect(first.headers['User-Agent'], 'e2b-dart-sdk/$sdkVersion wrapper/1.0');
    expect(caller, {'X-Test': 'value'});
    ConnectionConfig.setIntegration('wrapper/2.0');
    final rebuilt = ConnectionConfig(headers: first.headers);
    expect(
        rebuilt.headers['User-Agent'], 'e2b-dart-sdk/$sdkVersion wrapper/2.0');
    expect(first.headers['User-Agent'], endsWith('wrapper/1.0'));
    expect(
        ConnectionConfig(headers: {'User-Agent': 'custom'})
            .headers['User-Agent'],
        'custom');
    expect(
        ConnectionConfig(
            headers: {'User-Agent': 'custom'},
            apiHeaders: {'User-Agent': 'api-custom'}).headers['User-Agent'],
        'api-custom');
  });

  test('management metadata identifies Dart and allows caller overrides',
      () async {
    final client = ApiClient(
        apiKey: 'key',
        headers: {'publisher': 'wrapper'},
        httpClient: MockClient((request) async {
          expect(request.headers['lang'], 'dart');
          expect(request.headers['lang_version'],
              Platform.version.split(' ').first);
          expect(request.headers['package_version'], sdkVersion);
          expect(request.headers['sdk_runtime'], 'dart');
          expect(request.headers['system'], Platform.operatingSystem);
          expect(request.headers['publisher'], 'wrapper');
          expect(request.headers['User-Agent'], 'e2b-dart-sdk/$sdkVersion');
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    await client.request('GET', '/test');
  });

  test('only bound User-Agent reaches sandbox requests', () async {
    final client = E2BClient(
        apiKey: 'key',
        headers: {'X-Custom': 'bound'},
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/connect')) {
            return http.Response(
                jsonEncode({
                  'sandboxID': 's',
                  'envdVersion': '0.6.4',
                  'domain': 'e2b.app',
                }),
                200);
          }
          expect(request.headers['X-Custom'], isNull);
          expect(request.headers['User-Agent'], 'e2b-dart-sdk/$sdkVersion');
          expect(request.headers.keys.map((s) => s.toLowerCase()),
              isNot(contains('x-api-key')));
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    final sandbox = await client.connect('s');
    await sandbox.files.makeDir('/directory');
  });
}
