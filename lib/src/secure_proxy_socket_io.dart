import 'dart:async';
import 'dart:io';
import 'http_proxy_tunnel_io.dart';
import 'raw_tls_socket_io.dart';

/// Retains raw close handles throughout both proxy and origin TLS handshakes.
Future<ConnectionTask<Socket>> secureProxyConnection(Uri target, Uri proxy,
    {SecurityContext? context, Future<void>? abortTrigger}) async {
  final connecting = await RawSocket.startConnect(proxy.host, proxy.port);
  final sockets = <RawSocket>[];
  var pending = true;
  var canceled = false;
  final cancel = Completer<Socket>();
  final connected = connecting.socket.then<Socket>((raw) async {
    sockets.add(raw);
    try {
      if (canceled) throw const SocketException('Proxy connection canceled');
      raw.setOption(SocketOption.tcpNoDelay, true);
      RawSocket tunnel = raw;
      if (proxy.scheme == 'https') {
        tunnel = await RawSecureSocket.secure(raw,
            host: proxy.host,
            context: context,
            supportedProtocols: ['http/1.1']);
        sockets.add(tunnel);
      }
      if (canceled) throw const SocketException('Proxy connection canceled');
      final subscription = await openHttpTunnel(tunnel, target, proxy);
      if (canceled) throw const SocketException('Proxy connection canceled');
      final secured = await RawSecureSocket.secure(tunnel,
          host: target.host,
          subscription: subscription,
          context: context,
          supportedProtocols: ['http/1.1']);
      sockets.add(secured);
      if (canceled) throw const SocketException('Proxy connection canceled');
      return RawTlsSocket(secured);
    } catch (_) {
      for (final socket in sockets) {
        unawaited(socket.close());
      }
      rethrow;
    } finally {
      pending = false;
    }
  });
  final task = ConnectionTask.fromSocket(
      Future.any<Socket>([connected, cancel.future]), () {
    if (canceled || !pending) return;
    canceled = true;
    connecting.cancel();
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    cancel.completeError(const SocketException('Proxy connection canceled'));
  });
  abortTrigger?.then((_) => task.cancel());
  return task;
}
