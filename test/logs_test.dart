import 'dart:convert';
import 'dart:async';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _StreamingClient extends http.BaseClient {
  final Stream<List<int>> stream;
  _StreamingClient(this.stream);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

void main() {
  test('stream logger failure reaches wait and releases the output connection',
      () async {
    var canceled = false;
    final events = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final failure = StateError('logger failed');
    final transport = EnvdTransport(
        _StreamingClient(events.stream),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1), logger: Logger(debug: (args) {
      final event = (args[1] as Map)['event'] as Map?;
      if (event?['data'] != null) throw failure;
    }));
    final opening = Commands(transport).start('echo');
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    events.add(envelope({
      'event': {
        'data': {
          'stdout': base64Encode([65])
        }
      }
    }));
    await expectLater(handle.wait(), throwsA(same(failure)));
    await handle.disconnect();
    expect(canceled, true);
    await events.close();
  });

  test('stream logger mutation cannot change command output', () async {
    final events = StreamController<List<int>>();
    final transport = EnvdTransport(
        _StreamingClient(events.stream),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1), logger: Logger(debug: (args) {
      final event = (args[1] as Map)['event'] as Map?;
      if (event?['data'] != null) (event!['data'] as Map)['stdout'] = '';
    }));
    final opening = Commands(transport).start('echo');
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    events.add(envelope({
      'event': {
        'data': {
          'stdout': base64Encode([65])
        }
      }
    }));
    events.add(envelope({
      'event': {
        'end': {'exitCode': 0}
      }
    }));
    expect((await handle.wait()).stdout, 'A');
    await events.close();
  });

  test('management logs request and status with per-call logger isolation',
      () async {
    final info = <List<Object?>>[], errors = <List<Object?>>[];
    final alternate = <List<Object?>>[];
    var calls = 0;
    final client = ApiClient(
        apiKey: 'secret',
        retries: 0,
        logger: Logger(info: info.add, error: errors.add),
        httpClient: MockClient((_) async => ++calls == 1
            ? http.Response('{}', 200, reasonPhrase: 'OK')
            : http.Response('failed', 500, reasonPhrase: 'Failure')));
    addTearDown(client.close);
    await client.request('GET', '/test');
    expect(info, [
      ['Request GET https://api.e2b.app/test'],
      ['Response:', 200, 'OK']
    ]);
    await expectLater(
        client.request('GET', '/test',
            options: RequestOptions(
                logger: Logger(info: alternate.add, error: alternate.add))),
        throwsA(isA<E2BException>()));
    expect(alternate.last, ['Response:', 500, 'Failure']);
    expect(info.length, 2);
    expect(errors, isEmpty);
    expect('$info$alternate', isNot(contains('secret')));
  });

  test('RPC logger receives detached response objects', () async {
    final messages = <List<Object?>>[];
    final transport = EnvdTransport(
        MockClient(
            (_) async => http.Response(jsonEncode({'entries': []}), 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1), logger: Logger(info: (args) {
      messages.add(args);
      if (args.first == 'Response:') (args[1] as Map)['mutated'] = true;
    }));
    final result = await transport.rpc('filesystem.Filesystem', 'ListDir', {});
    expect(result.containsKey('mutated'), false);
    expect(messages.first.first, startsWith('Request: POST '));
    expect(messages.last.first, 'Response:');
  });
}
