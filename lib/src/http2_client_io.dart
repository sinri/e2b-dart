import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'vendor/http2/transport.dart';
import 'http2_connection_pool_io.dart';
import 'http_request_limiter.dart';
import 'http_content_decoder_io.dart';
import 'http_dispatch_config.dart';
import 'native_http_client_io.dart';
import 'proxy_config.dart' show proxyRequestAbortKey;

/// Native direct HTTP/2 transport with HTTP/1.1 ALPN fallback.
/// Compression and lifecycle parity limitations are tracked in docs/PARITY.md.
class Http2Client extends http.BaseClient {
  final Http2ConnectionPool _pool;
  final bool allowH2;
  final HttpRequestLimiter _limiter;
  late final http.Client _fallback;
  bool _closed = false;

  Http2Client(
      {SecurityContext? context,
      num? maxInFlight,
      num connectionLimit = 100,
      String? proxy,
      this.allowH2 = true})
      : _limiter = HttpRequestLimiter(maxInFlight ?? apiInflightLimit),
        _pool = Http2ConnectionPool(
            context: context, connectionLimit: connectionLimit, proxy: proxy) {
    _fallback = IOClient(nativeHttpClient(
        context: context,
        connectionLimit: connectionLimit,
        proxy: proxy,
        takePreconnected: _pool.takeHttp1Socket)
      ..autoUncompress = false);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _limiter.run(request, () => _sendRedirects(request));

  Future<http.StreamedResponse> _sendRedirects(http.BaseRequest request) async {
    var current = request;
    var redirects = 0;
    while (true) {
      final replay =
          current is http.Request ? List<int>.of(current.bodyBytes) : null;
      final response = await _sendOnce(current);
      final location = response.headers['location'];
      if (!request.followRedirects ||
          location == null ||
          !const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      await response.stream.listen(null).cancel();
      if (redirects++ >= request.maxRedirects) {
        throw http.ClientException('Redirect limit exceeded', current.url);
      }
      final target = current.url.resolve(location);
      if (target.scheme != 'https' && target.scheme != 'http') {
        throw http.ClientException(
            'Redirect URL must use HTTP or HTTPS', target);
      }
      if (target.userInfo.isNotEmpty) {
        throw http.ClientException('Redirect URL contains credentials', target);
      }
      final dropBody =
          ((response.statusCode == 301 || response.statusCode == 302) &&
                  current.method == 'POST') ||
              (response.statusCode == 303 &&
                  current.method != 'GET' &&
                  current.method != 'HEAD');
      if (response.statusCode != 303 &&
          replay == null &&
          (current is http.StreamedRequest || current.contentLength != 0)) {
        throw http.ClientException(
            'Cannot replay a streaming request body after redirect',
            current.url);
      }
      final next = http.AbortableRequest(
          dropBody ? 'GET' : current.method, target,
          abortTrigger: current is http.Abortable ? current.abortTrigger : null)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..headers.addAll(current.headers);
      if (target.origin != current.url.origin) {
        next.headers.removeWhere((key, _) => const {
              'authorization',
              'proxy-authorization',
              'cookie'
            }.contains(key.toLowerCase()));
      }
      next.headers.removeWhere((key, _) =>
          key.toLowerCase() == 'host' ||
          (dropBody &&
              const {
                'content-length',
                'content-type',
                'content-encoding',
                'content-language',
                'content-location'
              }.contains(key.toLowerCase())));
      if (!dropBody && replay != null) next.bodyBytes = replay;
      current = next;
    }
  }

  Future<http.StreamedResponse> _sendOnce(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client is closed', request.url);
    var aborted = false;
    ClientTransportStream? stream;
    final abort = Completer<Never>();
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) {
        aborted = true;
        stream?.terminate();
        _pool.notifyCapacity();
        if (!abort.isCompleted) {
          abort.completeError(http.RequestAbortedException(request.url));
        }
      });
    }
    final bodyStream = request.finalize();
    final headers = <Header>[
      Header.ascii(':method', request.method),
      Header.ascii(':scheme', request.url.scheme),
      Header.ascii(':authority', request.url.authority),
      Header.ascii(':path',
          '${request.url.path.isEmpty ? '/' : request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}'),
      for (final entry in request.headers.entries)
        if (!const {
          'connection',
          'host',
          'transfer-encoding',
          'upgrade',
          'keep-alive'
        }.contains(entry.key.toLowerCase()))
          Header(
              utf8.encode(entry.key.toLowerCase()), utf8.encode(entry.value)),
      if (request.contentLength != null &&
          !request.headers.keys
              .any((key) => key.toLowerCase() == 'content-length'))
        Header.ascii('content-length', '${request.contentLength}'),
    ];
    final allocated = await Future.any([
      allowH2
          ? _pool.makeRequest(request.url, headers,
              abortTrigger:
                  request is http.Abortable ? request.abortTrigger : null)
          : Future<ClientTransportStream?>.value(null),
      abort.future,
    ]);
    if (_closed) throw http.ClientException('Client is closed', request.url);
    if (aborted) {
      allocated?.terminate();
      _pool.notifyCapacity();
      throw http.RequestAbortedException(request.url);
    }
    if (allocated == null) {
      final response = await Future.any([
        runZoned(
            () => _fallback.send(_UnredirectedRequest(request, bodyStream)),
            zoneValues: {
              proxyRequestAbortKey:
                  request is http.Abortable ? request.abortTrigger : null
            }),
        abort.future,
      ]);
      return http.StreamedResponse(
          decodeHttpContent(response.stream, response.headers, request.method,
              response.statusCode),
          response.statusCode,
          request: request,
          headers: response.headers,
          contentLength: response.contentLength,
          reasonPhrase: response.reasonPhrase,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection);
    }
    final transport = allocated;
    stream = transport;
    final incoming = StreamIterator(transport.incomingMessages);
    final uploadError = Completer<Never>();
    final body = StreamIterator(bodyStream);
    Future<void> upload() async {
      try {
        while (!aborted && await body.moveNext()) {
          transport.sendData(body.current);
        }
        if (!aborted) await transport.outgoingMessages.close();
      } catch (error, stack) {
        transport.terminate();
        _pool.notifyCapacity();
        if (!uploadError.isCompleted) uploadError.completeError(error, stack);
      } finally {
        await body.cancel();
      }
    }

    // Keep errors observed even after response headers have arrived.
    unawaited(uploadError.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(upload());
    try {
      while (await Future.any<bool>([
        incoming.moveNext(),
        abort.future,
        uploadError.future,
      ])) {
        final message = incoming.current;
        if (message is! HeadersStreamMessage) {
          throw http.ClientException(
              'HTTP/2 response data before headers', request.url);
        }
        final responseHeaders = <String, String>{};
        int? status;
        for (final header in message.headers) {
          final name = utf8.decode(header.name);
          final value = utf8.decode(header.value);
          if (name == ':status') {
            status = int.tryParse(value);
          } else if (!name.startsWith(':')) {
            responseHeaders.update(name, (previous) => '$previous,$value',
                ifAbsent: () => value);
          }
        }
        if (status != null && status >= 100 && status < 200) continue;
        if (status == null) {
          throw http.ClientException('Missing HTTP/2 status', request.url);
        }
        Stream<List<int>> responseBody() async* {
          try {
            while (!aborted && await incoming.moveNext()) {
              final next = incoming.current;
              if (next is DataStreamMessage) yield next.bytes;
            }
            if (aborted) throw http.RequestAbortedException(request.url);
          } catch (_) {
            if (aborted) throw http.RequestAbortedException(request.url);
            rethrow;
          } finally {
            transport.terminate();
            _pool.notifyCapacity();
            await incoming.cancel();
            await body.cancel();
          }
        }

        // Cancellation must release the transport even if no DATA was read.
        late StreamController<List<int>> guardedBody;
        StreamSubscription<List<int>>? responseSubscription;
        guardedBody = StreamController<List<int>>(
          onListen: () {
            responseSubscription = responseBody().listen(guardedBody.add,
                onError: guardedBody.addError, onDone: guardedBody.close);
          },
          onPause: () => responseSubscription?.pause(),
          onResume: () => responseSubscription?.resume(),
          onCancel: () async {
            transport.terminate();
            _pool.notifyCapacity();
            await incoming.cancel();
            await body.cancel();
            await responseSubscription?.cancel();
          },
        );
        Stream<List<int>> decodedBody = guardedBody.stream;
        decodedBody = decodeHttpContent(
            decodedBody, responseHeaders, request.method, status);
        // Fetch exposes the original wire headers even after decompression.
        return http.StreamedResponse(decodedBody, status,
            request: request,
            headers: responseHeaders,
            contentLength:
                int.tryParse(responseHeaders['content-length'] ?? ''),
            persistentConnection: true);
      }
      throw http.ClientException(
          'HTTP/2 connection closed before response', request.url);
    } catch (_) {
      transport.terminate();
      _pool.notifyCapacity();
      await incoming.cancel();
      await body.cancel();
      if (aborted) throw http.RequestAbortedException(request.url);
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _limiter.close();
    _fallback.close();
    unawaited(_pool.close());
  }
}

/// Delegate request data and cancellation without changing caller options.
/// Redirects are handled by the same Fetch loop for both native protocols.
class _UnredirectedRequest extends http.BaseRequest implements http.Abortable {
  final http.BaseRequest source;
  final http.ByteStream bodyStream;
  _UnredirectedRequest(this.source, this.bodyStream)
      : super(source.method, source.url) {
    headers.addAll(source.headers);
    contentLength = source.contentLength;
    persistentConnection = source.persistentConnection;
    maxRedirects = source.maxRedirects;
    followRedirects = false;
  }
  @override
  Future<void>? get abortTrigger =>
      source is http.Abortable ? (source as http.Abortable).abortTrigger : null;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return bodyStream;
  }
}
