import 'http_defaults.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'connection.dart';
import 'errors.dart';
import 'logs.dart';
import 'transport.dart' show decodeBody;

/// Shared raw-byte transport for volume and sandbox file content.
class ContentTransport {
  final http.Client client;
  final Uri baseUrl;
  final Map<String, String> headers;
  final Duration requestTimeout;
  final CancellationSignal? signal;
  final Logger? logger;
  final Object Function(int status, Object? body, String? reason)?
      responseError;
  final Future<Object> Function(Object error)? resolveError;
  ContentTransport(this.client, this.baseUrl, this.headers, this.requestTimeout,
      {this.signal, this.logger, this.responseError, this.resolveError});
  void _logResponse(int status, String? reason) {
    final log = status >= 400 ? logger?.error : logger?.info;
    log?.call(['Response:', status, reason ?? '']);
  }

  Never _throwResponseError(int status, Object? body, String? reason) {
    if (responseError != null) throw responseError!(status, body, reason);
    throwApiError(body, statusCode: status);
  }

  Uri uri(String path, Map<String, String> query) => query.isEmpty
      ? baseUrl.resolve(path)
      : baseUrl.resolve(path).replace(queryParameters: query);

  Future<http.Response> request(String method, String path,
      {Map<String, String> query = const {},
      Object? data,
      Map<String, String> extraHeaders = const {},
      bool streamed = false,
      bool validateStatus = true}) async {
    signal?.throwIfCanceled();
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    final remove = signal?.listen(stop);
    StreamSubscription<List<int>>? producer;
    Object? producerError;
    try {
      late final http.BaseRequest request;
      if (data is Stream<List<int>>) {
        final upload = http.AbortableStreamedRequest(method, uri(path, query),
            abortTrigger: abort.future);
        request = upload;
        producer = data.listen(upload.sink.add,
            onError: (Object error, StackTrace stack) {
              producerError = error;
              stop();
              unawaited(upload.sink.close());
            },
            onDone: () => unawaited(upload.sink.close()));
      } else {
        final buffered = http.AbortableRequest(method, uri(path, query),
            abortTrigger: abort.future);
        if (data is String) {
          buffered.bodyBytes = utf8.encode(data);
        } else if (data is List<int>) {
          buffered.bodyBytes = data;
        } else if (data != null) {
          throw const InvalidArgumentException(
              'File data must be text, bytes, or a byte stream');
        }
        request = buffered;
      }
      request.maxRedirects = fetchRedirectLimit;
      request.headers.addAll({...headers, ...extraHeaders});
      logger?.info?.call(['Request $method ${request.url}']);
      final pending = (() async {
        final response = await client.send(request);
        try {
          _logResponse(response.statusCode, response.reasonPhrase);
        } catch (_) {
          await response.stream.listen((_) {}).cancel();
          rethrow;
        }
        return http.Response.fromStream(response);
      })();
      final response = requestTimeout == Duration.zero || streamed
          ? await pending
          : await pending.timeout(requestTimeout);
      signal?.throwIfCanceled();
      if (producerError != null) throw producerError!;
      if (validateStatus && response.statusCode >= 300) {
        _throwResponseError(response.statusCode, decodeBody(response.body),
            response.reasonPhrase);
      }
      return response;
    } catch (error, stack) {
      signal?.throwIfCanceled();
      if (producerError != null) throw producerError!;
      Error.throwWithStackTrace(
          resolveError == null ? error : await resolveError!(error), stack);
    } finally {
      stop();
      remove?.call();
      await producer?.cancel();
    }
  }

  /// Read bytes with a handshake timeout and a separately reset idle timeout.
  /// Pausing the subscription pauses both the source and its idle timer.
  Stream<List<int>> readStream(String path,
      {Map<String, String> query = const {},
      Duration? idleTimeout,
      Map<String, String> extraHeaders = const {}}) {
    final abort = Completer<void>();
    StreamSubscription<List<int>>? source;
    Timer? timer;
    void Function()? remove;
    var finished = false;
    var consumerCanceled = false;
    late final StreamController<List<int>> output;
    void stop() {
      timer?.cancel();
      remove?.call();
      if (!abort.isCompleted) abort.complete();
    }

    Future<void> fail(Object error, [StackTrace? stack]) async {
      if (finished) return;
      finished = true;
      stop();
      await source?.cancel();
      final mapped = signal?.isCanceled == true
          ? signal!.reason
          : resolveError == null
              ? error
              : await resolveError!(error);
      if (!consumerCanceled) {
        output.addError(mapped, stack);
        unawaited(output.close());
      }
    }

    void idle() {
      timer?.cancel();
      final duration = idleTimeout ?? requestTimeout;
      if (duration > Duration.zero && !output.isPaused) {
        timer = Timer(duration,
            () => fail(TimeoutException('File stream idle timeout', duration)));
      }
    }

    Future<void> start() async {
      try {
        signal?.throwIfCanceled();
        remove = signal?.listen(() => fail(signal!.reason));
        final request = http.AbortableRequest('GET', uri(path, query),
            abortTrigger: abort.future)
          ..maxRedirects = fetchRedirectLimit
          ..headers.addAll({...headers, ...extraHeaders});
        logger?.info?.call(['Request GET ${request.url}']);
        final pending = client.send(request);
        final response = requestTimeout == Duration.zero
            ? await pending
            : await pending.timeout(requestTimeout);
        if (finished) {
          await response.stream.listen((_) {}).cancel();
          return;
        }
        try {
          _logResponse(response.statusCode, response.reasonPhrase);
        } catch (_) {
          await response.stream.listen((_) {}).cancel();
          rethrow;
        }
        if (response.statusCode >= 300) {
          final body = response.stream.bytesToString();
          _throwResponseError(
              response.statusCode,
              decodeBody(requestTimeout == Duration.zero
                  ? await body
                  : await body.timeout(requestTimeout)),
              response.reasonPhrase);
        }
        source = response.stream.listen(
            (bytes) {
              if (!finished) {
                idle();
                output.add(bytes);
              }
            },
            onError: fail,
            onDone: () {
              if (!finished) {
                finished = true;
                stop();
                unawaited(output.close());
              }
            });
        if (output.isPaused) source!.pause();
        idle();
      } catch (error, stack) {
        fail(error, stack);
      }
    }

    output = StreamController<List<int>>(
      onListen: () => unawaited(start()),
      onPause: () {
        timer?.cancel();
        source?.pause();
      },
      onResume: () {
        source?.resume();
        idle();
      },
      onCancel: () async {
        consumerCanceled = true;
        finished = true;
        stop();
        await source?.cancel();
      },
    );
    return output.stream;
  }
}
