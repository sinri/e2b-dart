import 'api_endpoint_client.dart';
import 'http_defaults.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'connection.dart';
import 'connection_error_stub.dart'
    if (dart.library.io) 'connection_error_io.dart';
import 'errors.dart';
import 'metadata.dart';
import 'logs.dart';
import 'retry_config.dart';
import 'http_client_pool.dart';
import 'http_dispatch_config.dart';
import 'transport.dart' show decodeBody;

/// Shared management transport with safe replay rules and one total deadline.
class ApiClient {
  late final ApiEndpointClient api = ApiEndpointClient(this);
  final ConnectionConfig config;
  final HttpClientPool clientPool;
  http.Client get httpClient =>
      clientPool.get(config.proxy, httpVersion: config.httpVersion);
  http.Client httpClientFor(RequestOptions? options) {
    return clientPool.get(options?.proxy ?? config.proxy,
        httpVersion: options?.httpVersion ?? config.httpVersion);
  }

  http.Client envdHttpClientFor(RequestOptions? options, {bool rpc = false}) =>
      clientPool.get(options?.proxy ?? config.proxy,
          httpVersion: options?.httpVersion ?? config.httpVersion,
          scope: rpc ? HttpDispatchScope.envdRpc : HttpDispatchScope.envdRest);

  final bool _ownsHttp;
  final bool _requireApiKey;
  static const _missingApiKeyMessage =
      'API key is required, please visit the API Keys tab at https://e2b.dev/dashboard?tab=keys to get your API key. '
      'You can either set the environment variable `E2B_API_KEY` '
      "or you can pass it directly to the sandbox like Sandbox.create({ apiKey: 'e2b_...' })";
  final Random _random = Random();
  ApiClient(
      {String? apiKey,
      bool requireApiKey = true,
      // Reusable Dart resources resolve per-call credentials before validation.
      bool deferApiKeyValidation = false,
      bool? validateApiKey,
      Logger? logger,
      String? proxy,
      HttpVersion? httpVersion,
      String? domain,
      Uri? apiUrl,
      Uri? sandboxUrl,
      Uri? volumeApiUrl,
      bool? debug,
      Duration requestTimeout = const Duration(seconds: 60),
      num retries = 3,
      http.Client? httpClient,
      HttpClientPool? clientPool,
      Map<String, String> headers = const {},
      Map<String, String> apiHeaders = const {}})
      : config = ConnectionConfig(
            apiKey: apiKey,
            validateApiKey: validateApiKey,
            logger: logger,
            proxy: proxy,
            httpVersion: httpVersion,
            domain: domain,
            apiUrl: apiUrl,
            sandboxUrl: sandboxUrl,
            volumeApiUrl: volumeApiUrl,
            debug: debug,
            requestTimeout: requestTimeout,
            retries: retries,
            headers: headers,
            apiHeaders: apiHeaders),
        clientPool =
            clientPool ?? HttpClientPool(proxy: proxy, client: httpClient),
        _ownsHttp = clientPool == null,
        _requireApiKey = requireApiKey {
    if (requireApiKey &&
        !deferApiKeyValidation &&
        (config.apiKey == null || config.apiKey!.isEmpty)) {
      if (_ownsHttp) this.clientPool.close();
      throw const AuthenticationException(_missingApiKeyMessage);
    }
  }
  String get apiKey => config.apiKey ?? '';
  String get domain => config.domain;
  Uri get apiUrl => config.apiUrl;
  Uri? get sandboxUrl => config.sandboxUrl;
  Duration get requestTimeout => config.requestTimeout;
  Map<String, String> get headers => config.headers;

  /// Resolve custom management headers at the time a request is constructed.
  Map<String, String> requestHeaders(RequestOptions? options) =>
      {...headers, ...?options?.headers};

  Future<http.Response> requestResponse(String method, String path,
      {Object? body,
      Map<String, String>? query,
      Object Function(int status, Object? body, String? reason)? responseError,
      RequestOptions? options,
      bool validateStatus = true,
      bool addJsonContentType = true,
      String? rawQuery,
      List<int>? serializedBody,
      bool serializeBody = true,
      String Function(String url)? pathSerializer,
      Future<http.Response> Function(http.Request request,
              Future<http.Response> Function(http.Request) send)?
          exchange}) async {
    resolveHttpVersion(options?.httpVersion ?? config.httpVersion);
    final retries = resolveRetries(options?.retries ?? config.retries);
    final key = options?.apiKey ?? config.apiKey;
    if (_requireApiKey && (key == null || key.isEmpty)) {
      throw const AuthenticationException(_missingApiKeyMessage);
    }
    final timeout = options?.requestTimeout ?? requestTimeout;
    final signal = options?.signal;
    signal?.throwIfCanceled();
    final requestClient = httpClientFor(options);
    final base = options?.apiUrl != null ||
            options?.domain != null ||
            options?.debug != null
        ? ConnectionConfig(
                domain: options?.domain ?? domain,
                debug: options?.debug ?? config.debug,
                apiUrl: options?.apiUrl ?? config.explicitApiUrl)
            .apiUrl
        : apiUrl;
    final resolvedUrl = pathSerializer == null
        ? base.resolve(path).toString()
        : pathSerializer(
            '${base.toString().replaceFirst(RegExp(r'/$'), '')}$path');
    final uri = rawQuery == null
        ? Uri.parse(resolvedUrl).replace(queryParameters: query)
        : rawQuery.isEmpty
            ? Uri.parse(resolvedUrl)
            : Uri.parse('$resolvedUrl?$rawQuery');
    final resolvedHeaders = {
      ...defaultHeaders,
      if (key != null && key.isNotEmpty) 'X-API-Key': key,
      if (addJsonContentType) 'Content-Type': 'application/json',
      ...requestHeaders(options)
    };
    final logger = options?.logger ?? config.logger;
    logger?.info?.call(['Request $method $uri']);
    final prepared = http.Request(method, uri)..headers.addAll(resolvedHeaders);
    final bytes = serializeBody
        ? (body == null ? null : utf8.encode(jsonEncode(body)))
        : serializedBody;
    if (bytes != null) prepared.bodyBytes = bytes;
    Future<http.Response> transmit(http.Request prepared) async {
      final sendHeaders = Map<String, String>.of(prepared.headers);
      final clock = Stopwatch()..start();
      final replayable = isReplayable(prepared.method, prepared.url.path);
      final bytes = prepared.bodyBytes;
      Duration? remaining() =>
          timeout == Duration.zero ? null : timeout - clock.elapsed;
      Future<T> bounded<T>(Future<T> future) {
        final left = remaining();
        return left == null
            ? future
            : future.timeout(left > Duration.zero ? left : Duration.zero);
      }

      for (var attempt = 0;; attempt++) {
        final abort = Completer<void>();
        void stop() {
          if (!abort.isCompleted) abort.complete();
        }

        final remove = signal?.listen(stop);
        http.Response? response;
        Object? failure;
        StackTrace? failureStack;
        try {
          signal?.throwIfCanceled();
          final request = http.AbortableRequest(prepared.method, prepared.url,
              abortTrigger: abort.future);
          request.maxRedirects = fetchRedirectLimit;
          request.headers.addAll(sendHeaders);
          request.bodyBytes = bytes;
          response = await bounded((() async =>
              http.Response.fromStream(await requestClient.send(request)))());
        } catch (error, stack) {
          signal?.throwIfCanceled();
          failure = error;
          failureStack = stack;
        } finally {
          stop();
          remove?.call();
        }
        signal?.throwIfCanceled();
        Duration? delay;
        if (failure != null) {
          if (failure is! http.RequestAbortedException &&
              (isConnectionEstablishmentError(failure) ||
                  (replayable &&
                      (failure is http.ClientException ||
                          isSocketNetworkError(failure))))) {
            delay = _backoff(attempt);
          }
        } else {
          final status = response!.statusCode;
          if (status == 429 || status == 503 || (status == 502 && replayable)) {
            final seconds = parseRetryAfter(response.headers['retry-after']);
            if (seconds != null) {
              delay = Duration(seconds: seconds);
            } else if (status != 429) {
              delay = _backoff(attempt);
            }
          }
        }
        final retryDeadline =
            timeout == Duration.zero ? const Duration(seconds: 60) : timeout;
        if (attempt >= retries ||
            delay == null ||
            clock.elapsed + delay >= retryDeadline) {
          if (failure != null) {
            Error.throwWithStackTrace(failure, failureStack!);
          }
          final log =
              response!.statusCode >= 400 ? logger?.error : logger?.info;
          log?.call(
              ['Response:', response.statusCode, response.reasonPhrase ?? '']);
          if (validateStatus && response.statusCode >= 300) {
            if (responseError != null) {
              throw responseError(response.statusCode,
                  decodeBody(response.body), response.reasonPhrase);
            }
            throwApiError(decodeBody(response.body),
                statusCode: response.statusCode);
          }
          return response;
        }
        await cancellableDelay(delay, signal);
      }
    }

    return exchange == null ? transmit(prepared) : exchange(prepared, transmit);
  }

  Duration _backoff(int attempt) {
    final maximum = min(100 * pow(2, min(attempt, 20)), 10000);
    return Duration(
        milliseconds: (maximum * (0.5 + _random.nextDouble() * 0.5)).floor());
  }

  Future<Object?> request(String method, String path,
          {Object? body,
          Map<String, String>? query,
          Object Function(int status, Object? body, String? reason)?
              responseError,
          RequestOptions? options}) async =>
      decodeBody((await requestResponse(method, path,
              body: body,
              query: query,
              options: options,
              responseError: responseError))
          .body);
  void close() {
    if (_ownsHttp) clientPool.close();
  }
}

int? parseRetryAfter(String? value) {
  if (value == null || !RegExp(r'^\d+$').hasMatch(value.trim())) return null;
  final seconds = int.tryParse(value.trim());
  return seconds != null && seconds <= 2147483 ? seconds : null;
}

bool isReplayable(String method, String path) {
  if (const {'GET', 'PUT', 'PATCH', 'DELETE'}.contains(method.toUpperCase())) {
    return true;
  }
  if (method.toUpperCase() != 'POST') return false;
  return RegExp(r'^/sandboxes/[^/]+/(pause|resume|timeout|refreshes)$')
          .hasMatch(path) ||
      RegExp(r'^/(v2/)?sandboxes/[^/]+/connect$').hasMatch(path) ||
      path == '/v3/templates' ||
      RegExp(r'^/v2/templates/[^/]+/builds/[^/]+$').hasMatch(path) ||
      path == '/templates/tags' ||
      RegExp(r'^/nodes/[^/]+$').hasMatch(path) ||
      RegExp(r'^/admin/teams/[^/]+/(sandboxes/kill|builds/cancel)$')
          .hasMatch(path);
}
