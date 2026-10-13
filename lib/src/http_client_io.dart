import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'native_http_client_io.dart';
import 'http2_client_io.dart';
import 'http_request_limiter.dart';
import 'http_dispatch_config.dart';
import 'http_content_decoder_io.dart';

http.Client createHttpClient(String? proxy,
    {String httpVersion = '2', num? maxInFlight, num? connectionLimit}) {
  final limit = connectionLimit ?? connectionLimitFor(HttpDispatchScope.api);
  if (httpVersion == '2' || (proxy != null && proxy.isNotEmpty)) {
    return Http2Client(
        maxInFlight: maxInFlight,
        connectionLimit: limit,
        proxy: proxy,
        allowH2: httpVersion == '2');
  }
  return _LimitedIOClient(
      nativeHttpClient(proxy: proxy, connectionLimit: limit), maxInFlight);
}

/// Keep the native IOClient surface while sharing the fetch slot semantics.
class _LimitedIOClient extends IOClient {
  final HttpRequestLimiter _limiter;
  _LimitedIOClient(HttpClient inner, num? maxInFlight)
      : _limiter = HttpRequestLimiter(maxInFlight ?? apiInflightLimit),
        super(inner..autoUncompress = false);

  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) =>
      _limiter.run(request, () async {
        final response = await super.send(request);
        return _DecodedIOStreamedResponse(
            response,
            decodeHttpContent(response.stream, response.headers, request.method,
                response.statusCode));
      });

  @override
  void close() {
    _limiter.close();
    super.close();
  }
}

class _DecodedIOStreamedResponse extends IOStreamedResponse {
  final IOStreamedResponse source;
  _DecodedIOStreamedResponse(this.source, Stream<List<int>> body)
      : super(body, source.statusCode,
            contentLength: source.contentLength,
            request: source.request,
            headers: source.headers,
            isRedirect: source.isRedirect,
            persistentConnection: source.persistentConnection,
            reasonPhrase: source.reasonPhrase);
  @override
  Future<Socket> detachSocket() => source.detachSocket();
}
