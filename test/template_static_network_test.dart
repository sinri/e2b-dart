import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test(
      'static Template default client performs build and log polling over HTTP',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    var polls = 0;
    final serving = server.listen((request) async {
      paths.add(request.uri.path);
      expect(request.headers.value('x-api-key'), 'static-template-key');
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/v3/templates') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['name'], 'static-demo');
        expect(body['cpuCount'], 2);
        request.response.write(jsonEncode({
          'templateID': 't',
          'buildID': 'b',
          'tags': ['stable']
        }));
      } else if (request.method == 'POST') {
        expect(request.uri.path, '/v2/templates/t/builds/b');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['fromImage'], 'python:3');
        request.response.statusCode = 204;
      } else {
        expect(request.uri.path, '/templates/t/builds/b/status');
        expect(
            request.uri.queryParameters['logsOffset'], polls == 0 ? '0' : '1');
        polls++;
        request.response.write(jsonEncode({
          'templateID': 't',
          'buildID': 'b',
          'status': 'ready',
          'logs': [],
          'logEntries': polls == 1
              ? [
                  {
                    'timestamp': '2026-10-13T00:00:00Z',
                    'level': 'info',
                    'message': 'cloud-like log'
                  }
                ]
              : []
        }));
      }
      await request.response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });
    final options = RequestOptions(
        apiKey: 'static-template-key',
        apiUrl: Uri.parse('http://127.0.0.1:${server.port}'));
    final logs = <LogEntry>[];
    final info = await Template.build(
        Template().fromPythonImage(), 'static-demo',
        cpuCount: 2,
        tags: ['stable'],
        options: options,
        pollInterval: Duration.zero,
        onBuildLogs: logs.add);
    expect(info.templateId, 't');
    expect(info.tags, ['stable']);
    expect(polls, 2);
    expect(logs.where((entry) => entry.message == 'cloud-like log').length, 1);
    expect(logs.first, isA<LogEntryStart>());
    expect(logs.last, isA<LogEntryEnd>());
    expect(paths.length, 4);
    paths.clear();
    await Template.buildInBackground(
        Template().fromPythonImage(), 'static-demo',
        cpuCount: 2, options: options);
    expect(paths, ['/v3/templates', '/v2/templates/t/builds/b']);
  });
}
