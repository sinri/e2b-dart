import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'proxy_config.dart';

/// A plaintext origin HTTP connection carried through a CONNECT tunnel.
Future<ConnectionTask<Socket>> plainProxyConnection(Uri target, Uri proxy,
    {SecurityContext? context, Future<void>? abortTrigger}) async {
  final ConnectionTask<Socket> connecting = proxy.scheme == 'https'
      ? await SecureSocket.startConnect(proxy.host, proxy.port,
          context: context, supportedProtocols: ['http/1.1'])
      : await Socket.startConnect(proxy.host, proxy.port);
  Socket? socket;
  var canceled = false;
  var pending = true;
  final cancel = Completer<Socket>();
  final connected = connecting.socket.then<Socket>((value) async {
    socket = value;
    try {
      if (canceled) {
        value.destroy();
        throw const SocketException('Proxy connection canceled');
      }
      return await _PlainProxySocket(value, target, proxy).ready;
    } finally {
      pending = false;
    }
  });
  final task = ConnectionTask.fromSocket(
      Future.any<Socket>([connected, cancel.future]), () {
    if (canceled || !pending) return;
    canceled = true;
    connecting.cancel();
    socket?.destroy();
    cancel.completeError(const SocketException('Proxy connection canceled'));
  });
  abortTrigger?.then((_) => task.cancel());
  return task;
}

/// Keeps the original socket subscription through the CONNECT response, then
/// exposes only tunnel bytes to HttpClient. TLS upgrades are never used here.
class _PlainProxySocket extends Stream<Uint8List> implements Socket {
  final Socket inner;
  final _ready = Completer<Socket>();
  final _header = <int>[];
  late final StreamController<Uint8List> _input;
  late final StreamSubscription<Uint8List> _subscription;
  Future<Socket> get ready => _ready.future;
  _PlainProxySocket(this.inner, Uri target, Uri proxy) {
    _input = StreamController<Uint8List>(
        onListen: () => _subscription.resume(),
        onPause: () => _subscription.pause(),
        onResume: () => _subscription.resume(),
        onCancel: destroy);
    _subscription = inner.listen((bytes) {
      if (_ready.isCompleted) {
        _input.add(bytes);
        return;
      }
      _header.addAll(bytes);
      final text = latin1.decode(_header);
      final end = text.indexOf('\r\n\r\n');
      if ((end < 0 && _header.length > 65536) || end > 65532) {
        _fail(const SocketException('Proxy CONNECT headers exceed 64 KiB'));
      } else if (end >= 0) {
        final match =
            RegExp(r'^HTTP/1\.[01] ([0-9]{3})(?: |\r)').firstMatch(text);
        if (match == null || match.group(1) != '200') {
          _fail(SocketException(
              'Proxy CONNECT failed: ${text.split('\r\n').first}'));
          return;
        }
        if (end + 4 < _header.length) {
          _input.add(Uint8List.fromList(_header.sublist(end + 4)));
        }
        _header.clear();
        _subscription.pause();
        _ready.complete(this);
      }
    }, onError: (Object error, StackTrace stack) {
      if (!_ready.isCompleted) {
        _fail(error);
      } else {
        _input.addError(error, stack);
      }
    }, onDone: () {
      if (!_ready.isCompleted) {
        _fail(const SocketException('Proxy closed during CONNECT'));
      }
      unawaited(_input.close());
    });
    final host = target.host.contains(':') ? '[${target.host}]' : target.host;
    final authority = '$host:${target.port}';
    final (user, password) = proxyCredentials(proxy);
    final auth = proxy.userInfo.isEmpty
        ? ''
        : 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('$user:$password'))}\r\n';
    inner.write('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$auth\r\n');
  }
  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    inner.destroy();
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _input.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  void destroy() => inner.destroy();
  @override
  int get port => inner.port;
  @override
  int get remotePort => inner.remotePort;
  @override
  InternetAddress get address => inner.address;
  @override
  InternetAddress get remoteAddress => inner.remoteAddress;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => inner.setRawOption(option);
  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;
  @override
  void add(List<int> data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => inner.addStream(stream);
  @override
  void write(Object? object) => inner.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => inner.writeln(object);
  @override
  Future<void> flush() => inner.flush();
  @override
  Future close() => inner.close();
  @override
  Future get done => inner.done;
  // Socket has a private SDK-only detach method. This adapter is only used for
  // HTTP origins and is never passed to SecureSocket.secure.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
