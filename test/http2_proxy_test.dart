import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:e2b/src/http2_client_io.dart';
import 'package:e2b/e2b.dart' show ApiClient;
import 'package:test/test.dart';
import 'package:http/http.dart' as http;

void main() {
  for (final scheme in ['http', 'https']) {
    for (final stage in ['CONNECT', 'TLS']) {
      test('$scheme h1 TLS target $stage abort releases socket and queue',
          () async {
        final proxyContext = SecurityContext()
          ..useCertificateChain('test/fixtures/https-proxy-local-cert.pem')
          ..usePrivateKey('test/fixtures/https-proxy-local-key.pem');
        final targetContext = SecurityContext()
          ..useCertificateChain('test/fixtures/http2-local-cert.pem')
          ..usePrivateKey('test/fixtures/http2-local-key.pem');
        ServerSocket? plain;
        SecureServerSocket? secure;
        final Stream<Socket> server;
        if (scheme == 'https') {
          secure = await SecureServerSocket.bind(
              InternetAddress.loopbackIPv4, 0, proxyContext);
          server = secure;
        } else {
          plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          server = plain;
        }
        final port = secure?.port ?? plain!.port;
        final hello = Completer<void>();
        final eof = Completer<void>();
        final peers = <Socket>[];
        final served = Completer<void>();
        server.listen((socket) {
          peers.add(socket);
          final first = peers.length == 1;
          var buffered = '';
          var tunneling = false;
          late StreamSubscription<List<int>> subscription;
          subscription = socket.listen((bytes) async {
            if (first && tunneling) {
              expect(bytes.first, 22); // TLS ClientHello record.
              if (!hello.isCompleted) hello.complete();
              return;
            }
            buffered += latin1.decode(bytes);
            if (!buffered.contains('\r\n\r\n')) return;
            expect(buffered, startsWith('CONNECT localhost:443 HTTP/1.1'));
            if (first) {
              if (stage == 'TLS') {
                tunneling = true;
                socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                return;
              }
              if (!hello.isCompleted) hello.complete();
              return;
            }
            subscription.pause();
            socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            await socket.flush();
            try {
              final secured = await SecureSocket.secureServer(
                  socket, targetContext,
                  supportedProtocols: ['http/1.1']);
              peers.add(secured);
              var request = '';
              secured.listen((bytes) {
                request += latin1.decode(bytes);
                if (!request.contains('\r\n\r\n')) return;
                expect(request, startsWith('GET /next HTTP/1.1'));
                secured.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
                if (!served.isCompleted) served.complete();
              });
            } catch (error, stack) {
              if (!served.isCompleted) served.completeError(error, stack);
            }
          }, onDone: () {
            if (first && !eof.isCompleted) eof.complete();
          });
        });
        final client = Http2Client(
            allowH2: false,
            proxy: '$scheme://localhost:$port',
            connectionLimit: 1,
            context: SecurityContext()
              ..setTrustedCertificates('test/fixtures/http2-local-cert.pem')
              ..setTrustedCertificates(
                  'test/fixtures/https-proxy-local-cert.pem'));
        addTearDown(() async {
          client.close();
          for (final peer in peers) {
            peer.destroy();
          }
          await plain?.close();
          await secure?.close();
        });
        final uri = Uri.parse('https://localhost/next');
        final abort = Completer<void>();
        final pending = client.send(
            http.AbortableRequest('GET', uri, abortTrigger: abort.future));
        final checked =
            expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
        await hello.future.timeout(const Duration(seconds: 3));
        final next = client.get(uri);
        unawaited(next.then<void>((_) {}, onError: (Object _) {}));
        await Future<void>.delayed(Duration.zero);
        abort.complete();
        await checked.timeout(const Duration(seconds: 3));
        await eof.future.timeout(const Duration(seconds: 3));
        expect((await next.timeout(const Duration(seconds: 3))).body, 'ok');
        await served.future.timeout(const Duration(seconds: 3));
        // Two accepted connections plus the upgraded target TLS socket.
        expect(peers.length, 3);
      });
    }
  }
  for (final scheme in ['http', 'https']) {
    for (final mode in ['h2', 'h1', 'plain']) {
      test('$scheme CONNECT failure recovers for $mode on the same client',
          () async {
        final peer = await Process.start('node', [
          'test/fixtures/http2_proxy_server.js',
          mode,
          'fail-once',
          if (scheme == 'https') 'secure',
        ]);
        final errors = peer.stderr.transform(utf8.decoder).join();
        final ports = jsonDecode(await peer.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first) as Map<String, dynamic>;
        final client = Http2Client(
            proxy: '$scheme://localhost:${ports['proxy']}',
            connectionLimit: 1,
            context: SecurityContext()
              ..setTrustedCertificates('test/fixtures/http2-local-cert.pem')
              ..setTrustedCertificates(
                  'test/fixtures/https-proxy-local-cert.pem'));
        addTearDown(() async {
          client.close();
          peer.kill();
          await peer.exitCode;
          expect(await errors, isEmpty);
        });
        final uri = Uri.parse(
            '${mode == 'plain' ? 'http' : 'https'}://localhost:${ports['origin']}/');
        await expectLater(client.get(uri).timeout(const Duration(seconds: 3)),
            throwsA(isA<SocketException>()));
        final recovered = jsonDecode(
            (await client.get(uri).timeout(const Duration(seconds: 3)))
                .body) as Map;
        expect(recovered['protocol'], mode);
        expect(recovered['tunnels'], 1);
        final reused = jsonDecode(
            (await client.get(uri).timeout(const Duration(seconds: 3)))
                .body) as Map;
        expect(reused['protocol'], mode);
        expect(reused['tunnels'], recovered['tunnels']);
      });
    }
  }
  for (final scheme in ['http', 'https']) {
    for (final mode in ['h2', 'h1', 'plain']) {
      for (final authenticated in [false, true]) {
        test(
            '$scheme CONNECT to $mode auth=$authenticated isolates credentials',
            () async {
          final peer = await Process.start('node', [
            'test/fixtures/http2_proxy_server.js',
            mode,
            if (authenticated) 'auth',
            if (scheme == 'https') 'secure',
          ]);
          final errors = peer.stderr.transform(utf8.decoder).join();
          final ports = jsonDecode(await peer.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first) as Map<String, dynamic>;
          final proxy =
              '$scheme://${authenticated ? 'u:p%40ss@' : ''}localhost:${ports['proxy']}';
          final client = Http2Client(
              proxy: proxy,
              context: SecurityContext()
                ..setTrustedCertificates('test/fixtures/http2-local-cert.pem')
                ..setTrustedCertificates(
                    'test/fixtures/https-proxy-local-cert.pem'));
          addTearDown(() async {
            client.close();
            peer.kill();
            await peer.exitCode;
            expect(await errors, isEmpty);
          });
          final uri = Uri.parse(
              '${mode == 'plain' ? 'http' : 'https'}://localhost:${ports['origin']}/');
          if (mode == 'plain') {
            // An abort signal outliving its completed request must not destroy
            // the tunnel after it has returned to the native idle pool.
            final completedAbort = Completer<void>();
            final completed = await http.Response.fromStream(await client.send(
                http.AbortableRequest('GET', uri,
                    abortTrigger: completedAbort.future)));
            final tunnelCount = (jsonDecode(completed.body) as Map)['tunnels'];
            completedAbort.complete();
            await Future<void>.delayed(Duration.zero);
            final reused = await client.get(uri);
            expect((jsonDecode(reused.body) as Map)['tunnels'], tunnelCount);
            final activeClient = Http2Client(
                proxy: proxy,
                connectionLimit: 1,
                context: SecurityContext()
                  ..setTrustedCertificates(
                      'test/fixtures/https-proxy-local-cert.pem'));
            addTearDown(activeClient.close);
            final oldAbort = Completer<void>();
            final first = await http.Response.fromStream(
                await activeClient.send(http.AbortableRequest('GET', uri,
                    abortTrigger: oldAbort.future)));
            final activeTunnel = (jsonDecode(first.body) as Map)['tunnels'];
            final held = await activeClient
                .send(http.Request('GET', uri.resolve('/held')));
            final chunks = StreamIterator(held.stream);
            expect(await chunks.moveNext(), isTrue);
            expect(utf8.decode(chunks.current), 'prefix');
            oldAbort.complete();
            await Future<void>.delayed(Duration.zero);
            peer.stdin.writeln('release');
            await peer.stdin.flush();
            expect(await chunks.moveNext().timeout(const Duration(seconds: 3)),
                isTrue);
            expect(utf8.decode(chunks.current), 'suffix');
            expect(await chunks.moveNext(), isFalse);
            await chunks.cancel();
            final after = await activeClient.get(uri);
            expect((jsonDecode(after.body) as Map)['tunnels'], activeTunnel);
            activeClient.close();
          }
          for (var i = 0; i < 2; i++) {
            final response =
                await client.get(uri).timeout(const Duration(seconds: 5));
            final result = jsonDecode(response.body) as Map<String, dynamic>;
            expect(result['protocol'], mode);
            expect(result['leaked'], false);
            if (mode != 'plain') expect(result['tunnels'], 1);
          }
          if (mode != 'h2') {
            final bytes =
                List.generate(256 * 1024 + 17, (index) => index % 251);
            final upload = http.StreamedRequest('POST', uri.resolve('/echo'))
              ..contentLength = bytes.length;
            final pending = client.send(upload);
            for (var offset = 0; offset < bytes.length; offset += 4093) {
              upload.sink.add(bytes.sublist(offset,
                  offset + 4093 < bytes.length ? offset + 4093 : bytes.length));
            }
            await upload.sink.close();
            final echoed = await http.Response.fromStream(await pending);
            expect(jsonDecode(echoed.body), {
              'length': bytes.length,
              'hash': sha256.convert(bytes).toString(),
              'leaked': false,
            });
            final abort = Completer<void>();
            final response = await client.send(http.AbortableRequest(
                'GET', uri.resolve('/stream'),
                abortTrigger: abort.future));
            final body = StreamIterator(response.stream);
            expect(await body.moveNext(), isTrue);
            expect(utf8.decode(body.current), 'prefix');
            final next = body.moveNext();
            final checked =
                expectLater(next, throwsA(isA<http.RequestAbortedException>()));
            abort.complete();
            await checked;
            await body.cancel();
            expect((await client.get(uri)).statusCode, 200);
          }
          if (scheme == 'https') {
            for (final trusted in [
              null,
              'test/fixtures/http2-local-cert.pem',
              'test/fixtures/https-proxy-local-cert.pem'
            ]) {
              if (mode == 'plain' &&
                  trusted == 'test/fixtures/https-proxy-local-cert.pem') {
                continue;
              }
              final context = SecurityContext(withTrustedRoots: false);
              if (trusted != null) context.setTrustedCertificates(trusted);
              final untrusted = Http2Client(proxy: proxy, context: context);
              addTearDown(untrusted.close);
              await expectLater(
                  untrusted.get(uri).timeout(const Duration(seconds: 5)),
                  throwsA(isA<HandshakeException>()));
            }
          }
          SecurityContext.defaultContext
            ..setTrustedCertificates('test/fixtures/http2-local-cert.pem')
            ..setTrustedCertificates(
                'test/fixtures/https-proxy-local-cert.pem');
          final api = ApiClient(
              apiKey: 'test',
              proxy: proxy,
              apiUrl: uri,
              retries: 0,
              httpVersion: mode == 'h1' ? '1.1' : '2');
          addTearDown(api.close);
          final managed = await api.requestResponse('GET', '/redirect');
          expect((jsonDecode(managed.body) as Map)['protocol'], mode);
          expect((jsonDecode(managed.body) as Map)['leaked'], false);
          expect((api.httpClient as Http2Client).allowH2, mode != 'h1');
          if (authenticated) {
            final invalid = Http2Client(
                proxy: '$scheme://u:wrong@localhost:${ports['proxy']}',
                context: SecurityContext()
                  ..setTrustedCertificates('test/fixtures/http2-local-cert.pem')
                  ..setTrustedCertificates(
                      'test/fixtures/https-proxy-local-cert.pem'));
            addTearDown(invalid.close);
            await expectLater(
                invalid.get(uri).timeout(const Duration(seconds: 5)),
                throwsA(isA<SocketException>()));
          }
        });
      }
    }
  }
  for (final scheme in ['http', 'https']) {
    test('close interrupts $scheme proxy waiting for CONNECT response',
        () async {
      ServerSocket? plain;
      SecureServerSocket? secure;
      final Stream<Socket> server;
      if (scheme == 'https') {
        secure = await SecureServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
            SecurityContext()
              ..useCertificateChain('test/fixtures/https-proxy-local-cert.pem')
              ..usePrivateKey('test/fixtures/https-proxy-local-key.pem'));
        server = secure;
      } else {
        plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server = plain;
      }
      final port = secure?.port ?? plain!.port;
      final hello = Completer<void>();
      final eof = Completer<void>();
      Socket? peer;
      server.listen((socket) {
        peer = socket;
        final bytes = <int>[];
        socket.listen((chunk) {
          bytes.addAll(chunk);
          if (latin1.decode(bytes).contains('\r\n\r\n') && !hello.isCompleted) {
            expect(latin1.decode(bytes),
                startsWith('CONNECT localhost:443 HTTP/1.1'));
            hello.complete();
          }
        }, onDone: () {
          if (!eof.isCompleted) eof.complete();
        });
      });
      final client = Http2Client(
          proxy: '$scheme://localhost:$port',
          context: SecurityContext()
            ..setTrustedCertificates(
                'test/fixtures/https-proxy-local-cert.pem'));
      addTearDown(() async {
        client.close();
        peer?.destroy();
        await plain?.close();
        await secure?.close();
      });
      final pending = client.get(Uri.parse('https://localhost/'));
      final checked = expectLater(pending, throwsStateError);
      await hello.future.timeout(const Duration(seconds: 3));
      client.close();
      await checked.timeout(const Duration(seconds: 3));
      await eof.future.timeout(const Duration(seconds: 3));
    });
  }
  for (final scheme in ['http', 'https']) {
    test('$scheme plaintext CONNECT abort releases socket before client close',
        () async {
      ServerSocket? plain;
      SecureServerSocket? secure;
      final Stream<Socket> server;
      if (scheme == 'https') {
        secure = await SecureServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
            SecurityContext()
              ..useCertificateChain('test/fixtures/https-proxy-local-cert.pem')
              ..usePrivateKey('test/fixtures/https-proxy-local-key.pem'));
        server = secure;
      } else {
        plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server = plain;
      }
      final port = secure?.port ?? plain!.port;
      final hello = Completer<void>();
      final eof = Completer<void>();
      final peers = <Socket>[];
      server.listen((socket) {
        peers.add(socket);
        final first = peers.length == 1;
        var connected = false;
        var buffered = '';
        socket.listen((bytes) {
          buffered += latin1.decode(bytes);
          if (!buffered.contains('\r\n\r\n')) return;
          if (first) {
            if (!hello.isCompleted) hello.complete();
          } else if (!connected) {
            expect(buffered, startsWith('CONNECT localhost:80 HTTP/1.1'));
            socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            connected = true;
            buffered = '';
          } else {
            expect(buffered, startsWith('GET /next HTTP/1.1'));
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
            buffered = '';
          }
        }, onDone: () {
          if (first && !eof.isCompleted) eof.complete();
        });
      });
      final client = Http2Client(
          proxy: '$scheme://localhost:$port',
          connectionLimit: 1,
          context: SecurityContext()
            ..setTrustedCertificates(
                'test/fixtures/https-proxy-local-cert.pem'));
      addTearDown(() async {
        client.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await plain?.close();
        await secure?.close();
      });
      final abort = Completer<void>();
      final pending = client.send(http.AbortableRequest(
          'GET', Uri.parse('http://localhost/next'),
          abortTrigger: abort.future));
      final checked =
          expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
      await hello.future.timeout(const Duration(seconds: 3));
      final next = client.get(Uri.parse('http://localhost/next'));
      unawaited(next.then<void>((_) {}, onError: (Object _) {}));
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await checked.timeout(const Duration(seconds: 3));
      await eof.future.timeout(const Duration(seconds: 3));
      expect((await next.timeout(const Duration(seconds: 3))).body, 'ok');
      expect(peers.length, 2);
    });
  }
}
