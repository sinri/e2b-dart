import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

Future<bool> forwardTunnel(HttpRequest request, {String? credentials}) async {
  if (request.method != 'CONNECT') return false;
  expect(request.headers.value('x-api-key'), isNull);
  if (credentials != null &&
      request.headers.value('proxy-authorization') != credentials) {
    request.response.statusCode = 407;
    request.response.headers.set('proxy-authenticate', 'Basic realm="test"');
    await request.response.close();
    return true;
  }
  final upstream =
      await Socket.connect('127.0.0.1', request.connectionInfo!.localPort);
  request.response.statusCode = 200;
  request.response.contentLength = 0;
  final downstream = await request.response.detachSocket();
  addTearDown(() {
    upstream.destroy();
    downstream.destroy();
  });
  unawaited(upstream.addStream(downstream).then((_) => upstream.close(),
      onError: (Object _) {
    upstream.destroy();
  }));
  unawaited(downstream.addStream(upstream).then((_) => downstream.close(),
      onError: (Object _) {
    downstream.destroy();
  }));
  return true;
}

void main() {
  test('volume content inherits creation proxy and supports per-call overrides',
      () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => first.close(force: true));
    addTearDown(() => second.close(force: true));
    final seen = <String>[];
    void serve(HttpServer server, String label) {
      final subscription = server.listen((request) async {
        if (await forwardTunnel(request)) return;
        seen.add('$label ${request.method} ${request.uri.path}');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/volumes') {
          request.response
              .write('{"volumeID":"v","name":"test","token":"volume-token"}');
        } else {
          expect(request.headers.value('authorization'), 'Bearer volume-token');
          expect(request.headers.value('x-api-key'), isNull);
          request.response.write('content');
        }
        await request.response.close();
      });
      addTearDown(subscription.cancel);
    }

    serve(first, 'first');
    serve(second, 'second');
    final firstUrl = 'http://127.0.0.1:${first.port}';
    final secondUrl = 'http://127.0.0.1:${second.port}';
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        proxy: firstUrl,
        apiUrl: Uri.parse('http://control.invalid'),
        volumeApiUrl: Uri.parse('http://content.invalid'));
    addTearDown(client.close);
    final volume = await client.volumes
        .create('test', options: RequestOptions(proxy: secondUrl));
    expect(await volume.readFile('/a'), 'content');
    expect(
        await volume.readFile('/b',
            options: VolumeRequestOptions(proxy: firstUrl)),
        'content');
    expect(
        await volume.readFile('/c', options: VolumeRequestOptions(proxy: '')),
        'content');
    expect(await volume.readStream('/d').expand((bytes) => bytes).toList(),
        utf8.encode('content'));
    expect(seen, [
      'second POST /volumes',
      'second GET /volumecontent/v/file',
      'first GET /volumecontent/v/file',
      'second GET /volumecontent/v/file',
      'second GET /volumecontent/v/file',
    ]);
  });

  test('per-call proxy selection is inherited by sandbox and isolated per RPC',
      () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => first.close(force: true));
    addTearDown(() => second.close(force: true));
    final seen = <String>[];
    void serve(HttpServer server, String label) {
      final subscription = server.listen((request) async {
        if (await forwardTunnel(request)) return;
        seen.add('$label ${request.uri.path}');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(request.uri.path.endsWith('/connect')
            ? '{"sandboxID":"s","envdVersion":"0.6.4"}'
            : '{}');
        await request.response.close();
      });
      addTearDown(subscription.cancel);
    }

    serve(first, 'first');
    serve(second, 'second');
    final firstUrl = 'http://127.0.0.1:${first.port}';
    final secondUrl = 'http://127.0.0.1:${second.port}';
    final client = E2BClient(
        apiKey: 'key',
        retries: 0,
        proxy: firstUrl,
        apiUrl: Uri.parse('http://control.invalid'),
        sandboxUrl: Uri.parse('http://sandbox.invalid'));
    addTearDown(client.close);
    final sandbox =
        await client.connect('s', options: RequestOptions(proxy: secondUrl));
    await sandbox.files.makeDir('/a');
    await sandbox.files.makeDir('/b', options: RequestOptions(proxy: firstUrl));
    client.withOptions(RequestOptions(proxy: secondUrl)).close();
    await client.getInfo('s');
    expect(seen, [
      'second /v2/sandboxes/s/connect',
      'second /filesystem.Filesystem/MakeDir',
      'first /filesystem.Filesystem/MakeDir',
      'first /sandboxes/s',
    ]);
    client.close();
    expect(() => client.httpClient, throwsStateError);
  });

  for (final authenticated in [false, true]) {
    test('native HTTP proxy routes management requests auth=$authenticated',
        () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var received = 0;
      final credentials = 'Basic ${base64Encode(utf8.encode('user:p:ass'))}';
      final subscription = proxy.listen((request) async {
        if (await forwardTunnel(request,
            credentials: authenticated ? credentials : null)) {
          return;
        }
        received++;
        expect(request.headers.host, 'target.invalid');
        expect(request.uri.path, '/test');
        expect(request.headers.value('proxy-authorization'), isNull);
        expect(request.headers.value('x-api-key'), 'key');
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"proxied":true}');
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final userInfo = authenticated ? 'user:p%3Aass@' : '';
      final client = ApiClient(
          apiKey: 'key',
          retries: 0,
          apiUrl: Uri.parse('http://target.invalid'),
          proxy: 'http://${userInfo}127.0.0.1:${proxy.port}');
      addTearDown(client.close);
      expect(await client.request('GET', '/test'), {'proxied': true});
      expect(received, 1);
    });
  }
}
