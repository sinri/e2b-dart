import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('direct sandbox paginator owns HTTP clients and retains failed cursor',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final keys = <String?>[];
    final cursors = <String?>[];
    final states = <String?>[];
    final serving = server.listen((request) async {
      keys.add(request.headers.value('x-api-key'));
      cursors.add(request.uri.queryParameters['nextToken']);
      states.add(request.uri.queryParameters['state']);
      expect(request.uri.path, '/v2/sandboxes');
      expect(request.uri.queryParameters['limit'], '2');
      request.response.headers.contentType = ContentType.json;
      if (keys.length == 2) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'message': 'denied'}));
      } else {
        if (keys.length == 1) {
          request.response.headers.set('x-next-token', 'next');
        }
        request.response.write('[]');
      }
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final state = <SandboxState>['running'];
    final paginator = SandboxPaginator(
        limit: 2,
        nextToken: 'initial',
        state: state,
        options: RequestOptions(
            apiKey: 'bound',
            retries: 0,
            apiUrl: Uri.parse('http://127.0.0.1:${server.port}')));
    expect(await paginator.nextItems(), isEmpty);
    state.add('paused');
    await expectLater(paginator.nextItems(), throwsA(isA<SandboxException>()));
    expect(paginator.nextToken, 'next');
    expect(paginator.hasNext, isTrue);
    expect(await paginator.nextItems(options: RequestOptions(apiKey: 'call')),
        isEmpty);
    expect(paginator.hasNext, isFalse);
    expect(keys, ['bound', 'bound', 'call']);
    expect(cursors, ['initial', 'next', 'next']);
    expect(states, ['running', 'running,paused', 'running,paused']);
    await expectLater(paginator.nextItems(), throwsStateError);
    expect(keys, hasLength(3));
  });
}
