import 'errors.dart';

// Request-local context for native connectionFactory callbacks.
final proxyRequestAbortKey = Object();

Uri? parseHttpProxy(String? proxy) {
  if (proxy == null || proxy.isEmpty) return null;
  final uri = Uri.tryParse(proxy);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    throw const InvalidArgumentException(
        'Dart native proxy must be an HTTP or HTTPS URL');
  }
  return uri;
}

(String, String) proxyCredentials(Uri proxy) {
  final colon = proxy.userInfo.indexOf(':');
  return (
    Uri.decodeComponent(
        colon < 0 ? proxy.userInfo : proxy.userInfo.substring(0, colon)),
    Uri.decodeComponent(colon < 0 ? '' : proxy.userInfo.substring(colon + 1))
  );
}
