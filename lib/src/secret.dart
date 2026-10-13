import 'api.dart';
import 'api_date.dart';
import 'dart:convert';
import 'resource_api_error.dart';
import 'connection.dart';
import 'errors.dart';
import 'network.dart';
import 'paginator.dart';

class SecretInfo {
  final String secretId;
  final String name;
  final int version;
  final Map<String, String> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  SecretInfo(Map<String, dynamic> data)
      : secretId = data['secretID'] as String,
        name = data['name'] as String,
        version = data['currentVersion'] as int,
        metadata = Map.unmodifiable(
            Map<String, String>.from(data['metadata'] as Map? ?? {})),
        createdAt = parseApiDate(data['createdAt'] as String),
        updatedAt = parseApiDate(data['updatedAt'] as String);
}

/// Project secrets. Values are write-only and excluded from result models.
class Secrets {
  final ApiClient _client;
  Secrets(this._client);
  Future<Object?> _request(String method, String path,
          {Map<String, dynamic>? body,
          RequestOptions? options,
          bool notFound = false}) =>
      _client.request(method, path,
          body: body,
          options: options,
          responseError: (status, body, reason) =>
              _secretError(status, body, reason, notFound: notFound));
  Map<String, dynamic> _requiredData(Object? data) {
    if (!jsApiTruthy(data)) {
      throw const E2BException('Response data is missing');
    }
    return data as Map<String, dynamic>;
  }

  Future<SecretInfo> create(String name, String value,
          {Map<String, String>? metadata, RequestOptions? options}) async =>
      SecretInfo(_requiredData(await _request('POST', '/secrets',
          body: {
            'name': name,
            'value': value,
            if (metadata != null) 'metadata': metadata
          },
          options: options)));
  Future<SecretInfo> update(String secret, String value,
      {Map<String, String>? metadata, RequestOptions? options}) async {
    try {
      return SecretInfo(_requiredData(await _request(
          'POST', '/secrets/${Uri.encodeComponent(secret)}',
          body: {'value': value, if (metadata != null) 'metadata': metadata},
          options: options,
          notFound: true)));
    } on NotFoundException catch (e) {
      throw SecretNotFoundException('Secret $secret not found',
          statusCode: e.statusCode, code: e.code);
    }
  }

  Future<SecretInfo> getInfo(String secret, {RequestOptions? options}) async {
    try {
      return SecretInfo(_requiredData(await _request(
          'GET', '/secrets/${Uri.encodeComponent(secret)}',
          options: options, notFound: true)));
    } on NotFoundException catch (e) {
      throw SecretNotFoundException('Secret $secret not found',
          statusCode: e.statusCode, code: e.code);
    }
  }

  Future<bool> exists(String secret, {RequestOptions? options}) async {
    try {
      await getInfo(secret, options: options);
      return true;
    } on SecretNotFoundException {
      return false;
    }
  }

  Future<bool> destroy(String secret, {RequestOptions? options}) async {
    try {
      await _request('DELETE', '/secrets/${Uri.encodeComponent(secret)}',
          options: options, notFound: true);
      return true;
    } on NotFoundException {
      return false;
    }
  }

  SecretPaginator list(
          {num? limit, String? nextToken, RequestOptions? options}) =>
      SecretPaginator(
          client: _client,
          limit: limit,
          nextToken: nextToken,
          options: options);
  static String fill(String name) {
    if (name.isEmpty ||
        name.runes.any(
            (r) => r == 123 || r == 125 || r <= 31 || (r >= 127 && r <= 159))) {
      throw InvalidArgumentException(
          "secret name ${jsonEncode(name)} is not usable: a secret name cannot be empty or contain '{', '}' or control characters, because it is interpolated into the '\${e2b.secrets.<name>}' placeholder the runtime resolves.");
    }
    return '\${e2b.secrets.$name}';
  }

  static IamToken iamToken(
          {required String audience, required String tokenType}) =>
      IamToken(audience: audience, tokenType: tokenType);
}

/// Cursor-based secret listing, with per-page connection overrides.
class SecretPaginator extends Paginator<SecretInfo> {
  SecretPaginator(
      {ApiClient? client,
      num? limit,
      String? nextToken,
      RequestOptions? options})
      : super(client, '/secrets', SecretInfo.new,
            limit: limit,
            nextToken: nextToken,
            options: options,
            responseError: _secretError,
            clientFactory: client == null
                ? () => ApiClient(deferApiKeyValidation: true)
                : null);
}

/// Environment-configured static resource API, matching the official SDK.
class Secret {
  static Future<T> _run<T>(
      Future<T> Function(Secrets resource) operation, ApiClient? client) async {
    final resolved = client ?? ApiClient(deferApiKeyValidation: true);
    try {
      return await operation(Secrets(resolved));
    } finally {
      if (client == null) resolved.close();
    }
  }

  static Future<SecretInfo> create(String name, String value,
          {Map<String, String>? metadata,
          RequestOptions? options,
          ApiClient? client}) =>
      _run(
          (resource) => resource.create(name, value,
              metadata: metadata, options: options),
          client);

  static Future<SecretInfo> update(String secret, String value,
          {Map<String, String>? metadata,
          RequestOptions? options,
          ApiClient? client}) =>
      _run(
          (resource) => resource.update(secret, value,
              metadata: metadata, options: options),
          client);

  static Future<SecretInfo> getInfo(String secret,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.getInfo(secret, options: options), client);

  static Future<bool> exists(String secret,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.exists(secret, options: options), client);

  static Future<bool> destroy(String secret,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.destroy(secret, options: options), client);

  static SecretPaginator list(
          {num? limit,
          String? nextToken,
          RequestOptions? options,
          ApiClient? client}) =>
      SecretPaginator(
          client: client, limit: limit, nextToken: nextToken, options: options);

  static String fill(String name) => Secrets.fill(name);
  static IamToken iamToken(
          {required String audience, required String tokenType}) =>
      Secrets.iamToken(audience: audience, tokenType: tokenType);
}

Object _secretError(int status, Object? body, String? reason,
        {bool notFound = false}) =>
    resourceApiError(status, body, reason,
        notFound: notFound,
        fallback: (message, status) =>
            SecretException(message, statusCode: status));
