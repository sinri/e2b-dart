import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:e2b/src/http2_client_io.dart';
import 'package:e2b/src/http_client_io.dart' as native;
import 'package:e2b/e2b.dart' show ApiClient;
import 'package:http/http.dart' as http;
import 'package:http2/transport.dart';
import 'package:test/test.dart';

void main() {
  for (final explicitH1 in [false, true]) {
    test('HTTP1 compression preserves wire headers explicitH1=$explicitH1',
        () async {
      final plain = utf8.encode('compressed fallback 世界');
      final vectors = <String, List<int>>{
        'gzip': gzip.encode(plain),
        'x-gzip': gzip.encode(plain),
        'deflate': zlib.encode(plain),
        'DEFLATE': ZLibEncoder(raw: true).convert(plain),
        'gzip, deflate': zlib.encode(gzip.encode(plain)),
      };
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final encoding = request.uri.queryParameters['encoding']!;
        final bytes = vectors[encoding]!;
        request.response.headers.set('content-encoding', encoding);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final client = explicitH1
          ? native.createHttpClient(null, httpVersion: '1.1')
          : Http2Client();
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      for (final entry in vectors.entries) {
        final uri =
            Uri.http('localhost:${server.port}', '/', {'encoding': entry.key});
        final response = await client.get(uri);
        expect(response.bodyBytes, plain);
        expect(response.headers['content-encoding'], entry.key);
        expect(response.headers['content-length'], '${entry.value.length}');
      }
    });
  }
  Future<(Uri, Http2Client)> setup(
      void Function(ServerTransportStream) handle) async {
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/http2-local-cert.pem')
      ..usePrivateKey('test/fixtures/http2-local-key.pem')
      ..setAlpnProtocols(['h2'], true);
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, context,
        supportedProtocols: ['h2']);
    final transports = <ServerTransportConnection>[];
    server.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      final transport = ServerTransportConnection.viaSocket(socket);
      transports.add(transport);
      transport.incomingStreams.listen(handle);
    });
    final client = Http2Client(
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    addTearDown(() async {
      client.close();
      for (final transport in transports) {
        await transport.terminate();
      }
      await server.close();
    });
    return (Uri.parse('https://localhost:${server.port}/'), client);
  }

  test('default API transport negotiates h2 without an injected client',
      () async {
    SecurityContext.defaultContext
        .setTrustedCertificates('test/fixtures/http2-local-cert.pem');
    final (uri, _) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final headers = {
        for (final header
            in messages.whereType<HeadersStreamMessage>().first.headers)
          utf8.decode(header.name): utf8.decode(header.value)
      };
      expect(headers[':path'], '/health');
      expect(headers['x-api-key'], 'test-key');
      stream.sendHeaders([Header.ascii(':status', '200')]);
      stream.sendData(utf8.encode('{"transport":"h2"}'), endStream: true);
    });
    final api = ApiClient(apiKey: 'test-key', apiUrl: uri, retries: 0);
    addTearDown(api.close);
    final response = await api.requestResponse('GET', '/health');
    expect(jsonDecode(response.body), {'transport': 'h2'});
  });

  test('independent API roots reuse h2 and closing one preserves the other',
      () async {
    SecurityContext.defaultContext
        .setTrustedCertificates('test/fixtures/http2-local-cert.pem');
    final keys = <String>[];
    final (uri, _) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final headers = messages.whereType<HeadersStreamMessage>().first.headers;
      keys.add(utf8.decode(headers
          .firstWhere((header) => utf8.decode(header.name) == 'x-api-key')
          .value));
      stream.sendHeaders([Header.ascii(':status', '200')]);
      stream.sendData(utf8.encode(jsonEncode({'stream': stream.id})),
          endStream: true);
    });
    final first = ApiClient(apiKey: 'first', apiUrl: uri, retries: 0);
    final second = ApiClient(apiKey: 'second', apiUrl: uri, retries: 0);
    addTearDown(first.close);
    addTearDown(second.close);
    expect(jsonDecode((await first.requestResponse('GET', '/')).body)['stream'],
        1);
    expect(
        jsonDecode((await second.requestResponse('GET', '/')).body)['stream'],
        3);
    first.close();
    expect(
        jsonDecode((await second.requestResponse('GET', '/')).body)['stream'],
        5);
    expect(keys, ['first', 'second', 'second']);
  });

  test('HTTP/2 adapter forwards request body and streams response headers/data',
      () async {
    final (uri, client) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final headers = {
        for (final header
            in messages.whereType<HeadersStreamMessage>().first.headers)
          utf8.decode(header.name): utf8.decode(header.value)
      };
      expect(headers[':method'], 'POST');
      expect(headers[':path'], '/echo?q=a%20b');
      expect(headers['x-custom'], 'value');
      final bytes = messages
          .whereType<DataStreamMessage>()
          .expand((message) => message.bytes)
          .toList();
      expect(utf8.decode(bytes), 'hello世界');
      stream.sendHeaders(
          [Header.ascii(':status', '201'), Header.ascii('x-reply', 'yes')]);
      stream.sendData(bytes, endStream: true);
    });
    final response = await client.post(uri.resolve('echo?q=a%20b'),
        headers: {'X-Custom': 'value'}, body: utf8.encode('hello世界'));
    expect(response.statusCode, 201);
    expect(response.headers['x-reply'], 'yes');
    expect(utf8.decode(response.bodyBytes), 'hello世界');
  });

  test('abort before response headers leaves the shared connection usable',
      () async {
    final waiting = Completer<void>();
    var requests = 0;
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      if (++requests == 1) {
        waiting.complete();
        return;
      }
      stream.sendHeaders([Header.ascii(':status', '200')]);
      stream.sendData(utf8.encode('next'), endStream: true);
    });
    final abort = Completer<void>();
    final response = client
        .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future));
    final checked =
        expectLater(response, throwsA(isA<http.RequestAbortedException>()));
    await waiting.future;
    abort.complete();
    await checked;
    expect((await client.get(uri)).body, 'next');
  });

  test('ALPN HTTP/1.1 fallback reuses the negotiated TLS socket', () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain('test/fixtures/http2-local-cert.pem')
          ..usePrivateKey('test/fixtures/http2-local-key.pem'),
        supportedProtocols: ['http/1.1']);
    final peers = <SecureSocket>[];
    server.listen((socket) {
      peers.add(socket);
      var buffered = '';
      socket.listen((bytes) {
        buffered += latin1.decode(bytes);
        if (!buffered.contains('\r\n\r\n')) return;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
        buffered = '';
      });
    });
    final client = Http2Client(
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    addTearDown(() async {
      client.close();
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    });
    final uri = Uri.parse('https://localhost:${server.port}/');
    for (var i = 0; i < 2; i++) {
      expect((await client.get(uri).timeout(const Duration(seconds: 3))).body,
          'ok');
    }
    expect(peers.length, 1);
  });

  test('cleartext request falls back to HTTP/1.1', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('fallback');
      await request.response.close();
    });
    final client = Http2Client();
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    expect(
        (await client.get(Uri.parse('http://localhost:${server.port}/'))).body,
        'fallback');
  });
  test('abort while streaming reports RequestAbortedException', () async {
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders([Header.ascii(':status', '200')]);
      stream.sendData(utf8.encode('first'));
    });
    final abort = Completer<void>();
    final response = await client
        .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future));
    final first = Completer<void>();
    final result = response.stream.map((chunk) {
      if (!first.isCompleted) first.complete();
      return chunk;
    }).drain<void>();
    final checked =
        expectLater(result, throwsA(isA<http.RequestAbortedException>()));
    await first.future;
    abort.complete();
    await checked;
  });

  for (final encoding in ['gzip', 'deflate', 'gzip, deflate']) {
    for (final partial in [false, true]) {
      test('h2 $encoding cancel resets stream partial=$partial', () async {
        final reset = Completer<void>();
        final ids = <int>[];
        final (uri, client) = await setup((stream) async {
          await stream.incomingMessages.drain<void>();
          ids.add(stream.id);
          if (ids.length == 1) {
            stream.onTerminated = (_) {
              if (!reset.isCompleted) reset.complete();
            };
            stream.sendHeaders([
              Header.ascii(':status', '200'),
              Header.ascii('content-encoding', encoding),
            ]);
            if (partial) {
              stream.sendData([encoding == 'gzip' ? 0x1f : 0x78]);
            }
          } else {
            stream.sendHeaders([Header.ascii(':status', '200')]);
            stream.sendData(utf8.encode('next'), endStream: true);
          }
        });
        final response = await client.send(http.Request('GET', uri));
        final subscription = response.stream.listen((_) {});
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel().timeout(const Duration(seconds: 2));
        await reset.future.timeout(const Duration(seconds: 2));
        expect((await client.get(uri)).body, 'next');
        expect(ids, [1, 3]);
      });
    }
  }

  test('consumer cancellation resets its stream and preserves the connection',
      () async {
    final reset = Completer<void>();
    var requests = 0;
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders([Header.ascii(':status', '200')]);
      if (++requests == 1) {
        stream.onTerminated = (_) {
          if (!reset.isCompleted) reset.complete();
        };
        stream.sendData(utf8.encode('first'));
      } else {
        stream.sendData(utf8.encode('next'), endStream: true);
      }
    });
    final response = await client.send(http.Request('GET', uri));
    final body = StreamIterator(response.stream);
    expect(await body.moveNext(), true);
    expect(utf8.decode(body.current), 'first');
    await body.cancel();
    await reset.future.timeout(const Duration(seconds: 2));
    expect((await client.get(uri)).body, 'next');
  });
  test(
      'gzip/deflate and stacked encodings decode while preserving wire headers',
      () async {
    final plain = utf8.encode('hello世界' * 100);
    final cases = <String, List<int>>{
      'gzip': gzip.encode(plain),
      'GZIP': gzip.encode(plain),
      'x-gzip': gzip.encode(plain),
      'deflate': zlib.encode(plain),
      'gzip, deflate': zlib.encode(gzip.encode(plain)),
    };
    final (uri, client) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final path = utf8.decode(messages
          .whereType<HeadersStreamMessage>()
          .first
          .headers
          .firstWhere((header) => utf8.decode(header.name) == ':path')
          .value);
      final encoding = Uri.decodeComponent(path.substring(1));
      final compressed = cases[encoding]!;
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        Header.ascii('content-encoding', encoding),
        Header.ascii('content-length', '${compressed.length}'),
      ]);
      for (var offset = 0; offset < compressed.length; offset += 3) {
        final end =
            offset + 3 < compressed.length ? offset + 3 : compressed.length;
        stream.sendData(compressed.sublist(offset, end),
            endStream: end == compressed.length);
      }
    });
    for (final entry in cases.entries) {
      final response =
          await client.get(uri.resolve(Uri.encodeComponent(entry.key)));
      expect(response.bodyBytes, plain);
      expect(response.headers['content-encoding'], entry.key);
      expect(response.headers['content-length'], '${entry.value.length}');
    }
  });

  test(
      'malformed gzip fails response consumption without poisoning the connection',
      () async {
    var requests = 0;
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      final bad = ++requests == 1;
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        if (bad) Header.ascii('content-encoding', 'gzip'),
      ]);
      stream.sendData(utf8.encode(bad ? 'not gzip' : 'next'), endStream: true);
    });
    await expectLater(client.get(uri), throwsA(isA<FormatException>()));
    expect((await client.get(uri)).body, 'next');
  });
  test('raw deflate response decodes without a zlib wrapper', () async {
    final plain = utf8.encode('raw deflate世界');
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        Header.ascii('content-encoding', 'deflate')
      ]);
      final compressed = ZLibEncoder(raw: true).convert(plain);
      stream.sendData(compressed.sublist(0, 1));
      stream.sendData(compressed.sublist(1), endStream: true);
    });
    expect((await client.get(uri)).bodyBytes, plain);
  });
  test('unsupported x-deflate encoding stays opaque like Node fetch', () async {
    final compressed = zlib.encode(utf8.encode('hello'));
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders([
        Header.ascii(':status', '200'),
        Header.ascii('content-encoding', 'x-deflate')
      ]);
      stream.sendData(compressed, endStream: true);
    });
    expect((await client.get(uri)).bodyBytes, compressed);
  });
  test('redirect method/body matrix cancels unread intermediate streams',
      () async {
    for (final status in [301, 302, 303, 307, 308]) {
      for (final method in ['POST', 'PUT', 'PATCH', 'GET', 'HEAD']) {
        final vectors = jsonDecode(
            File('test/http_redirect_vectors.json').readAsStringSync()) as List;
        final vector = vectors.cast<Map<String, dynamic>>().firstWhere(
            (row) => row['status'] == status && row['method'] == method);
        final reset = Completer<void>();
        final drop = ((status == 301 || status == 302) && method == 'POST') ||
            (status == 303 && method != 'GET' && method != 'HEAD');
        final (uri, client) = await setup((stream) async {
          final messages = await stream.incomingMessages.toList();
          final headers = {
            for (final h
                in messages.whereType<HeadersStreamMessage>().first.headers)
              utf8.decode(h.name): utf8.decode(h.value)
          };
          if (headers[':path'] == '/') {
            stream.onTerminated = (_) {
              if (!reset.isCompleted) reset.complete();
            };
            stream.sendHeaders([
              Header.ascii(':status', '$status'),
              Header.ascii('location', '/target')
            ]);
            // Deliberately leave the response body open. Following must cancel it.
          } else {
            expect(headers[':method'], vector['expectedMethod']);
            expect(headers['content-type'],
                drop ? isNull : 'text/plain; charset=utf-8');
            expect(headers['authorization'], 'Bearer same-origin');
            final body = messages
                .whereType<DataStreamMessage>()
                .expand((m) => m.bytes)
                .toList();
            expect(utf8.decode(body), vector['expectedBody']);
            stream
                .sendHeaders([Header.ascii(':status', '200')], endStream: true);
          }
        });
        final request = http.Request(method, uri)
          ..headers['content-type'] = 'text/plain'
          ..headers['authorization'] = 'Bearer same-origin'
          ..body = ['GET', 'HEAD'].contains(method) ? '' : 'payload';
        final response = await client.send(request);
        expect(response.statusCode, 200);
        await response.stream.drain<void>();
        await reset.future.timeout(const Duration(seconds: 2));
      }
    }
  });

  test('redirects honor manual mode and the configured limit', () async {
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders(
          [Header.ascii(':status', '302'), Header.ascii('location', '/')],
          endStream: true);
    });
    final manual =
        await client.send(http.Request('GET', uri)..followRedirects = false);
    expect(manual.statusCode, 302);
    await manual.stream.drain<void>();
    await expectLater(
        client.send(http.Request('GET', uri)..maxRedirects = 2),
        throwsA(isA<http.ClientException>().having(
            (error) => error.message, 'message', 'Redirect limit exceeded')));
  });

  test(
      'cross-origin redirect strips credentials while retaining custom API headers',
      () async {
    final (target, _) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final headers = {
        for (final h
            in messages.whereType<HeadersStreamMessage>().first.headers)
          utf8.decode(h.name): utf8.decode(h.value)
      };
      expect(headers['authorization'], isNull);
      expect(headers['cookie'], isNull);
      expect(headers['proxy-authorization'], isNull);
      expect(headers['x-api-key'], 'custom-key');
      stream.sendHeaders([Header.ascii(':status', '200')], endStream: true);
    });
    final (uri, client) = await setup((stream) async {
      await stream.incomingMessages.drain<void>();
      stream.sendHeaders([
        Header.ascii(':status', '302'),
        Header.ascii('location', target.toString())
      ], endStream: true);
    });
    final response = await client.get(uri, headers: {
      'Authorization': 'Bearer private',
      'Cookie': 'session=private',
      'Proxy-Authorization': 'Basic private',
      'X-API-Key': 'custom-key',
    });
    expect(response.statusCode, 200);
  });
  test('SDK management requests allow the Fetch default twenty redirects',
      () async {
    var requests = 0;
    final (uri, transport) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final path = utf8.decode(messages
          .whereType<HeadersStreamMessage>()
          .first
          .headers
          .firstWhere((header) => utf8.decode(header.name) == ':path')
          .value);
      final step = int.parse(path.substring(1));
      requests++;
      if (step < 20) {
        stream.sendHeaders([
          Header.ascii(':status', '302'),
          Header.ascii('location', '/${step + 1}')
        ], endStream: true);
      } else {
        stream.sendHeaders([Header.ascii(':status', '200')]);
        stream.sendData(utf8.encode('{"done":true}'), endStream: true);
      }
    });
    final client = ApiClient(apiKey: 'key', apiUrl: uri, httpClient: transport);
    addTearDown(client.close);
    expect(await client.request('GET', '/0'), {'done': true});
    expect(requests, 21);
  });
  test(
      'streaming redirects match Node including empty streams and 301/302 rejection',
      () async {
    final vectors = jsonDecode(
            File('test/http_redirect_stream_vectors.json').readAsStringSync())
        as List;
    for (final vector in vectors.cast<Map<String, dynamic>>()) {
      var calls = 0;
      final (uri, client) = await setup((stream) async {
        final messages = await stream.incomingMessages.toList();
        if (++calls == 1) {
          stream.sendHeaders([
            Header.ascii(':status', '${vector['status']}'),
            Header.ascii('location', '/target')
          ], endStream: true);
        } else {
          final headers = {
            for (final h
                in messages.whereType<HeadersStreamMessage>().first.headers)
              utf8.decode(h.name): utf8.decode(h.value)
          };
          expect(headers[':method'], vector['expectedMethod']);
          expect(messages.whereType<DataStreamMessage>().expand((m) => m.bytes),
              isEmpty);
          stream.sendHeaders([Header.ascii(':status', '200')], endStream: true);
        }
      });
      final bytes = utf8.encode(vector['body'] as String);
      final request = http.StreamedRequest('POST', uri)
        ..contentLength = bytes.length;
      request.sink.add(bytes);
      unawaited(request.sink.close());
      if (vector['rejected'] == true) {
        await expectLater(
            client.send(request),
            throwsA(isA<http.ClientException>().having(
                (error) => error.message,
                'message',
                'Cannot replay a streaming request body after redirect')));
        expect(calls, 1);
      } else {
        final response = await client.send(request);
        expect(response.statusCode, 200);
        await response.stream.drain<void>();
        expect(calls, 2);
      }
    }
  });
  test('abort signal remains active after a redirect and isolates its stream',
      () async {
    final targetStarted = Completer<void>();
    final (uri, client) = await setup((stream) async {
      final messages = await stream.incomingMessages.toList();
      final path = utf8.decode(messages
          .whereType<HeadersStreamMessage>()
          .first
          .headers
          .firstWhere((header) => utf8.decode(header.name) == ':path')
          .value);
      if (path == '/') {
        stream.sendHeaders([
          Header.ascii(':status', '302'),
          Header.ascii('location', '/target')
        ], endStream: true);
      } else if (path == '/target') {
        targetStarted.complete();
      } else {
        stream.sendHeaders([Header.ascii(':status', '200')]);
        stream.sendData(utf8.encode('next'), endStream: true);
      }
    });
    final abort = Completer<void>();
    final pending = client
        .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future));
    final checked =
        expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
    await targetStarted.future;
    abort.complete();
    await checked;
    expect((await client.get(uri.resolve('/ok'))).body, 'next');
  });
  test(
      'HTTP/1.1 fallback uses the same Node method/body vectors for cleartext and TLS',
      () async {
    final vectors =
        jsonDecode(File('test/http_redirect_vectors.json').readAsStringSync())
            as List;
    for (final secure in [false, true]) {
      final serverContext = SecurityContext()
        ..useCertificateChain('test/fixtures/http2-local-cert.pem')
        ..usePrivateKey('test/fixtures/http2-local-key.pem')
        ..setAlpnProtocols(['http/1.1'], true);
      final server = secure
          ? await HttpServer.bindSecure(
              InternetAddress.loopbackIPv4, 0, serverContext)
          : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = Http2Client(
          context: SecurityContext()
            ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      Map<String, dynamic>? active;
      server.listen((request) async {
        final bytes = await request
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        final expected = active!;
        if (request.uri.path == '/target') {
          expect(request.method, expected['expectedMethod']);
          expect(utf8.decode(bytes), expected['expectedBody']);
          request.response.statusCode = 200;
        } else {
          request.response.statusCode = expected['status'] as int;
          request.response.headers.set('location', '/target');
        }
        await request.response.close();
      });
      final uri = Uri.parse(
          '${secure ? 'https' : 'http'}://localhost:${server.port}/redirect');
      for (final vector in vectors.cast<Map<String, dynamic>>()) {
        active = vector;
        final method = vector['method'] as String;
        final request = http.Request(method, uri)
          ..body = ['GET', 'HEAD'].contains(method) ? '' : 'payload';
        final response = await client.send(request);
        expect(response.statusCode, 200);
        expect(request.followRedirects, true);
        expect(response.request!.url.path, '/target');
        await response.stream.drain<void>();
      }
      final streaming = jsonDecode(
              File('test/http_redirect_stream_vectors.json').readAsStringSync())
          as List;
      for (final vector in streaming.cast<Map<String, dynamic>>()) {
        active = {...vector, 'expectedBody': ''};
        final bytes = utf8.encode(vector['body'] as String);
        final request = http.StreamedRequest('POST', uri)
          ..contentLength = bytes.length;
        request.sink.add(bytes);
        unawaited(request.sink.close());
        if (vector['rejected'] == true) {
          await expectLater(
              client.send(request),
              throwsA(isA<http.ClientException>().having(
                  (error) => error.message,
                  'message',
                  'Cannot replay a streaming request body after redirect')));
        } else {
          final response = await client.send(request);
          expect(response.statusCode, 200);
          await response.stream.drain<void>();
        }
      }
    }
  });
  test('HTTP/1.1 fallback preserves abort before headers and during body',
      () async {
    for (final secure in [false, true]) {
      for (final streaming in [false, true]) {
        final context = SecurityContext()
          ..useCertificateChain('test/fixtures/http2-local-cert.pem')
          ..usePrivateKey('test/fixtures/http2-local-key.pem')
          ..setAlpnProtocols(['http/1.1'], true);
        final server = secure
            ? await HttpServer.bindSecure(
                InternetAddress.loopbackIPv4, 0, context)
            : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = Http2Client(
            context: SecurityContext()
              ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        final received = Completer<void>();
        server.listen((request) async {
          await request.drain<void>();
          unawaited(request.response.done
              .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
          if (request.uri.path == '/ok') {
            request.response.write('next');
            await request.response.close();
          } else {
            if (streaming) {
              request.response.bufferOutput = false;
              request.response.write('first');
              await request.response.flush();
            }
            received.complete();
          }
        });
        final uri = Uri.parse(
            '${secure ? 'https' : 'http'}://localhost:${server.port}/wait');
        final abort = Completer<void>();
        final pending = client.send(
            http.AbortableRequest('GET', uri, abortTrigger: abort.future));
        if (streaming) {
          final response = await pending;
          final chunks = StreamIterator(response.stream);
          expect(
              await chunks.moveNext().timeout(const Duration(seconds: 5)), true,
              reason: 'first chunk secure=$secure');
          expect(utf8.decode(chunks.current), 'first');
          final reading = chunks.moveNext().timeout(const Duration(seconds: 5));
          final checked = expectLater(
              reading, throwsA(isA<http.RequestAbortedException>()));
          abort.complete();
          await checked;
          await chunks.cancel();
        } else {
          final checked = expectLater(
              pending, throwsA(isA<http.RequestAbortedException>()));
          await received.future;
          abort.complete();
          await checked;
        }
        expect((await client.get(uri.resolve('/ok'))).body, 'next');
      }
    }
  });

  test(
      'HTTP/1.1 fallback keeps same-origin credentials and strips cross-origin ones',
      () async {
    for (final secure in [false, true]) {
      for (final crossOrigin in [false, true]) {
        final context = SecurityContext()
          ..useCertificateChain('test/fixtures/http2-local-cert.pem')
          ..usePrivateKey('test/fixtures/http2-local-key.pem')
          ..setAlpnProtocols(['http/1.1'], true);
        Future<HttpServer> bind() => secure
            ? HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context)
            : HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = await bind();
        final target = await bind();
        final client = Http2Client(
            context: SecurityContext()
              ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
        addTearDown(() async {
          client.close();
          await origin.close(force: true);
          await target.close(force: true);
        });
        Future<void> respond(HttpRequest request) async {
          await request.drain<void>();
          expect(request.headers.value('authorization'),
              crossOrigin ? isNull : 'Bearer private');
          expect(request.headers.value('cookie'),
              crossOrigin ? isNull : 'session=private');
          expect(request.headers.value('proxy-authorization'),
              crossOrigin ? isNull : 'Basic private');
          expect(request.headers.value('x-api-key'), 'custom-key');
          await request.response.close();
        }

        final scheme = secure ? 'https' : 'http';
        target.listen(respond);
        origin.listen((request) async {
          if (request.uri.path == '/target') {
            await respond(request);
            return;
          }
          await request.drain<void>();
          request.response.statusCode = 302;
          request.response.headers.set(
              'location',
              crossOrigin
                  ? '$scheme://localhost:${target.port}/target'
                  : '/target');
          await request.response.close();
        });
        final response = await client
            .get(Uri.parse('$scheme://localhost:${origin.port}/'), headers: {
          'Authorization': 'Bearer private',
          'Cookie': 'session=private',
          'Proxy-Authorization': 'Basic private',
          'X-API-Key': 'custom-key',
        });
        expect(response.statusCode, 200);
      }
    }
  });
  test(
      'concurrent multi-megabyte uploads and responses cross HTTP/2 windows intact',
      () async {
    final payloads = List.generate(
        3,
        (index) => Uint8List.fromList(List.generate(
            (index + 1) * 1024 * 1024 + 17,
            (offset) => (offset + index * 31) % 251)));
    final expected =
        payloads.map((bytes) => sha256.convert(bytes).toString()).toList();
    final dartPeer = Platform.environment['E2B_TEST_HTTP2_PEER'] == 'dart';
    final peer =
        await Process.start(dartPeer ? Platform.resolvedExecutable : 'node', [
      dartPeer
          ? 'tool/http2_dart_echo_peer.dart'
          : 'test/fixtures/http2_echo_server.js'
    ]);
    final peerErrors = peer.stderr.transform(utf8.decoder).join();
    final port = int.parse(await peer.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first);
    final client = Http2Client(
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    addTearDown(() async {
      client.close();
      peer.kill();
      await peer.exitCode;
      final errors = await peerErrors;
      expect(errors, isEmpty);
    });
    final uri = Uri.parse('https://localhost:$port/');
    await Future.wait(List.generate(payloads.length, (index) async {
      final request = http.StreamedRequest('POST', uri.resolve('/$index'))
        ..contentLength = payloads[index].length;
      final pending = client.send(request);
      for (var offset = 0; offset < payloads[index].length; offset += 4093) {
        final end = offset + 4093 < payloads[index].length
            ? offset + 4093
            : payloads[index].length;
        request.sink.add(Uint8List.sublistView(payloads[index], offset, end));
      }
      unawaited(request.sink.close());
      final response = await http.Response.fromStream(await pending);
      expect(response.statusCode, 200);
      expect(response.bodyBytes.length, payloads[index].length);
      expect(sha256.convert(response.bodyBytes).toString(), expected[index]);
    }));
  });
  test(
      'dynamic SETTINGS zero waits, increases resume and cancellation survives',
      () async {
    final peer =
        await Process.start('node', ['test/fixtures/http2_settings_server.js']);
    final errors = peer.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(
        peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    await lines.moveNext();
    final port = int.parse(lines.current);
    final client = Http2Client(
        connectionLimit: 1,
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    addTearDown(() async {
      client.close();
      peer.kill();
      await peer.exitCode;
      await lines.cancel();
      expect(await errors, isEmpty);
    });
    final uri = Uri.parse('https://localhost:$port/');
    Future<void> acknowledged(int limit, {bool send = true}) async {
      if (send) {
        peer.stdin.writeln('limit $limit');
        await peer.stdin.flush();
      }
      expect(
          await lines.moveNext().timeout(const Duration(seconds: 3)), isTrue);
      expect(lines.current, 'settings:$limit');
    }

    var completed = false;
    final first = client.get(uri).then((response) {
      completed = true;
      return response;
    });
    await acknowledged(0, send: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    await acknowledged(1);
    expect((await first.timeout(const Duration(seconds: 3))).body, 'ok');
    final held = await client.send(http.Request('GET', uri.resolve('/hold')));
    final body = StreamIterator(held.stream);
    expect(await body.moveNext(), isTrue);
    expect(utf8.decode(body.current), 'prefix');
    await acknowledged(0);
    completed = false;
    final pending = client.get(uri).then((response) {
      completed = true;
      return response;
    });
    peer.stdin.writeln('release');
    await peer.stdin.flush();
    final tail = <int>[];
    while (await body.moveNext()) {
      tail.addAll(body.current);
    }
    expect(utf8.decode(tail), 'tail');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse,
        reason: 'free stream still blocked by SETTINGS=0');
    await acknowledged(1);
    final resumed = await pending.timeout(const Duration(seconds: 3));
    expect(resumed.body, 'ok');
    expect(resumed.headers['x-sessions'], '1');
    await acknowledged(0);
    final abort = Completer<void>();
    final canceled = client
        .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future));
    final checked =
        expectLater(canceled, throwsA(isA<http.RequestAbortedException>()));
    await Future<void>.delayed(Duration.zero);
    abort.complete();
    await checked.timeout(const Duration(seconds: 3));
    final blocked = client.get(uri);
    final closed = expectLater(blocked, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    client.close();
    await closed.timeout(const Duration(seconds: 3));
  });

  test('GOAWAY creates a new connection without disrupting a draining stream',
      () async {
    final peer =
        await Process.start('node', ['test/fixtures/http2_goaway_server.js']);
    final errors = peer.stderr.transform(utf8.decoder).join();
    final port = int.parse(await peer.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first);
    final client = Http2Client(
        connectionLimit: 1,
        context: SecurityContext()
          ..setTrustedCertificates('test/fixtures/http2-local-cert.pem'));
    addTearDown(() async {
      client.close();
      peer.kill();
      await peer.exitCode;
      expect(await errors, isEmpty);
    });
    final uri = Uri.parse('https://localhost:$port/');
    final held = await client.send(http.Request('GET', uri.resolve('/hold')));
    final body = StreamIterator(held.stream);
    expect(await body.moveNext(), true);
    expect(utf8.decode(body.current), 'held');
    expect(
        (await client.get(uri.resolve('/goaway'))).headers['x-session'], '1');
    final next = await client.get(uri.resolve('/next'));
    expect(next.headers['x-session'], '2');
    final draining = body.moveNext();
    expect(
        (await client.get(uri.resolve('/release'))).headers['x-session'], '2');
    expect(await draining, true);
    expect(utf8.decode(body.current), 'released');
    expect(await body.moveNext(), false);
    // Confirm the peer has closed session 1 before checking the cached session.
    var closed = false;
    for (var attempt = 0; attempt < 20 && !closed; attempt++) {
      final status = await client.get(uri.resolve('/status'));
      expect(status.headers['x-session'], '2');
      closed = status.headers['x-old-closed'] == 'true';
    }
    expect(closed, true);
    expect((await client.get(uri.resolve('/after'))).headers['x-session'], '2');
  });
}
