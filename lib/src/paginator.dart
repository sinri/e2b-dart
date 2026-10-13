import 'dart:convert';
import 'api.dart';
import 'connection.dart';
import 'js_number.dart';

class Page<T> {
  final List<T> items;
  final String? nextToken;
  bool get hasNext => nextToken != null && nextToken!.isNotEmpty;
  Page(Iterable<T> items, this.nextToken) : items = List.unmodifiable(items);
}

/// Lazy paginator. Failed requests preserve the cursor; successful responses
/// advance it before converting individual items, as in the official SDK.
class Paginator<T> {
  final ApiClient? _client;
  final ApiClient Function()? clientFactory;
  final String _path;
  final T Function(Map<String, dynamic>) _convert;
  final Map<String, String> _query;
  final Map<String, String> Function()? queryBuilder;
  final RequestOptions? _options;
  final Object Function(int status, Object? body, String? reason)?
      responseError;
  bool _hasNext = true;
  String? _nextToken;
  bool get hasNext => _hasNext;
  String? get nextToken => _nextToken;
  Paginator(this._client, this._path, this._convert,
      {num? limit,
      String? nextToken,
      Map<String, String> query = const {},
      this.responseError,
      this.queryBuilder,
      this.clientFactory,
      RequestOptions? options})
      : _nextToken = nextToken,
        _query = {...query, if (limit != null) 'limit': jsNumberString(limit)},
        _options = options;
  Future<List<T>> nextItems({RequestOptions? options}) async {
    if (!_hasNext) throw StateError('No more items to fetch');
    final client = clientFactory?.call() ?? _client!;
    try {
      final response = await client.requestResponse('GET', _path,
          query: {
            ...?queryBuilder?.call(),
            ..._query,
            if (_nextToken != null) 'nextToken': _nextToken!
          },
          responseError: responseError,
          options: RequestOptions.merge(_options, options));
      final data = response.body.isEmpty ? null : jsonDecode(response.body);
      final token = response.headers['x-next-token'];
      _nextToken = token == null || token.isEmpty ? null : token;
      _hasNext = _nextToken != null;
      return (data as List? ?? [])
          .map((e) => _convert(e as Map<String, dynamic>))
          .toList();
    } finally {
      if (clientFactory != null) client.close();
    }
  }

  Stream<T> get items async* {
    while (hasNext) {
      yield* Stream.fromIterable(await nextItems());
    }
  }
}
