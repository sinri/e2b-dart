import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('empty connection strings resolve defaults like official JS options',
      () {
    final defaults = ConnectionConfig();
    final empty = ConnectionConfig(
        domain: '', apiUrl: Uri.parse(''), sandboxUrl: Uri.parse(''));
    expect(empty.domain, defaults.domain);
    expect(empty.apiUrl, defaults.apiUrl);
    expect(empty.sandboxUrl, defaults.sandboxUrl);
    final explicit = ConnectionConfig(
        domain: 'custom.test',
        apiUrl: Uri.parse('https://control.test'),
        sandboxUrl: Uri.parse('https://sandbox.test'));
    expect(explicit.domain, 'custom.test');
    expect(explicit.apiUrl.host, 'control.test');
    expect(explicit.sandboxUrl!.host, 'sandbox.test');
  });

  test('per-call sandbox URL binds returned sandbox without changing defaults',
      () async {
    final hosts = <String>[];
    final client = E2BClient(
        apiKey: 'key',
        sandboxUrl: Uri.parse('https://default.test'),
        httpClient: MockClient((request) async {
          if (request.url.host.startsWith('api.')) {
            return http.Response(
                jsonEncode({
                  'sandboxID': 's',
                  'envdVersion': '0.6.4',
                }),
                200);
          }
          hosts.add(request.url.host);
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    final options =
        RequestOptions(sandboxUrl: Uri.parse('https://override.test'));
    final created = await client.create(options: options);
    await created.files.makeDir('/a');
    final connected = await client.connect('s', options: options);
    await connected.files.makeDir('/b');
    final inherited = await client.connect('s');
    await inherited.files.makeDir('/c');
    expect(hosts, ['override.test', 'override.test', 'default.test']);
    expect(RequestOptions.merge(options, RequestOptions())!.sandboxUrl,
        options.sandboxUrl);
  });

  test('native hosted API endpoints and direct URLs follow official routing',
      () {
    for (final domain in ['e2b.app', 'e2b.dev', 'e2b.pro', 'e2b-staging.dev']) {
      final config = ConnectionConfig(domain: domain);
      expect(config.getSandboxUrl('s').toString(), 'https://sandbox.$domain');
      expect(config.getSandboxDirectUrl('s').toString(),
          'https://49983-s.$domain');
    }
    final config = ConnectionConfig(domain: 'custom.example');
    expect(config.getSandboxUrl('s').host, '49983-s.custom.example');
    expect(config.getSandboxUrl('s', sandboxDomain: 'e2b.dev').host,
        'sandbox.e2b.dev');
    expect(config.getSandboxDirectUrl('s', envdPort: 42).host,
        '42-s.custom.example');
  });

  test('explicit sandbox URL wins over debug and sandbox domain', () {
    final config = ConnectionConfig(
        debug: true, sandboxUrl: Uri.parse('http://proxy.example/envd'));
    expect(config.getSandboxUrl('s'), config.sandboxUrl);
    expect(config.getSandboxDirectUrl('s'), config.sandboxUrl);
    final debug = ConnectionConfig(debug: true);
    expect(debug.getSandboxUrl('s').toString(), 'http://localhost:49983');
    expect(debug.getSandboxDirectUrl('s', envdPort: 42).toString(),
        'http://localhost:42');
  });

  test('sandbox RPC uses shared endpoint while signed URLs stay direct',
      () async {
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/connect')) {
            return http.Response(
                jsonEncode({
                  'sandboxID': 's',
                  'domain': 'e2b.dev',
                  'envdVersion': '0.6.4',
                }),
                200);
          }
          expect(request.url.host, 'sandbox.e2b.dev');
          expect(request.headers['E2b-Sandbox-Id'], 's');
          expect(request.headers['E2b-Sandbox-Port'], '49983');
          return http.Response('{}', 200);
        }));
    addTearDown(client.close);
    final sandbox = await client.connect('s');
    await sandbox.files.makeDir('/a');
    expect(sandbox.downloadUrl('/a').host, '49983-s.e2b.dev');
    expect(sandbox.uploadUrl().host, '49983-s.e2b.dev');
  });
}
