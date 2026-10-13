import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'proxy_config.dart';
import 'plain_proxy_socket_io.dart';
import 'secure_proxy_socket_io.dart';
export 'proxy_config.dart' show parseHttpProxy, proxyCredentials;

HttpClient nativeHttpClient(
    {SecurityContext? context,
    String? proxy,
    num connectionLimit = 100,
    Socket? Function(Uri)? takePreconnected}) {
  final uri = parseHttpProxy(proxy);
  final requests = _ProxyRequestRegistry();
  final client = HttpClient(context: context)
    ..maxConnectionsPerHost = connectionLimit.toInt();
  if (uri == null && takePreconnected == null) return client;
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (target, proxyHost, proxyPort) {
    final existing = takePreconnected?.call(target);
    if (existing != null) {
      return Future.value(
          ConnectionTask.fromSocket(Future.value(existing), existing.destroy));
    }
    if (uri == null) {
      return target.scheme == 'https'
          ? SecureSocket.startConnect(target.host, target.port,
              context: context, supportedProtocols: ['http/1.1'])
          : Socket.startConnect(target.host, target.port);
    }
    if (target.scheme == 'http') {
      return plainProxyConnection(target, uri,
          context: context, abortTrigger: requests.take(target));
    }
    return secureProxyConnection(target, uri,
        context: context, abortTrigger: requests.take(target));
  };
  return uri == null ? client : _ProxySafeHttpClient(client, requests);
}

/// Carries each request's cancellation ticket into the native connection queue
/// and keeps proxy authorization out of origin HTTPS requests.
class _ProxySafeHttpClient implements HttpClient {
  final HttpClient inner;
  final _ProxyRequestRegistry requests;
  _ProxySafeHttpClient(this.inner, this.requests);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final context =
        requests.add(url, Zone.current[proxyRequestAbortKey] as Future<void>?);
    try {
      final request = await runZoned(() => inner.openUrl(method, url),
          zoneValues: {_proxyOpeningContext: context});
      if (url.scheme == 'https' && method != 'CONNECT') {
        request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
      }
      return request;
    } finally {
      requests.remove(url, context);
    }
  }

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      inner.open(method, host, port, path);
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  set authenticate(Future<bool> Function(Uri, String, String?)? value) =>
      inner.authenticate = value;
  @override
  set authenticateProxy(
          Future<bool> Function(String, int, String, String?)? value) =>
      inner.authenticateProxy = value;
  @override
  set findProxy(String Function(Uri)? value) => inner.findProxy = value;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value) =>
      inner.connectionFactory = value;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate, String, int)? value) =>
      inner.badCertificateCallback = value;
  @override
  set keyLog(Function(String)? value) => inner.keyLog = value;
  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      inner.addProxyCredentials(host, port, realm, credentials);
  @override
  Duration get idleTimeout => inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => inner.autoUncompress;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;
  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
}

// dart:io invokes queued connectionFactory callbacks in the releasing request's
// Zone. Claim each openUrl context explicitly instead of reading that Zone.
final _proxyOpeningContext = Object();

class _ProxyRequestRegistry {
  final Map<Uri, Queue<_ProxyRequestContext>> _pending = {};
  _ProxyRequestContext add(Uri uri, Future<void>? abort) {
    final context = _ProxyRequestContext(abort);
    (_pending[uri] ??= Queue()).add(context);
    return context;
  }

  Future<void>? take(Uri uri) {
    final queue = _pending[uri];
    if (queue == null || queue.isEmpty) return null;
    final opening = Zone.current[_proxyOpeningContext];
    // Immediate calls use their exact ticket; queued calls can inherit an
    // already claimed/removed ticket and must claim the next waiting request.
    final context = opening is _ProxyRequestContext && queue.contains(opening)
        ? opening
        : queue.first;
    queue.remove(context);
    if (queue.isEmpty) _pending.remove(uri);
    return context.abort;
  }

  void remove(Uri uri, _ProxyRequestContext context) {
    final queue = _pending[uri];
    queue?.remove(context);
    if (queue != null && queue.isEmpty) _pending.remove(uri);
  }
}

class _ProxyRequestContext {
  final Future<void>? abort;
  _ProxyRequestContext(this.abort);
}
