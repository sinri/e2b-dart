import 'js_number.dart';
import 'dart:async';
import 'environment_stub.dart' if (dart.library.io) 'environment_io.dart'
    as env;
import 'errors.dart';
import 'metadata.dart';
import 'logs.dart';
import 'retry_config.dart';

typedef Username = String;

/// Accepted protocol values are '1.1' and '2'. Native transport support is
/// tracked separately from configuration parsing.
typedef HttpVersion = String;

/// Resolve explicit values before environment defaults, matching the JS SDK.
HttpVersion resolveHttpVersion([String? httpVersion]) {
  var source = 'httpVersion';
  if (httpVersion == null) {
    source = 'E2B_HTTP_VERSION';
    final configured = env.environmentValue('E2B_HTTP_VERSION');
    httpVersion = configured == null || configured.isEmpty ? '2' : configured;
  }
  if (httpVersion != '1.1' && httpVersion != '2') {
    throw InvalidArgumentException(
        "$source must be '1.1' or '2', got '$httpVersion'");
  }
  return httpVersion;
}

/// Per-request cancellation. A signal is never stored as a client default.
class CancellationSignal {
  bool _canceled = false;
  Object? _reason;
  final Set<void Function()> _listeners = {};
  bool get isCanceled => _canceled;
  Object get reason =>
      _reason ?? const CancellationException('Request canceled');
  void throwIfCanceled() {
    if (_canceled) throw reason;
  }

  void cancel([Object? reason]) {
    if (_canceled) return;
    _canceled = true;
    _reason = reason;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  /// Returns a function that removes the listener after the request completes.
  void Function() listen(void Function() listener) {
    if (_canceled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// Connection overrides for a single operation. Null means inherit.
class RequestOptions {
  final String? proxy;
  final HttpVersion? httpVersion;
  final Logger? logger;
  final bool hasHeadersOverride;
  final String? apiKey;

  /// Retained for JS compatibility; API key format validation is disabled.
  final bool? validateApiKey;
  final bool? debug;
  final String? domain;
  final Uri? apiUrl;
  final Uri? sandboxUrl;
  Map<String, String> get headers =>
      Map.unmodifiable({...?legacyHeaders, ...?apiHeaders});

  /// Unmerged references retain omission and observe caller changes per request.
  final Map<String, String>? legacyHeaders;
  final Map<String, String>? apiHeaders;
  final Duration? requestTimeout;
  final num? retries;
  final CancellationSignal? signal;
  RequestOptions(
      {this.apiKey,
      this.validateApiKey,
      this.logger,
      this.proxy,
      this.httpVersion,
      this.debug,
      this.domain,
      this.apiUrl,
      this.sandboxUrl,
      Map<String, String>? headers,
      this.apiHeaders,
      this.requestTimeout,
      this.retries,
      this.signal})
      : hasHeadersOverride = headers != null || apiHeaders != null,
        legacyHeaders = headers {
    if (requestTimeout != null && requestTimeout! < Duration.zero) {
      throw const InvalidArgumentException(
          'requestTimeout must be nonnegative');
    }
  }

  /// Per-call values override bound values; omitted fields inherit them.
  static RequestOptions? merge(RequestOptions? bound, RequestOptions? call) {
    if (bound == null) return call;
    if (call == null) return bound;
    return RequestOptions(
      apiKey: call.apiKey ?? bound.apiKey,
      logger: call.logger ?? bound.logger,
      proxy: call.proxy ?? bound.proxy,
      httpVersion: call.httpVersion ?? bound.httpVersion,
      validateApiKey: call.validateApiKey ?? bound.validateApiKey,
      debug: call.debug ?? bound.debug,
      domain: call.domain ?? bound.domain,
      apiUrl: call.apiUrl ?? bound.apiUrl,
      sandboxUrl: call.sandboxUrl ?? bound.sandboxUrl,
      headers: call.legacyHeaders ?? bound.legacyHeaders,
      apiHeaders: call.apiHeaders ?? bound.apiHeaders,
      requestTimeout: call.requestTimeout ?? bound.requestTimeout,
      retries: call.retries ?? bound.retries,
      signal: call.signal ?? bound.signal,
    );
  }
}

/// Resolved, isolated configuration shared by client resources.
class ConnectionConfig {
  static int envdPort = 49983;

  /// Shallow option merge. A null map means no supplied options; null values
  /// inside a map are explicit values, corresponding to JavaScript null.
  /// Omit a key to represent JavaScript undefined.
  static Map<String, T>? mergeOpts<T>(Map<String, T>? boundOpts,
      [Map<String, T>? opts]) {
    if (boundOpts == null) return opts;
    return {...boundOpts, ...?opts};
  }

  final Logger? logger;
  final String? proxy;
  static String? _integration;
  static const _userAgentPrefix = 'e2b-dart-sdk/';

  /// Identify an integration wrapping this SDK. Existing configs stay isolated.
  static void setIntegration(String? integration) => _integration = integration;

  static Map<String, String> _headers(Map<String, String> values) {
    final result = {...values};
    final userAgent = result['User-Agent'];
    if (userAgent == null || userAgent.startsWith(_userAgentPrefix)) {
      result['User-Agent'] = '$_userAgentPrefix$sdkVersion'
          '${_integration == null || _integration!.isEmpty ? '' : ' $_integration'}';
    }
    return Map.unmodifiable(result);
  }

  final String? apiKey;

  /// Retained for JS compatibility; API key format validation is disabled.
  final bool? validateApiKey;
  final String domain;
  final Uri apiUrl;

  /// Caller-supplied API URL, before environment and domain defaults resolve.
  final Uri? explicitApiUrl;
  final Uri? sandboxUrl;
  final Uri? volumeApiUrl;
  final bool debug;
  final HttpVersion httpVersion;
  final Duration requestTimeout;
  final num retries;
  final Map<String, String> headers;
  ConnectionConfig(
      {String? apiKey,
      this.validateApiKey,
      this.logger,
      this.proxy,
      String? httpVersion,
      String? domain,
      Uri? apiUrl,
      Uri? sandboxUrl,
      Uri? volumeApiUrl,
      bool? debug,
      this.requestTimeout = const Duration(seconds: 60),
      this.retries = 3,
      Map<String, String> headers = const {},
      Map<String, String> apiHeaders = const {}})
      : httpVersion = resolveHttpVersion(httpVersion),
        explicitApiUrl = apiUrl,
        apiKey = (apiKey == null || apiKey.isEmpty)
            ? env.environmentValue('E2B_API_KEY')
            : apiKey,
        domain = _domain(domain),
        debug = debug ??
            (env.environmentValue('E2B_DEBUG')?.toLowerCase() == 'true'),
        apiUrl = _uri(apiUrl?.toString()) ??
            _uri(env.environmentValue('E2B_API_URL')) ??
            Uri.parse((debug ??
                    (env.environmentValue('E2B_DEBUG')?.toLowerCase() ==
                        'true'))
                ? 'http://localhost:3000'
                : 'https://api.${_domain(domain)}'),
        sandboxUrl = _uri(sandboxUrl?.toString()) ??
            _uri(env.environmentValue('E2B_SANDBOX_URL')),
        volumeApiUrl =
            volumeApiUrl ?? _uri(env.environmentValue('E2B_VOLUME_API_URL')),
        headers = _headers({...headers, ...apiHeaders}) {
    resolveRetries(retries);
    if (requestTimeout < Duration.zero) {
      throw const InvalidArgumentException(
          'requestTimeout must be nonnegative');
    }
  }
  static String _domain(String? value) {
    if (value != null && value.isNotEmpty) return value;
    final configured = env.environmentValue('E2B_DOMAIN');
    return configured == null || configured.isEmpty ? 'e2b.app' : configured;
  }

  static Uri? _uri(String? value) =>
      value == null || value.isEmpty ? null : Uri.parse(value);

  String getHost(String sandboxId, num port, {String? sandboxDomain}) => debug
      ? 'localhost:${jsNumberString(port)}'
      : '${jsNumberString(port)}-$sandboxId.${sandboxDomain ?? domain}';

  /// API requests use the shared sandbox endpoint on supported native hosts.
  Uri getSandboxUrl(String sandboxId,
      {String? sandboxDomain, int envdPort = 49983}) {
    if (sandboxUrl != null) return sandboxUrl!;
    if (debug) {
      return getSandboxDirectUrl(sandboxId,
          sandboxDomain: sandboxDomain, envdPort: envdPort);
    }
    final resolvedDomain = sandboxDomain ?? domain;
    const supported = ['e2b.app', 'e2b.dev', 'e2b.pro', 'e2b-staging.dev'];
    if (!env.isBrowserRuntime && supported.contains(resolvedDomain)) {
      return Uri.parse('https://sandbox.$resolvedDomain');
    }
    return getSandboxDirectUrl(sandboxId,
        sandboxDomain: resolvedDomain, envdPort: envdPort);
  }

  /// Signed file URLs always address the sandbox directly.
  Uri getSandboxDirectUrl(String sandboxId,
      {String? sandboxDomain, int envdPort = 49983}) {
    if (sandboxUrl != null) return sandboxUrl!;
    return Uri.parse(
        '${debug ? 'http' : 'https'}://${getHost(sandboxId, envdPort, sandboxDomain: sandboxDomain)}');
  }
}

/// A cancellable wait used for backoff; cancellation also removes the timer.
Future<void> cancellableDelay(
    Duration duration, CancellationSignal? signal) async {
  signal?.throwIfCanceled();
  final done = Completer<void>();
  final timer = Timer(duration, done.complete);
  final remove = signal?.listen(() {
    if (!done.isCompleted) done.completeError(signal.reason);
  });
  try {
    await done.future;
  } finally {
    timer.cancel();
    remove?.call();
  }
}
