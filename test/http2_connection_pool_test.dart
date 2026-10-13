import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/http2_connection_pool_io.dart';
import 'package:e2b/src/vendor/http2/transport.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  SecurityContext serverContext(List<String> protocols) => SecurityContext()
    ..setAlpnProtocols(protocols, true)
    ..useCertificateChain('test/fixtures/http2-local-cert.pem')
    ..usePrivateKey('test/fixtures/http2-local-key.pem');
  SecurityContext clientContext() => SecurityContext()
    ..setTrustedCertificates('test/fixtures/http2-local-cert.pem');

  test('TLS ALPN pool shares one HTTP/2 connection and multiplexes streams',
      () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serverContext(['h2', 'http/1.1']),
        supportedProtocols: ['h2', 'http/1.1']);
    var sockets = 0;
    final transports = <ServerTransportConnection>[];
    server.listen((socket) {
      sockets++;
      expect(socket.selectedProtocol, 'h2');
      final transport = ServerTransportConnection.viaSocket(socket);
      transports.add(transport);
      transport.incomingStreams.listen((stream) async {
        await stream.incomingMessages.drain<void>();
        stream.sendHeaders([Header.ascii(':status', '200')]);
        stream.sendData(utf8.encode('stream:${stream.id}'), endStream: true);
      });
    });
    final pool = Http2ConnectionPool(context: clientContext());
    addTearDown(() async {
      await pool.close();
      for (final transport in transports) {
        await transport.terminate();
      }
      await server.close();
    });
    final uri = Uri.parse('https://localhost:${server.port}/');
    final connections =
        await Future.wait(List.generate(8, (_) => pool.connect(uri)));
    expect(
        connections
            .every((connection) => identical(connection, connections.first)),
        true);
    final replies = await Future.wait(connections.map((connection) async {
      final stream = connection!.makeRequest([
        Header.ascii(':method', 'GET'),
        Header.ascii(':path', '/'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', uri.authority),
      ], endStream: true);
      final messages = await stream.incomingMessages.toList();
      return utf8.decode(messages
          .whereType<DataStreamMessage>()
          .expand((m) => m.bytes)
          .toList());
    }));
    expect(replies.toSet().length, 8);
    expect(sockets, 1);
    await pool.close();
    await expectLater(pool.connect(uri), throwsStateError);
  });

  test('TLS waits for peer SETTINGS and applies its stream limit', () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serverContext(['h2']),
        supportedProtocols: ['h2']);
    final accepted = Completer<SecureSocket>();
    server.listen(accepted.complete);
    final pool = Http2ConnectionPool(context: clientContext());
    ServerTransportConnection? peer;
    addTearDown(() async {
      await pool.close();
      await peer?.terminate();
      if (accepted.isCompleted) (await accepted.future).destroy();
      await server.close();
    });
    var completed = false;
    final pending = pool
        .connect(Uri.parse('https://localhost:${server.port}/'))
        .then((value) {
      completed = true;
      return value;
    });
    final socket = await accepted.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    peer = ServerTransportConnection.viaSocket(socket,
        settings: const ServerSettings(concurrentStreamLimit: 1));
    final connection = (await pending)!;
    final stream = connection.makeRequest([
      Header.ascii(':method', 'GET'),
      Header.ascii(':scheme', 'https'),
      Header.ascii(':authority', 'localhost'),
      Header.ascii(':path', '/'),
    ], endStream: true);
    expect(connection.isOpen, isFalse);
    stream.terminate();
  });

  for (final explicitConnect in [false, true]) {
    test(
        'cancel during initial SETTINGS preserves survivor explicitConnect=$explicitConnect',
        () async {
      final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, serverContext(['h2']),
          supportedProtocols: ['h2']);
      final accepted = Completer<SecureSocket>();
      var sockets = 0;
      server.listen((socket) {
        sockets++;
        if (!accepted.isCompleted) {
          accepted.complete(socket);
        } else {
          socket.destroy();
        }
      });
      final pool =
          Http2ConnectionPool(context: clientContext(), connectionLimit: 1);
      ServerTransportConnection? peer;
      addTearDown(() async {
        await pool.close();
        await peer?.terminate();
        if (accepted.isCompleted) (await accepted.future).destroy();
        await server.close();
      });
      final uri = Uri.parse('https://localhost:${server.port}/');
      List<Header> headers(String path) => [
            Header.ascii(':method', 'GET'),
            Header.ascii(':scheme', 'https'),
            Header.ascii(':authority', uri.authority),
            Header.ascii(':path', path),
          ];
      final abort = Completer<void>();
      final first = pool.makeRequest(uri, headers('/canceled'),
          abortTrigger: abort.future);
      final checked =
          expectLater(first, throwsA(isA<http.RequestAbortedException>()));
      final socket = await accepted.future;
      final next = explicitConnect
          ? pool.connect(uri).then(
              (connection) => connection!.makeRequest(headers('/survivor')))
          : pool.makeRequest(uri, headers('/survivor'));
      unawaited(next.then<void>((_) {}, onError: (Object _) {}));
      abort.complete();
      await checked.timeout(const Duration(seconds: 3));
      // Only now send initial SETTINGS, after cancellation has reached the caller.
      peer = ServerTransportConnection.viaSocket(socket);
      final paths = <String>[];
      peer.incomingStreams.listen((stream) async {
        await for (final message in stream.incomingMessages) {
          if (message is HeadersStreamMessage) {
            paths.addAll(message.headers
                .where((h) => ascii.decode(h.name) == ':path')
                .map((h) => utf8.decode(h.value)));
          }
        }
        stream.sendHeaders([Header.ascii(':status', '200')]);
        stream.sendData(utf8.encode('ok'), endStream: true);
      });
      final stream = (await next.timeout(const Duration(seconds: 3)))!;
      stream.sendData([], endStream: true);
      final messages = await stream.incomingMessages
          .toList()
          .timeout(const Duration(seconds: 3));
      expect(
          utf8.decode(messages
              .whereType<DataStreamMessage>()
              .expand((m) => m.bytes)
              .toList()),
          'ok');
      expect(paths, ['/survivor']);
      expect(sockets, 1);
    });
  }

  test('close rejects a TLS connection waiting forever for SETTINGS', () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serverContext(['h2']),
        supportedProtocols: ['h2']);
    final accepted = Completer<SecureSocket>();
    server.listen(accepted.complete);
    final pool = Http2ConnectionPool(context: clientContext());
    addTearDown(() async {
      await pool.close();
      if (accepted.isCompleted) (await accepted.future).destroy();
      await server.close();
    });
    final pending =
        pool.connect(Uri.parse('https://localhost:${server.port}/'));
    final checked = expectLater(pending, throwsStateError);
    await accepted.future;
    await pool.close().timeout(const Duration(seconds: 3));
    await checked.timeout(const Duration(seconds: 3));
  });

  for (final limit in [1, 2]) {
    test('stream saturation honors $limit connections and reuses capacity',
        () async {
      final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, serverContext(['h2']),
          supportedProtocols: ['h2']);
      final peers = <ServerTransportConnection>[];
      final streams = <ServerTransportStream>[];
      final arrived = StreamController<void>.broadcast();
      server.listen((socket) {
        final peer = ServerTransportConnection.viaSocket(socket,
            settings: const ServerSettings(concurrentStreamLimit: 1));
        peers.add(peer);
        peer.incomingStreams.listen((stream) {
          streams.add(stream);
          arrived.add(null);
          stream.incomingMessages.drain<void>();
          if (streams.length > limit) {
            stream.sendHeaders([Header.ascii(':status', '200')]);
            stream.sendData([], endStream: true);
          }
        });
      });
      final pool =
          Http2ConnectionPool(context: clientContext(), connectionLimit: limit);
      addTearDown(() async {
        await pool.close();
        for (final peer in peers) {
          await peer.terminate();
        }
        await arrived.close();
        await server.close();
      });
      final uri = Uri.parse('https://localhost:${server.port}/');
      final headers = [
        Header.ascii(':method', 'GET'),
        Header.ascii(':scheme', 'https'),
        Header.ascii(':authority', 'localhost'),
        Header.ascii(':path', '/')
      ];
      final allocated = <ClientTransportStream>[];
      for (var i = 0; i < limit; i++) {
        final received = arrived.stream.first;
        final stream = (await pool.makeRequest(uri, headers))!;
        allocated.add(stream);
        await stream.outgoingMessages.close();
        await received;
      }
      final abort = Completer<void>();
      final canceled =
          pool.makeRequest(uri, headers, abortTrigger: abort.future);
      final checked =
          expectLater(canceled, throwsA(isA<http.RequestAbortedException>()));
      abort.complete();
      await checked;
      var dispatched = false;
      final queued = Future.wait(List.generate(4, (_) async {
        final stream = (await pool.makeRequest(uri, headers))!;
        dispatched = true;
        await stream.outgoingMessages.close();
        await stream.incomingMessages.drain<void>();
      }));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dispatched, isFalse);
      expect(peers.length, limit);
      final drained = allocated.first.incomingMessages.drain<void>();
      streams.first.sendHeaders([Header.ascii(':status', '200')]);
      streams.first.sendData([], endStream: true);
      await drained;
      await queued.timeout(const Duration(seconds: 3));
      expect(dispatched, isTrue);
      expect(peers.length, limit);
    });
  }

  test('HTTP/1.1 ALPN and cleartext endpoints signal fallback', () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serverContext(['http/1.1']),
        supportedProtocols: ['http/1.1']);
    final accepted = Completer<SecureSocket>();
    server.listen(accepted.complete);
    final pool = Http2ConnectionPool(context: clientContext());
    addTearDown(() async {
      await pool.close();
      if (accepted.isCompleted) (await accepted.future).destroy();
      await server.close();
    });
    expect(await pool.connect(Uri.parse('http://localhost/')), isNull);
    expect(await pool.connect(Uri.parse('https://localhost:${server.port}/')),
        isNull);
    expect((await accepted.future).selectedProtocol, 'http/1.1');
  });
  for (final claimed in [false, true]) {
    test('HTTP1 ALPN socket close ownership claimed=$claimed', () async {
      final server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4, 0, serverContext(['http/1.1']),
          supportedProtocols: ['http/1.1']);
      final peers = <SecureSocket>[];
      final eof = Completer<void>();
      server.listen((socket) {
        peers.add(socket);
        socket.listen((bytes) {
          expect(utf8.decode(bytes), 'ping');
          socket.write('ack');
        }, onDone: () {
          if (!eof.isCompleted) eof.complete();
        });
      });
      final pool = Http2ConnectionPool(context: clientContext());
      Socket? transferred;
      addTearDown(() async {
        transferred?.destroy();
        await pool.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await server.close();
      });
      final uri = Uri.parse('https://localhost:${server.port}/');
      expect(await pool.connect(uri), isNull);
      if (claimed) {
        transferred = pool.takeHttp1Socket(uri);
        expect(transferred, isNotNull);
        expect(pool.takeHttp1Socket(uri), isNull);
      }
      await pool.close();
      if (claimed) {
        final owned = transferred!;
        final response = StreamIterator(owned);
        owned.write('ping');
        await owned.flush();
        expect(await response.moveNext().timeout(const Duration(seconds: 3)),
            isTrue);
        expect(utf8.decode(response.current), 'ack');
        owned.destroy();
        await eof.future.timeout(const Duration(seconds: 3));
        await response.cancel();
      } else {
        await eof.future.timeout(const Duration(seconds: 3));
      }
      expect(peers.length, 1);
      expect(pool.takeHttp1Socket(uri), isNull);
    });
  }
  test('failed certificate verification does not poison the origin cache',
      () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serverContext(['h2']),
        supportedProtocols: ['h2']);
    final transports = <ServerTransportConnection>[];
    server.listen((socket) {
      transports.add(ServerTransportConnection.viaSocket(socket));
    }, onError: (Object _) {});
    final context = SecurityContext();
    final pool = Http2ConnectionPool(context: context);
    addTearDown(() async {
      await pool.close();
      for (final transport in transports) {
        await transport.terminate();
      }
      await server.close();
    });
    final uri = Uri.parse('https://localhost:${server.port}/');
    await expectLater(pool.connect(uri), throwsA(isA<HandshakeException>()));
    context.setTrustedCertificates('test/fixtures/http2-local-cert.pem');
    final connection = await pool.connect(uri);
    expect(connection, isNotNull);
    expect(connection!.isOpen, true);
  });
  test('close interrupts a TLS handshake when the peer never responds',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hello = Completer<void>();
    final peerClosed = Completer<void>();
    final peers = <Socket>[];
    server.listen((socket) {
      peers.add(socket);
      socket.listen((bytes) {
        if (!hello.isCompleted && bytes.isNotEmpty) hello.complete();
      }, onDone: () {
        if (!peerClosed.isCompleted) peerClosed.complete();
      });
    });
    final pool = Http2ConnectionPool();
    addTearDown(() async {
      await pool.close();
      for (final peer in peers) {
        peer.destroy();
      }
      await server.close();
    });
    final connecting =
        pool.connect(Uri.parse('https://localhost:${server.port}/'));
    final checked = expectLater(connecting, throwsStateError);
    await hello.future.timeout(const Duration(seconds: 3));
    await pool.close().timeout(const Duration(seconds: 3));
    await checked.timeout(const Duration(seconds: 3));
    await peerClosed.future.timeout(const Duration(seconds: 3));
    await expectLater(
        pool.connect(Uri.parse('https://localhost:${server.port}/')),
        throwsStateError);
  });
  for (final stage in [
    'TLS',
    'CONNECT',
    'HTTPS_TLS',
    'HTTPS_CONNECT',
    'SETTINGS'
  ]) {
    test('last waiter cancellation releases $stage and permits a new attempt',
        () async {
      ServerSocket? plain;
      SecureServerSocket? secure;
      final Stream<Socket> server;
      if (stage == 'HTTPS_CONNECT' || stage == 'SETTINGS') {
        secure = await SecureServerSocket.bind(
            InternetAddress.loopbackIPv4, 0, serverContext(['h2', 'http/1.1']),
            supportedProtocols: ['h2', 'http/1.1']);
        server = secure;
      } else {
        plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server = plain;
      }
      final port = secure?.port ?? plain!.port;
      final hellos = [Completer<void>(), Completer<void>()];
      final eofs = [Completer<void>(), Completer<void>()];
      final peers = <Socket>[];
      server.listen((socket) {
        final index = peers.length;
        peers.add(socket);
        socket.listen((bytes) {
          if (!hellos[index].isCompleted && bytes.isNotEmpty) {
            hellos[index].complete();
          }
        }, onDone: () {
          if (!eofs[index].isCompleted) eofs[index].complete();
        });
      });
      final throughProxy = stage == 'CONNECT' || stage.startsWith('HTTPS_');
      final pool = Http2ConnectionPool(
          context: clientContext(),
          proxy: throughProxy
              ? '${stage.startsWith('HTTPS_') ? 'https' : 'http'}://localhost:$port'
              : null);
      addTearDown(() async {
        await pool.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await plain?.close();
        await secure?.close();
      });
      final uri = Uri.parse(
          throughProxy ? 'https://localhost/' : 'https://localhost:$port/');
      for (var cycle = 0; cycle < 2; cycle++) {
        final firstAbort = Completer<void>();
        final first =
            pool.makeRequest(uri, [], abortTrigger: firstAbort.future);
        final firstChecked =
            expectLater(first, throwsA(isA<http.RequestAbortedException>()));
        await hellos[cycle].future.timeout(const Duration(seconds: 3));
        final secondAbort = Completer<void>();
        final second =
            pool.makeRequest(uri, [], abortTrigger: secondAbort.future);
        final secondChecked =
            expectLater(second, throwsA(isA<http.RequestAbortedException>()));
        firstAbort.complete();
        await firstChecked.timeout(const Duration(seconds: 3));
        expect(eofs[cycle].isCompleted, isFalse);
        secondAbort.complete();
        await secondChecked.timeout(const Duration(seconds: 3));
        await eofs[cycle].future.timeout(const Duration(seconds: 3));
      }
      expect(peers.length, 2);
    });
  }
}
