import 'http_defaults.dart';
import 'dart:async';
import 'logs.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'errors.dart';
import 'content_transport.dart';
import 'connection.dart';

Object? decodeBody(String body) {
  if (body.isEmpty) return null;
  try {
    return jsonDecode(body);
  } on FormatException {
    return body;
  }
}

class EnvdRpcException extends E2BException {
  const EnvdRpcException(super.message, {super.code, super.statusCode});
}

Never _throwRpcError(Object? body, {int? statusCode}) {
  final data = body is Map ? body : const {};
  throw EnvdRpcException(
      data['message']?.toString() ?? body?.toString() ?? 'Request failed',
      code: data['code']?.toString() ??
          (statusCode == 502 ? 'unavailable' : null),
      statusCode: statusCode);
}

/// Connect JSON envelopes (flag byte + unsigned big endian length + payload).
Uint8List envelope(Map<String, dynamic> message) {
  final payload = utf8.encode(jsonEncode(message));
  final frame = Uint8List(5 + payload.length);
  ByteData.sublistView(frame).setUint32(1, payload.length);
  frame.setRange(5, frame.length, payload);
  return frame;
}

Stream<Map<String, dynamic>> decodeEnvelopes(Stream<List<int>> source,
    {bool rawErrors = false}) {
  var pending = <int>[];
  var ended = false;
  return source.transform(
      StreamTransformer<List<int>, Map<String, dynamic>>.fromHandlers(
    handleData: (chunk, sink) {
      try {
        if (ended && chunk.isNotEmpty) {
          throw const E2BException('Data after Connect end envelope');
        }
        pending.addAll(chunk);
        while (pending.length >= 5) {
          final header = Uint8List.fromList(pending.sublist(0, 5));
          final flags = header[0];
          final length = ByteData.sublistView(header).getUint32(1);
          if (length > 16 * 1024 * 1024) {
            throw const E2BException('Connect envelope exceeds 16 MiB');
          }
          if (pending.length < 5 + length) break;
          if (ended) {
            throw const E2BException('Data after Connect end envelope');
          }
          if (flags != 0 && flags != 2) {
            throw const E2BException('Unsupported Connect envelope flags');
          }
          final payload =
              jsonDecode(utf8.decode(pending.sublist(5, 5 + length)))
                  as Map<String, dynamic>;
          pending = pending.sublist(5 + length);
          if (flags == 2) {
            ended = true;
            if (payload['error'] != null) {
              if (rawErrors) _throwRpcError(payload['error']);
              throwApiError(payload['error']);
            }
          } else {
            sink.add(payload);
          }
        }
      } catch (error, stack) {
        sink.addError(error, stack);
      }
    },
    handleDone: (sink) {
      if (pending.isNotEmpty || !ended) {
        sink.addError(const E2BException('Truncated Connect stream'));
      }
      sink.close();
    },
  ));
}

class EnvdTransport {
  final http.Client Function(RequestOptions? options)? clientResolver;
  final http.Client Function(RequestOptions? options)? restClientResolver;
  final http.Client? _restClient;
  http.Client get restClient => _restClient ?? client;
  final Logger? logger;
  final http.Client client;
  final Uri baseUrl;
  final Map<String, String> headers;
  final Duration requestTimeout;
  final CancellationSignal? signal;
  String? defaultUser;
  String version = '';
  bool supports(String required) {
    final actual = version.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final minimum = required.split('.').map(int.parse).toList();
    for (var i = 0; i < minimum.length; i++) {
      final a = i < actual.length ? actual[i] : 0;
      if (a != minimum[i]) return a > minimum[i];
    }
    return true;
  }

  EnvdTransport(this.client, this.baseUrl, this.headers, this.requestTimeout,
      {this.signal,
      this.logger,
      this.clientResolver,
      this.restClientResolver,
      http.Client? restClient})
      : _restClient = restClient;

  EnvdTransport withOptions(RequestOptions? options) {
    if (options == null) return this;
    final resolvedClient = clientResolver?.call(options) ?? client;
    return EnvdTransport(resolvedClient, baseUrl, headers,
        options.requestTimeout ?? requestTimeout,
        signal: options.signal,
        logger: options.logger ?? logger,
        clientResolver: clientResolver,
        restClientResolver: restClientResolver,
        restClient:
            restClientResolver?.call(options) ?? _restClient ?? resolvedClient)
      ..defaultUser = defaultUser
      ..version = version;
  }

  Map<String, String> requestHeaders(String? user) => {
        ...headers,
        if (user != null || defaultUser != null)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('${user ?? defaultUser}:'))}',
        'Connect-Protocol-Version': '1',
      };
  Uri uri(String path, [Map<String, String>? query]) =>
      baseUrl.resolve(path).replace(queryParameters: query);

  Future<Map<String, dynamic>> rpc(
      String service, String method, Map<String, dynamic> body,
      {String? user}) async {
    try {
      logger?.info?.call(['Request: POST ${uri('/$service/$method')}']);
      final response = await ContentTransport(
              client, baseUrl, requestHeaders(user), requestTimeout,
              signal: signal)
          .request('POST', '/$service/$method',
              data: jsonEncode(body),
              validateStatus: false,
              extraHeaders: {'Content-Type': 'application/json'});
      final data = decodeBody(response.body);
      if (response.statusCode >= 300) {
        _throwRpcError(data, statusCode: response.statusCode);
      }
      final result = data as Map<String, dynamic>? ?? {};
      logger?.info?.call(['Response:', jsonDecode(jsonEncode(result))]);
      return result;
    } catch (error, stack) {
      signal?.throwIfCanceled();
      Error.throwWithStackTrace(await resolveError(error), stack);
    }
  }

  Future<bool?> checkHealth() async {
    final response = await ContentTransport(
            restClient, baseUrl, headers, const Duration(seconds: 5))
        .request('GET', '/health', validateStatus: false);
    if (response.statusCode == 502) {
      final data = decodeBody(response.body);
      final message = data is Map
          ? data['message']?.toString() ?? response.body
          : response.body;
      final error = formatSandboxUnavailableError(message);
      if (error is SandboxNotRunningException) return false;
      throw error;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    return null;
  }

  Future<Object> resolveError(Object error) async {
    final rpc = error is EnvdRpcException ? error : null;
    final message = rpc?.message ?? error.toString();
    final terminated = [
      'terminated',
      'The socket connection was closed unexpectedly',
      'error reading a body from connection',
      'Network connection lost',
      'network error'
    ].any(message.contains);
    final transportFailure = error is http.ClientException &&
            error is! http.RequestAbortedException ||
        rpc?.code == 'unknown' && terminated;
    final ambiguous = rpc?.code == 'unavailable' &&
        !message.contains('was not found') &&
        !message.contains('port is not open');
    if (transportFailure || ambiguous) {
      try {
        if (await checkHealth() == false) {
          return SandboxNotRunningException(
              '$message: The sandbox was killed or reached its end of life while the request was in flight.',
              cause: error);
        }
      } catch (probeError) {
        if (probeError is SandboxUnreachableException) {
          return SandboxUnreachableException(probeError.message, cause: error);
        }
        return SandboxUnreachableException(
            "$message: The sandbox could not be reached and its health probe failed too ($probeError). It was not confirmed to be stopped — this is likely a network issue or envd inside the sandbox not being up yet; check the sandbox state with 'Sandbox.getInfo()'.",
            cause: error);
      }
    }
    if (rpc == null) return error;
    switch (rpc.code) {
      case 'unavailable':
        return formatSandboxUnavailableError(message);
      case 'canceled':
        return SandboxTimeoutException(
            "$message: This error is likely due to exceeding 'requestTimeoutMs'. You can pass the request timeout value as an option when making the request.");
      case 'deadline_exceeded':
        return SandboxTimeoutException(
            "$message: This error is likely due to exceeding 'timeoutMs' — the total time a long running request (like command execution or directory watch) can be active. It can be modified by passing 'timeoutMs' when making the request. Use '0' to disable the timeout.");
      case 'invalid_argument':
        return InvalidArgumentException(message);
      case 'unauthenticated':
        return AuthenticationException(message);
      case 'not_found':
        return NotFoundException(message);
      case 'resource_exhausted':
        return RateLimitException(
            '$message: Rate limit exceeded, please try again later.');
    }
    if (rpc.code == null) {
      try {
        throwApiError({'message': message}, statusCode: rpc.statusCode);
      } catch (mapped) {
        return mapped;
      }
    }
    return SandboxException('${rpc.code}: $message',
        cause: error, code: rpc.code, statusCode: rpc.statusCode);
  }

  Stream<Map<String, dynamic>> stream(
      String service, String method, Map<String, dynamic> body,
      {String? user, Duration? timeout}) {
    final abort = Completer<void>();
    StreamSubscription<Map<String, dynamic>>? subscription;
    var canceled = false;
    void Function()? removeCancellation;
    late final StreamController<Map<String, dynamic>> controller;
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    Future<void> start() async {
      try {
        signal?.throwIfCanceled();
        removeCancellation = signal?.listen(() {
          if (canceled) return;
          canceled = true;
          stop();
          controller.addError(signal!.reason);
          unawaited(subscription?.cancel());
          unawaited(controller.close());
        });
        final request = http.AbortableRequest('POST', uri('/$service/$method'),
            abortTrigger: abort.future);
        request.maxRedirects = fetchRedirectLimit;
        request.headers.addAll({
          ...requestHeaders(user),
          'Content-Type': 'application/connect+json',
          'Keepalive-Ping-Interval': '50',
          if (timeout != null && timeout > Duration.zero)
            'Connect-Timeout-Ms': '${timeout.inMilliseconds}',
        });
        request.bodyBytes = envelope(body);
        logger?.info?.call(['Request: POST ${request.url}']);
        final pending = client.send(request);
        final response = requestTimeout == Duration.zero
            ? await pending
            : await pending.timeout(requestTimeout);
        if (canceled) {
          await response.stream.listen((_) {}).cancel();
          return;
        }
        if (response.statusCode >= 300) {
          final body = response.stream.bytesToString();
          _throwRpcError(
              decodeBody(requestTimeout == Duration.zero
                  ? await body
                  : await body.timeout(requestTimeout)),
              statusCode: response.statusCode);
        }
        subscription = decodeEnvelopes(response.stream, rawErrors: true)
            .map((message) {
          logger?.debug
              ?.call(['Response stream:', jsonDecode(jsonEncode(message))]);
          return message;
        }).listen(controller.add,
                onError: (Object error, StackTrace stack) async {
          subscription?.pause();
          final mapped = await resolveError(error);
          if (!canceled) controller.addError(mapped, stack);
          subscription?.resume();
        }, onDone: () {
          removeCancellation?.call();
          stop();
          unawaited(controller.close());
        });
        if (controller.isPaused) subscription!.pause();
      } catch (error, stack) {
        removeCancellation?.call();
        stop();
        if (canceled) return;
        final mapped = await resolveError(error);
        if (!canceled) {
          controller.addError(mapped, stack);
          unawaited(controller.close());
        }
      }
    }

    controller = StreamController<Map<String, dynamic>>(
      onListen: () => unawaited(start()),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        removeCancellation?.call();
        canceled = true;
        stop();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
