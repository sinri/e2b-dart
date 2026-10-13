import 'dart:convert';
import 'dart:typed_data';
import 'api.dart';
import 'api_date.dart';
import 'resource_api_error.dart';
import 'connection.dart';
import 'content_transport.dart';
import 'errors.dart';
import 'metadata.dart';
import 'transport.dart' show decodeBody;
import 'upload_body_web.dart' if (dart.library.io) 'upload_body_io.dart';

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
Object _volumeError(int status, Object? body, String? reason,
        {bool notFound = false}) =>
    resourceApiError(status, body, reason,
        notFound: notFound,
        fallback: (message, status) =>
            VolumeException(message, statusCode: status));

Map<String, dynamic> _requiredVolumeData(Object? data) {
  if (!jsApiTruthy(data)) {
    throw const E2BException('Response data is missing');
  }
  return data as Map<String, dynamic>;
}

/// String-valued file type, including future values returned by the server.
class VolumeFileType {
  static const unknown = VolumeFileType('unknown');
  static const file = VolumeFileType('file');
  static const directory = VolumeFileType('directory');
  static const symlink = VolumeFileType('symlink');
  static const values = [unknown, file, directory, symlink];
  final String value;
  const VolumeFileType(this.value);
  factory VolumeFileType.fromValue(String value) =>
      values.firstWhere((type) => type.value == value,
          orElse: () => VolumeFileType(value));
  String get name => value;
  String toJson() => value;
  @override
  bool operator ==(Object other) =>
      other is VolumeFileType && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

class VolumeInfo {
  final String volumeId;
  final String name;
  VolumeInfo(Map<String, dynamic> data)
      : volumeId = data['volumeID'] as String,
        name = data['name'] as String;
}

class VolumeAndToken extends VolumeInfo {
  final String token;
  final String? domain;
  VolumeAndToken(super.data)
      : token = data['token'] as String,
        domain = data['domain'] == '' ? null : data['domain'] as String?;
}

class VolumeEntryStat {
  final Map<String, dynamic> raw;
  VolumeEntryStat(Map<String, dynamic> data) : raw = Map.unmodifiable(data);
  String get name => raw['name'] as String;
  String get path => raw['path'] as String;
  VolumeFileType get type => VolumeFileType.fromValue(raw['type'] as String);
  int get size => raw['size'] as int;
  int get mode => raw['mode'] as int;
  int get uid => raw['uid'] as int;
  int get gid => raw['gid'] as int;
  DateTime get atime => parseApiDate(raw['atime'] as String);
  DateTime get mtime => parseApiDate(raw['mtime'] as String);
  DateTime get ctime => parseApiDate(raw['ctime'] as String);
  String? get target => raw['target'] as String?;
}

class VolumeRequestOptions extends RequestOptions {
  final String? token;
  VolumeRequestOptions(
      {this.token,
      super.domain,
      super.debug,
      super.apiUrl,
      super.headers,
      super.proxy,
      super.httpVersion,
      super.logger,
      super.requestTimeout,
      super.signal});
}

/// Volume management endpoints authenticate with the project's API key.
class Volumes {
  final ApiClient _client;
  Volumes(this._client);
  Future<Object?> _request(String method, String path,
          {Map<String, dynamic>? body,
          RequestOptions? options,
          bool notFound = false}) =>
      _client.request(method, path,
          body: body,
          options: options,
          responseError: (status, body, reason) =>
              _volumeError(status, body, reason, notFound: notFound));
  Future<Volume> create(String name, {RequestOptions? options}) async => Volume(
      _client,
      VolumeAndToken(_requiredVolumeData(await _request('POST', '/volumes',
          body: {'name': name}, options: options))),
      domain: options?.domain,
      debug: options?.debug,
      proxy: options?.proxy,
      httpVersion: options?.httpVersion);
  Future<Volume> connect(String volumeId, {RequestOptions? options}) async =>
      Volume(_client, await getInfo(volumeId, options: options),
          domain: options?.domain,
          debug: options?.debug,
          proxy: options?.proxy,
          httpVersion: options?.httpVersion);
  Future<VolumeAndToken> getInfo(String volumeId,
      {RequestOptions? options}) async {
    try {
      return VolumeAndToken(await _request(
          'GET', '/volumes/${Uri.encodeComponent(volumeId)}',
          options: options, notFound: true) as Map<String, dynamic>);
    } on NotFoundException catch (e) {
      throw VolumeNotFoundException('Volume $volumeId not found',
          statusCode: e.statusCode, code: e.code);
    }
  }

  Future<List<VolumeInfo>> list({RequestOptions? options}) async =>
      ((await _request('GET', '/volumes', options: options) as List?) ??
              const [])
          .map((e) => VolumeInfo(e as Map<String, dynamic>))
          .toList();
  Future<bool> destroy(String volumeId, {RequestOptions? options}) async {
    try {
      await _request('DELETE', '/volumes/${Uri.encodeComponent(volumeId)}',
          options: options, notFound: true);
      return true;
    } on NotFoundException {
      return false;
    }
  }
}

/// Independently persisted storage. Content requests use a volume-scoped token.
class Volume {
  ApiClient? _ownedClient;

  /// Release a client created by static create/connect; does not delete storage.
  void close() {
    _ownedClient?.close();
    _ownedClient = null;
  }

  static Future<T> _run<T>(
      Future<T> Function(Volumes resource) action, ApiClient? client) async {
    final resolved = client ?? ApiClient(deferApiKeyValidation: true);
    try {
      return await action(Volumes(resolved));
    } finally {
      if (client == null) resolved.close();
    }
  }

  static Future<Volume> _open(String value, bool create,
      RequestOptions? options, ApiClient? client) async {
    final resolved = client ?? ApiClient(deferApiKeyValidation: true);
    try {
      final resource = Volumes(resolved);
      final volume = create
          ? await resource.create(value, options: options)
          : await resource.connect(value, options: options);
      if (client == null) volume._ownedClient = resolved;
      return volume;
    } catch (_) {
      if (client == null) resolved.close();
      rethrow;
    }
  }

  static Future<Volume> create(String name,
          {RequestOptions? options, ApiClient? client}) =>
      _open(name, true, options, client);
  static Future<Volume> connect(String volumeId,
          {RequestOptions? options, ApiClient? client}) =>
      _open(volumeId, false, options, client);
  static Future<VolumeAndToken> getInfo(String volumeId,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.getInfo(volumeId, options: options), client);
  static Future<List<VolumeInfo>> list(
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.list(options: options), client);
  static Future<bool> destroy(String volumeId,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.destroy(volumeId, options: options), client);

  final ApiClient _client;
  final String volumeId;
  final String name;
  final String token;
  final String domain;
  final String? proxy;
  final bool debug;
  final HttpVersion httpVersion;
  Volume(ApiClient client, VolumeAndToken info,
      {String? domain, bool? debug, String? proxy, HttpVersion? httpVersion})
      : _client = client,
        volumeId = info.volumeId,
        name = info.name,
        token = info.token,
        domain = _nonEmpty(info.domain) ?? _nonEmpty(domain) ?? client.domain,
        debug = debug ?? client.config.debug,
        proxy = proxy ?? client.config.proxy,
        httpVersion =
            resolveHttpVersion(httpVersion ?? client.config.httpVersion);
  String _path(String suffix) =>
      '/volumecontent/${Uri.encodeComponent(volumeId)}/$suffix';
  ContentTransport _transport(VolumeRequestOptions? options,
      {bool file = false}) {
    final domain = _nonEmpty(options?.domain) ?? this.domain;
    final token = _nonEmpty(options?.token) ?? this.token;
    final base = (options?.apiUrl?.toString().isEmpty == true
            ? null
            : options?.apiUrl) ??
        _client.config.volumeApiUrl ??
        Uri.parse((options?.debug ?? debug)
            ? 'http://localhost:8080'
            : 'https://api.$domain');
    return ContentTransport(
        _client.httpClientFor(RequestOptions(
            httpVersion: options?.httpVersion ?? httpVersion,
            proxy: options?.proxy == null || options!.proxy!.isEmpty
                ? proxy
                : options.proxy)),
        base,
        {
          ...defaultHeaders,
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          ...?options?.headers
        },
        options?.requestTimeout ??
            (file ? const Duration(hours: 1) : const Duration(seconds: 60)),
        signal: options?.signal,
        logger: options?.logger,
        responseError: (status, body, reason) =>
            _volumeError(status, body, reason, notFound: true));
  }

  Future<T> _check<T>(String path, Future<T> Function() operation) async {
    try {
      return await operation();
    } on NotFoundException catch (e) {
      throw VolumePathNotFoundException('Path $path not found',
          statusCode: e.statusCode, code: e.code);
    }
  }

  Future<VolumeEntryStat> _entry(String method, String suffix, String path,
          {Map<String, String> query = const {},
          Map<String, dynamic>? metadata,
          VolumeRequestOptions? options}) =>
      _check(path, () async {
        final response = await _transport(options).request(
            method, _path(suffix),
            query: {'path': path, ...query},
            data: metadata == null ? null : jsonEncode(metadata),
            extraHeaders: {
              if (metadata != null) 'Content-Type': 'application/json'
            });
        return VolumeEntryStat(_requiredVolumeData(decodeBody(response.body)));
      });
  Future<List<VolumeEntryStat>> _list(String path,
          {int? depth, VolumeRequestOptions? options}) =>
      _check(path, () async {
        final response = await _transport(options).request('GET', _path('dir'),
            query: {'path': path, if (depth != null) 'depth': '$depth'});
        final body = decodeBody(response.body);
        return (body is List ? body : const [])
            .map((e) => VolumeEntryStat(e as Map<String, dynamic>))
            .toList();
      });
  Future<VolumeEntryStat> makeDir(String path,
          {int? uid,
          int? gid,
          int? mode,
          bool? force,
          VolumeRequestOptions? options}) =>
      _entry('POST', 'dir', path,
          query: _writeQuery(uid, gid, mode, force), options: options);
  Future<VolumeEntryStat> _getInfo(String path,
          {VolumeRequestOptions? options}) =>
      _entry('GET', 'path', path, options: options);
  Future<bool> exists(String path, {VolumeRequestOptions? options}) async {
    try {
      await _getInfo(path, options: options);
      return true;
    } on VolumePathNotFoundException {
      return false;
    }
  }

  Future<VolumeEntryStat> updateMetadata(String path,
          {int? uid, int? gid, int? mode, VolumeRequestOptions? options}) =>
      _entry('PATCH', 'path', path,
          metadata: {
            if (uid != null) 'uid': uid,
            if (gid != null) 'gid': gid,
            if (mode != null) 'mode': mode
          },
          options: options);
  Future<Uint8List> readBytes(String path, {VolumeRequestOptions? options}) =>
      _check(
          path,
          () async => (await _transport(options, file: true)
                  .request('GET', _path('file'), query: {'path': path}))
              .bodyBytes);
  Future<String> readFile(String path, {VolumeRequestOptions? options}) async =>
      utf8.decode(await readBytes(path, options: options),
          allowMalformed: true);
  Stream<List<int>> readStream(String path,
          {Duration? idleTimeout, VolumeRequestOptions? options}) =>
      _transport(options, file: true)
          .readStream(_path('file'),
              query: {'path': path}, idleTimeout: idleTimeout)
          .handleError((Object error) {
        if (error is NotFoundException) {
          throw VolumePathNotFoundException('Path $path not found',
              statusCode: error.statusCode, code: error.code);
        }
        throw error;
      });
  Future<VolumeEntryStat> writeFile(String path, Object data,
          {int? uid,
          int? gid,
          int? mode,
          bool? force,
          VolumeRequestOptions? options}) =>
      _check(path, () async {
        final transport = _transport(options, file: true);
        final upload = await prepareUpload(data, signal: transport.signal);
        final response = await transport.request('PUT', _path('file'),
            query: {'path': path, ..._writeQuery(uid, gid, mode, force)},
            data: upload.data,
            streamed: upload.streamed,
            extraHeaders: {'Content-Type': 'application/octet-stream'});
        return VolumeEntryStat(_requiredVolumeData(decodeBody(response.body)));
      });
  Future<void> remove(String path, {VolumeRequestOptions? options}) =>
      _check(path, () async {
        await _transport(options)
            .request('DELETE', _path('path'), query: {'path': path});
      });
  Map<String, String> _writeQuery(int? uid, int? gid, int? mode, bool? force) =>
      {
        if (uid != null) 'uid': '$uid',
        if (gid != null) 'gid': '$gid',
        if (mode != null) 'mode': '$mode',
        if (force != null) 'force': '$force',
      };
}

/// Instance content methods share official names with static management methods.
extension VolumeContent on Volume {
  Future<List<VolumeEntryStat>> list(String path,
          {int? depth, VolumeRequestOptions? options}) =>
      _list(path, depth: depth, options: options);
  Future<VolumeEntryStat> getInfo(String path,
          {VolumeRequestOptions? options}) =>
      _getInfo(path, options: options);
}
