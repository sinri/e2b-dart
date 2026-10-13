import 'dart:async';
import 'dart:io';
import 'vendor/http2/transport.dart';
import 'package:http/http.dart' as http;
import 'raw_tls_channel_io.dart';
import 'raw_tls_socket_io.dart';
import 'http2_frame_observer.dart';
import 'http_proxy_tunnel_io.dart';
import 'native_http_client_io.dart';

/// TLS connections negotiated with ALPN, shared by origin. A null transport
/// means the peer selected HTTP/1.1; request adaptation can use IOClient.
class Http2ConnectionPool {
  final SecurityContext? context;
  final num connectionLimit;
  final Uri? proxy;
  final Map<String, Set<ClientTransportConnection>> _byOrigin = {};
  final Set<ClientTransportConnection> _draining = {};
  final Map<String, Future<void>> _allocationTails = {};
  final Map<String, Socket> _http1Sockets = {};
  Socket? takeHttp1Socket(Uri uri) =>
      _http1Sockets.remove('${uri.host}:${uri.port}');
  final Map<String, int> _requestUsers = {};
  final Map<String, Set<_ConnectionAttempt>> _attempts = {};

  void _releaseRequest(String origin) {
    final remaining = (_requestUsers[origin] ?? 1) - 1;
    if (remaining > 0) {
      _requestUsers[origin] = remaining;
      return;
    }
    _requestUsers.remove(origin);
    for (final attempt in (_attempts[origin] ?? {}).toList()) {
      if (attempt.pinned) continue;
      final connection = attempt.connection;
      if (connection != null) {
        _byOrigin[origin]?.remove(connection);
        _connections.remove(connection);
      }
      attempt.cancel();
    }
  }

  Future<ClientTransportConnection?> _startConnection(Uri uri, String origin,
      {required bool managed}) async {
    final attempt = _ConnectionAttempt(uri, pinned: !managed);
    (_attempts[origin] ??= {}).add(attempt);
    try {
      return await Future.any<ClientTransportConnection?>([
        _connect(uri, origin, attempt),
        attempt.canceled.future,
      ]);
    } finally {
      _attempts[origin]?.remove(attempt);
      if (_attempts[origin]?.isEmpty ?? false) _attempts.remove(origin);
    }
  }

  Completer<void> _capacity = Completer<void>();
  void notifyCapacity() {
    final previous = _capacity;
    _capacity = Completer<void>();
    previous.complete();
  }

  final Map<String, Future<ClientTransportConnection?>> _pending = {};
  final Set<ClientTransportConnection> _connections = {};
  final Map<String, ClientTransportConnection> _originConnections = {};
  final Set<ConnectionTask<RawSocket>> _connecting = {};
  final Set<RawSocket> _handshaking = {};
  final Completer<void> _closedEvent = Completer<void>();
  Future<void>? _closeFuture;
  bool _closed = false;

  Http2ConnectionPool({this.context, this.connectionLimit = 100, String? proxy})
      : proxy = parseHttpProxy(proxy);

  Future<ClientTransportConnection?> connect(Uri uri,
      {bool managed = false}) async {
    if (_closed) throw StateError('HTTP/2 pool is closed');
    if (uri.scheme != 'https') return null;
    final origin = '${uri.host}:${uri.port}';
    if (!managed) {
      for (final attempt in _attempts[origin] ?? <_ConnectionAttempt>{}) {
        attempt.pinned = true;
      }
    }
    final pending = _pending.putIfAbsent(
        origin,
        () => Future.any<ClientTransportConnection?>([
              _startConnection(uri, origin, managed: managed),
              _closedEvent.future.then<ClientTransportConnection?>(
                  (_) => throw StateError('HTTP/2 pool is closed')),
            ]));
    final ClientTransportConnection? connection;
    try {
      connection = await pending;
    } catch (_) {
      if (identical(_pending[origin], pending)) _pending.remove(origin);
      rethrow;
    }
    if (_closed) throw StateError('HTTP/2 pool is closed');
    if (connection != null && _draining.contains(connection)) {
      if (identical(_originConnections[origin], connection)) {
        _originConnections.remove(origin);
      }
      if (identical(_pending[origin], pending)) _pending.remove(origin);
      return connect(uri, managed: managed);
    }
    return connection;
  }

  /// Allocation and makeRequest are serialized per origin, so concurrent
  /// callers cannot all observe the same last available stream slot.
  Future<ClientTransportStream?> makeRequest(Uri uri, List<Header> headers,
      {Future<void>? abortTrigger}) async {
    final origin = '${uri.host}:${uri.port}';
    _requestUsers[origin] = (_requestUsers[origin] ?? 0) + 1;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _releaseRequest(origin);
    }

    var aborted = false;
    ClientTransportStream? reserved;
    ClientTransportStream reserve(ClientTransportConnection connection) =>
        reserved = connection.makeRequest(headers);
    final abort = Completer<Never>();
    abortTrigger?.then((_) {
      aborted = true;
      reserved?.terminate();
      if (!abort.isCompleted) {
        abort.completeError(http.RequestAbortedException(uri));
      }
      release();
      notifyCapacity();
    });
    final previous = _allocationTails[origin] ?? Future<void>.value();
    final allocated = previous.then((_) async {
      while (true) {
        if (_closed) throw StateError('HTTP/2 pool is closed');
        if (aborted) throw http.RequestAbortedException(uri);
        if (uri.scheme != 'https') return null;
        final changed = _capacity.future;
        final available = (_byOrigin[origin] ?? {})
            .where((connection) => !_draining.contains(connection))
            .toList();
        for (final connection in available) {
          if (connection.isOpen) return reserve(connection);
        }
        if (available.length < connectionLimit) {
          final connection = available.isEmpty
              ? await connect(uri, managed: true)
              : await _startConnection(uri, origin, managed: true);
          if (aborted) throw http.RequestAbortedException(uri);
          if (connection == null) return null;
          if (connection.isOpen) return reserve(connection);
          continue;
        }
        await Future.any<void>([changed, _closedEvent.future]);
      }
    });
    final tail = allocated.then<void>((_) {}, onError: (Object _) {});
    _allocationTails[origin] = tail;
    unawaited(tail.then((_) {
      if (identical(_allocationTails[origin], tail)) {
        _allocationTails.remove(origin);
      }
    }));
    try {
      return await Future.any<ClientTransportStream?>(
          [allocated, abort.future]);
    } finally {
      release();
    }
  }

  Future<ClientTransportConnection?> _connect(
      Uri uri, String origin, _ConnectionAttempt attempt) async {
    try {
      final task = await RawSocket.startConnect(
          proxy?.host ?? uri.host, proxy?.port ?? uri.port);
      attempt.task = task;
      if (attempt.isCanceled) task.cancel();
      _connecting.add(task);
      if (_closed) task.cancel();
      late RawSocket raw;
      try {
        raw = await task.socket;
      } finally {
        _connecting.remove(task);
      }
      attempt.sockets.add(raw);
      attempt.check();
      // HTTP/2 control frames and TLS records must not wait for delayed ACKs.
      raw.setOption(SocketOption.tcpNoDelay, true);
      _handshaking.add(raw);
      RawSocket tunnelSocket = raw;
      late RawSecureSocket socket;
      try {
        if (_closed) {
          await raw.close();
          throw StateError('HTTP/2 pool is closed');
        }
        StreamSubscription<RawSocketEvent>? subscription;
        if (proxy?.scheme == 'https') {
          tunnelSocket = await Future.any<RawSecureSocket>([
            RawSecureSocket.secure(raw,
                host: proxy!.host,
                context: context,
                supportedProtocols: ['http/1.1']),
            _closedEvent.future.then<RawSecureSocket>(
                (_) => throw StateError('HTTP/2 pool is closed')),
          ]);
          attempt.sockets.add(tunnelSocket);
          attempt.check();
          _handshaking.add(tunnelSocket);
        }
        if (proxy != null) {
          subscription = await Future.any<StreamSubscription<RawSocketEvent>>([
            openHttpTunnel(tunnelSocket, uri, proxy!),
            _closedEvent.future.then<StreamSubscription<RawSocketEvent>>(
                (_) => throw StateError('HTTP/2 pool is closed')),
          ]);
        }
        socket = await Future.any<RawSecureSocket>([
          RawSecureSocket.secure(tunnelSocket,
              host: uri.host,
              subscription: subscription,
              context: context,
              supportedProtocols: ['h2', 'http/1.1']),
          _closedEvent.future.then<RawSecureSocket>(
              (_) => throw StateError('HTTP/2 pool is closed')),
        ]);
      } finally {
        _handshaking.remove(raw);
        _handshaking.remove(tunnelSocket);
      }
      attempt.sockets.add(socket);
      attempt.check();
      if (_closed) {
        await socket.close();
        throw StateError('HTTP/2 pool is closed');
      }
      if (socket.selectedProtocol != 'h2') {
        _http1Sockets.remove(origin)?.destroy();
        _http1Sockets[origin] = RawTlsSocket(socket);
        return null;
      }
      final channel = RawTlsChannel(socket);
      late ClientTransportConnection connection;
      final observer = Http2FrameObserver(() {
        _draining.add(connection);
        notifyCapacity();
      });
      connection =
          ClientTransportConnection.viaStreams(channel.input.map((bytes) {
        observer.add(bytes);
        return bytes;
      }), channel.output);
      final frames = connection.onFrameReceived.listen((_) => notifyCapacity());
      connection.onActiveStateChanged = (_) => notifyCapacity();
      attempt.connection = connection;
      (_byOrigin[origin] ??= {}).add(connection);
      _connections.add(connection);
      _originConnections[origin] = connection;
      // Frame notifications do not close in http2 2.3.1; observe TLS EOF.
      unawaited(channel.done.then<void>((_) {
        _connections.remove(connection);
        _byOrigin[origin]?.remove(connection);
        _draining.remove(connection);
        unawaited(frames.cancel());
        notifyCapacity();
        if (identical(_originConnections[origin], connection)) {
          _originConnections.remove(origin);
          _pending.remove(origin);
        }
        unawaited(channel.close());
      }));
      // Do not expose the transport before peer limits have been applied.
      // TLS completion alone says nothing about MAX_CONCURRENT_STREAMS.
      await Future.any<void>([
        connection.onInitialPeerSettingsReceived,
        channel.done.then<void>((_) =>
            throw StateError('HTTP/2 peer closed before initial SETTINGS')),
        _closedEvent.future
            .then<void>((_) => throw StateError('HTTP/2 pool is closed')),
      ]);
      if (_closed) throw StateError('HTTP/2 pool is closed');
      return connection;
    } catch (_) {
      if (attempt.isCanceled) attempt.closeSockets();
      rethrow;
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _closedEvent.complete();
    for (final task in _connecting.toList()) {
      task.cancel();
    }
    final handshakes = _handshaking.toList();
    _handshaking.clear();
    final connections = _connections.toList();
    _connections.clear();
    _originConnections.clear();
    _pending.clear();
    for (final socket in _http1Sockets.values) {
      socket.destroy();
    }
    _http1Sockets.clear();
    _byOrigin.clear();
    _draining.clear();
    notifyCapacity();
    await Future.wait<void>([
      for (final raw in handshakes) raw.close().then<void>((_) {}),
      for (final connection in connections)
        connection.terminate().then<void>((_) {}),
    ]);
  }
}

class _ConnectionAttempt {
  final Uri uri;
  bool pinned;
  bool isCanceled = false;
  ConnectionTask<RawSocket>? task;
  ClientTransportConnection? connection;
  final List<RawSocket> sockets = [];
  final Completer<ClientTransportConnection?> canceled = Completer();
  _ConnectionAttempt(this.uri, {required this.pinned});
  void check() {
    if (!isCanceled) return;
    closeSockets();
    throw http.RequestAbortedException(uri);
  }

  void closeSockets() {
    for (final socket in sockets) {
      unawaited(socket.close());
    }
  }

  void cancel() {
    if (isCanceled) return;
    isCanceled = true;
    task?.cancel();
    closeSockets();
    canceled.completeError(http.RequestAbortedException(uri));
  }
}
