import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('typed MCP names include dynamic GitHub repositories', () {
    final name = McpServerName.githubRepository('owner/repo');
    expect(name.name, 'github/owner/repo');
    expect(name, McpServerName.githubRepository('owner/repo'));
    expect(
        name.hashCode, McpServerName.githubRepository('owner/repo').hashCode);
    expect(name, isNot(McpServerName.githubRepository('other/repo')));
    final template = Template()
        .fromTemplate('mcp-gateway')
        .addMcpServer([McpServerName.brave, name]);
    expect(template.instructions.last.args.first,
        'mcp-gateway pull brave github/owner/repo');
  });

  test('all typed MCP names produce the official gateway pull command', () {
    expect(McpServerName.values.length, 265);
    for (final name in McpServerName.values) {
      final template =
          Template().fromTemplate('mcp-gateway').addMcpServer(name);
      expect(template.instructions.last.args,
          ['mcp-gateway pull ${name.name}', 'root']);
    }
    final mixed = Template()
        .fromTemplate('mcp-gateway')
        .addMcpServer([McpServerName.brave, 'fetch']);
    expect(
        mixed.instructions.last.args, ['mcp-gateway pull brave fetch', 'root']);
    expect(() => Template().addMcpServer(McpServerName.brave),
        throwsA(isA<BuildException>()));
  });

  test('typed MCP config serializes gateway and custom GitHub servers',
      () async {
    const config = McpServer(
      brave: McpBraveConfig(apiKey: 'example-key'),
      fetch: McpFetchConfig(),
      githubRepositories: {
        'owner/repo': GitHubMcpServerConfig(
            runCmd: 'node index.js',
            installCmd: 'npm install',
            envs: {'A': 'B'})
      },
    );
    final client = E2BClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['templateID'], 'mcp-gateway');
          expect(body['mcp'], {
            'brave': {'apiKey': 'example-key'},
            'fetch': {},
            'github/owner/repo': {
              'runCmd': 'node index.js',
              'installCmd': 'npm install',
              'envs': {'A': 'B'}
            },
          });
          return http.Response('{"sandboxID":"s","envdVersion":"0.6.4"}', 200);
        }));
    addTearDown(client.close);
    await client.create(mcp: config);
    expect(const McpServer().toJson(), isEmpty);
  });
}
