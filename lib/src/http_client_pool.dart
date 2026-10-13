import 'package:http/http.dart' as http;
import 'http_dispatch_config.dart';
import 'environment_stub.dart' if (dart.library.io) 'environment_io.dart'
    as env;
import 'connection.dart' show resolveHttpVersion;
import 'http_client_stub.dart' if (dart.library.io) 'http_client_io.dart';

/// Root pools lease transports shared within this Dart isolate.
/// Injected clients remain owned by their caller.
class HttpClientPool {
  final Map<String, http.Client> _clients = {};
  static final Map<String, _SharedHttpClient> _shared = {};
  final Map<String, _SharedHttpClient> _leases = {};
  bool _closed = false;
  HttpClientPool({String? proxy, http.Client? client}) {
    if (client != null) {
      // An explicitly supplied transport remains authoritative for both versions.
      for (final version in ['1.1', '2']) {
        for (final scope in HttpDispatchScope.values) {
          _clients['${scope.name}:$version:${proxy ?? ''}'] = client;
        }
      }
    }
  }
  http.Client get(String? proxy,
      {String? httpVersion, HttpDispatchScope scope = HttpDispatchScope.api}) {
    if (_closed) throw StateError('HTTP client pool is closed');
    final version = resolveHttpVersion(httpVersion);
    final key = '${scope.name}:$version:${proxy ?? ''}';
    return _clients.putIfAbsent(key, () {
      final lease = _shared.putIfAbsent(
          key,
          () => _SharedHttpClient(createHttpClient(proxy,
              httpVersion: version,
              maxInFlight:
                  env.isBrowserRuntime ? null : inflightLimitFor(scope),
              connectionLimit:
                  env.isBrowserRuntime ? null : connectionLimitFor(scope))));
      lease.references++;
      _leases[key] = lease;
      return lease.client;
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final entry in _leases.entries) {
      final lease = entry.value;
      if (--lease.references == 0) {
        if (identical(_shared[entry.key], lease)) _shared.remove(entry.key);
        lease.client.close();
      }
    }
    _clients.clear();
    _leases.clear();
  }
}

class _SharedHttpClient {
  final http.Client client;
  int references = 0;
  _SharedHttpClient(this.client);
}
