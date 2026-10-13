// ignore_for_file: non_constant_identifier_names
// Preserve official openapi-fetch method spelling at the low-level API boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'connection.dart';
import 'js_number.dart';
import 'metadata.dart';

/// Override OpenAPI query serialization. A single leading `?` is accepted.
typedef ApiQuerySerializer = String Function(Map<String, Object?> parameters);

/// Return text, bytes, or null (omit the body). Headers are a per-call snapshot.
typedef ApiBodySerializer = Object? Function(
    Object body, Map<String, String> headers);

/// Override path substitution before URL parsing and query serialization.
typedef ApiPathSerializer = String Function(
    String url, Map<String, Object?> parameters);

/// Low-level JSON response. HTTP errors are returned in [error], not thrown.
/// Transport, cancellation and JSON parsing failures still throw.
class ApiResponse {
  final Object? data;
  final Object? error;
  final http.Response response;
  const ApiResponse({this.data, this.error, required this.response});
}

/// Context shared by the hooks of one logical low-level request.
class ApiMiddlewareContext {
  final String id;
  final String schemaPath;
  final http.Request request;
  final Map<String, Object?> pathParameters;
  final Map<String, Object?> query;
  final RequestOptions? options;
  final String parseAs;
  final http.Response? response;
  final Object? error;
  const ApiMiddlewareContext(
      {required this.id,
      required this.schemaPath,
      required this.request,
      required this.pathParameters,
      required this.query,
      this.options,
      required this.parseAs,
      this.response,
      this.error});
}

/// Return a Request to replace, a Response to short-circuit, or null to continue.
class ApiMiddleware {
  final FutureOr<Object?> Function(ApiMiddlewareContext)? onRequest;
  final FutureOr<http.Response?> Function(ApiMiddlewareContext)? onResponse;
  final FutureOr<Object?> Function(ApiMiddlewareContext)? onError;
  const ApiMiddleware({this.onRequest, this.onResponse, this.onError});
}

/// Dart expression of the SDK's raw management client.
/// Generated schemas and paths are available through the public library.
class ApiEndpointClient {
  final ApiClient _client;
  ApiEndpointClient(this._client);
  final List<ApiMiddleware> _middlewares = [];
  static int _nextId = 0;

  void use(Iterable<ApiMiddleware> middleware) {
    for (final item in middleware) {
      if (item.onRequest == null &&
          item.onResponse == null &&
          item.onError == null) {
        throw ArgumentError('Middleware must provide at least one hook');
      }
      _middlewares.add(item);
    }
  }

  void eject(Iterable<ApiMiddleware> middleware) {
    for (final item in middleware) {
      final index = _middlewares.indexWhere((value) => identical(value, item));
      if (index >= 0) _middlewares.removeAt(index);
    }
  }

  Future<ApiResponse> request(String method, String path,
      {Map<String, Object?> pathParameters = const {},
      Map<String, Object?> query = const {},
      Object? body,
      RequestOptions? options,
      String parseAs = 'json',
      ApiQuerySerializer? querySerializer,
      ApiBodySerializer? bodySerializer,
      ApiPathSerializer? pathSerializer,
      List<ApiMiddleware> middleware = const []}) async {
    method = method.toUpperCase();
    final chain = [..._middlewares, ...middleware];
    final id = (++_nextId).toString();
    Future<http.Response> exchange(http.Request original,
        Future<http.Response> Function(http.Request) send) async {
      var request = original;
      ApiMiddlewareContext context({http.Response? response, Object? error}) =>
          ApiMiddlewareContext(
              id: id,
              schemaPath: path,
              request: request,
              pathParameters: pathParameters,
              query: query,
              options: options,
              parseAs: parseAs,
              response: response,
              error: error);
      for (final item in chain) {
        final result = await item.onRequest?.call(context());
        if (result is http.Response) {
          method = request.method;
          return result;
        }
        if (result is http.Request) {
          request = result;
        } else if (result != null) {
          throw ArgumentError(
              'onRequest must return Request, Response, or null');
        }
      }
      method = request.method;
      http.Response? response;
      try {
        response = await send(request);
      } catch (error, stack) {
        Object failure = error;
        var failureStack = stack;
        for (final item in chain.reversed) {
          final result = await item.onError?.call(context(error: failure));
          if (result is http.Response) {
            response = result;
            break;
          }
          if (result is Error || result is Exception) {
            failure = result!;
            failureStack = StackTrace.current;
          } else if (result != null) {
            throw ArgumentError(
                'onError must return Response, Error, Exception, or null');
          }
        }
        if (response == null) Error.throwWithStackTrace(failure, failureStack);
      }
      for (final item in chain.reversed) {
        response = await item.onResponse?.call(context(response: response)) ??
            response;
      }
      return response!;
    }

    final bodyHeaders = <String, String>{
      for (final entry in {
        ...defaultHeaders,
        if (options?.apiKey ?? _client.config.apiKey case final key?)
          'X-API-Key': key,
        ..._client.requestHeaders(options),
      }.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final form =
        bodyHeaders['content-type'] == 'application/x-www-form-urlencoded';
    final customBody = body != null && (bodySerializer != null || form);
    Object? serialized;
    if (customBody) {
      serialized = bodySerializer != null
          ? bodySerializer(body, bodyHeaders)
          : _formBody(body);
      if (serialized != null &&
          serialized is! String &&
          serialized is! List<int>) {
        throw ArgumentError(
            'bodySerializer must return String, List<int>, or null');
      }
    } else if (body != null) {
      serialized = jsonEncode(body);
    }
    final response = await _client.requestResponse(method, path,
        body: body,
        exchange: chain.isEmpty ? null : exchange, pathSerializer: (url) {
      final resolved = (pathSerializer ?? _path)(url, pathParameters);
      var search =
          querySerializer == null ? _query(query) : querySerializer(query);
      if (search.startsWith('?')) search = search.substring(1);
      return search.isEmpty ? resolved : '$resolved?$search';
    },
        serializeBody: false,
        serializedBody: serialized is String
            ? utf8.encode(serialized)
            : serialized as List<int>?,
        rawQuery: '',
        options: options,
        validateStatus: false,
        addJsonContentType:
            body != null && (!customBody || serialized != null));
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    final length = response.headers['content-length'];
    final empty = method == 'HEAD' ||
        response.statusCode == 204 ||
        (length == '0' &&
            !(response.headers['transfer-encoding']?.contains('chunked') ??
                false));
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? parsed;
    if (!empty) {
      if (!ok) {
        try {
          parsed = jsonDecode(text);
        } on FormatException {
          parsed = text;
        }
      } else {
        switch (parseAs) {
          case 'json':
            parsed = text.isEmpty && (length == null || length.isEmpty)
                ? null
                : jsonDecode(text);
          case 'text':
            parsed = text;
          case 'arrayBuffer':
            parsed = Uint8List.fromList(response.bodyBytes);
          default:
            throw UnsupportedError(
                'Response parseAs $parseAs is not implemented');
        }
      }
    }
    return ok
        ? ApiResponse(data: parsed, response: response)
        : ApiResponse(error: parsed, response: response);
  }

  Future<ApiResponse> GET(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('GET', path,
          pathParameters: pathParameters,
          query: query,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> HEAD(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('HEAD', path,
          pathParameters: pathParameters,
          query: query,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> POST(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('POST', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> PUT(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('PUT', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> PATCH(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('PATCH', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> DELETE(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('DELETE', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> OPTIONS(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('OPTIONS', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
  Future<ApiResponse> TRACE(String path,
          {Map<String, Object?> pathParameters = const {},
          Map<String, Object?> query = const {},
          Object? body,
          RequestOptions? options,
          String parseAs = 'json',
          ApiQuerySerializer? querySerializer,
          ApiBodySerializer? bodySerializer,
          ApiPathSerializer? pathSerializer,
          List<ApiMiddleware> middleware = const []}) =>
      request('TRACE', path,
          pathParameters: pathParameters,
          query: query,
          body: body,
          options: options,
          parseAs: parseAs,
          querySerializer: querySerializer,
          bodySerializer: bodySerializer,
          pathSerializer: pathSerializer,
          middleware: middleware);
}

String _string(Object? value) {
  if (value == null) return 'null';
  if (value is num) return jsNumberString(value);
  if (value is Map) return '[object Object]';
  if (value is List) {
    return value.map((item) => item == null ? '' : _string(item)).join(',');
  }
  return value.toString();
}

Iterable<String> _keys(Map<String, Object?> value) {
  final indices = <int>[];
  final other = <String>[];
  for (final key in value.keys) {
    final index = int.tryParse(key);
    if (index != null && index >= 0 && index < 4294967295 && '$index' == key) {
      indices.add(index);
    } else {
      other.add(key);
    }
  }
  indices.sort();
  return [...indices.map((index) => '$index'), ...other];
}

String _primitive(String name, Object? value) {
  if (value == null) return '';
  if (value is Map || value is List) {
    throw StateError(
        'Deeply-nested arrays/objects aren’t supported. Provide your own `querySerializer()` to handle these.');
  }
  return '$name=${Uri.encodeComponent(_string(value))}';
}

String _query(Map<String, Object?> query) {
  final parts = <String>[];
  for (final name in _keys(query)) {
    final value = query[name];
    if (value == null) continue;
    if (value is List) {
      if (value.isEmpty) continue;
      parts.add(
          '$name=${value.map((item) => Uri.encodeComponent(_string(item))).join(',')}');
    } else if (value is Map) {
      final object = Map<String, Object?>.from(value);
      parts.add(_keys(object)
          .map((key) => _primitive('$name[$key]', object[key]))
          .join('&'));
    } else {
      parts.add(_primitive(name, value));
    }
  }
  // WHATWG special-URL query parsing also escapes apostrophes.
  return parts.join('&').replaceAll("'", '%27');
}

String _path(String path, Map<String, Object?> parameters) {
  var result = path;
  for (final match in RegExp(r'\{[^{}]+\}').allMatches(path)) {
    final token = match.group(0)!;
    var name = token.substring(1, token.length - 1);
    final explode = name.endsWith('*');
    if (explode) name = name.substring(0, name.length - 1);
    var style = 'simple';
    if (name.startsWith('.')) {
      style = 'label';
      name = name.substring(1);
    } else if (name.startsWith(';')) {
      style = 'matrix';
      name = name.substring(1);
    }
    final value = parameters[name];
    if (value == null) continue;
    String encoded(Object? item) => Uri.encodeComponent(_string(item));
    final joiner = style == 'label'
        ? '.'
        : style == 'matrix'
            ? ';'
            : ',';
    String serialized;
    if (value is List) {
      if (explode) {
        final parts = value.map((item) =>
            style == 'matrix' ? _primitive(name, item) : encoded(item));
        serialized = (style == 'simple' ? '' : joiner) + parts.join(joiner);
      } else {
        final parts = value.map(encoded).join(',');
        serialized = style == 'matrix'
            ? ';$name=$parts'
            : style == 'label'
                ? '.$parts'
                : parts;
      }
    } else if (value is Map) {
      final object = Map<String, Object?>.from(value);
      if (explode) {
        serialized = (style == 'simple' ? '' : joiner) +
            _keys(object)
                .map((key) => _primitive(key, object[key]))
                .join(joiner);
      } else {
        final parts = _keys(object)
            .expand((key) => [key, encoded(object[key])])
            .join(',');
        serialized = style == 'matrix'
            ? ';$name=$parts'
            : style == 'label'
                ? '.$parts'
                : parts;
      }
    } else {
      serialized = style == 'matrix'
          ? ';${_primitive(name, value)}'
          : style == 'label'
              ? '.${encoded(value)}'
              : encoded(value);
    }
    result = result.replaceFirst(token, serialized);
  }
  return result;
}

String _formBody(Object body) {
  String encode(String value) => Uri.encodeQueryComponent(value)
      .replaceAll('~', '%7E')
      .replaceAll('%2A', '*');
  final pairs = <List<String>>[];
  if (body is Map<String, Object?>) {
    for (final key in _keys(body)) {
      pairs.add([key, _string(body[key])]);
    }
  } else if (body is String) {
    final query = body.startsWith('?') ? body.substring(1) : body;
    for (final field in query.split('&')) {
      if (field.isEmpty) continue;
      final equals = field.indexOf('=');
      pairs.add([
        _decodeForm(equals < 0 ? field : field.substring(0, equals)),
        _decodeForm(equals < 0 ? '' : field.substring(equals + 1))
      ]);
    }
  } else if (body is List) {
    for (final pair in body) {
      if (pair is! List || pair.length != 2) {
        throw ArgumentError(
            'Form sequence entries must contain exactly two values');
      }
      pairs.add([_string(pair[0]), _string(pair[1])]);
    }
  } else {
    throw ArgumentError('Form bodies must be a Map, String, or list of pairs');
  }
  return pairs.map((pair) => '${encode(pair[0])}=${encode(pair[1])}').join('&');
}

String _decodeForm(String value) {
  final input = utf8.encode(value.replaceAll('+', ' '));
  final bytes = <int>[];
  for (var i = 0; i < input.length; i++) {
    if (input[i] == 37 && i + 2 < input.length) {
      final octet = int.tryParse(
          String.fromCharCodes(input.sublist(i + 1, i + 3)),
          radix: 16);
      if (octet != null &&
          RegExp(r'^[0-9a-fA-F]{2}$')
              .hasMatch(String.fromCharCodes(input.sublist(i + 1, i + 3)))) {
        bytes.add(octet);
        i += 2;
        continue;
      }
    }
    bytes.add(input[i]);
  }
  // A sentinel prevents Dart's UTF-8 decoder from removing a field's BOM.
  return utf8.decode([0, ...bytes], allowMalformed: true).substring(1);
}
