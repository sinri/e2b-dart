import 'envd_api_error.dart';
import 'git.dart';
import 'resource_api_error.dart';
import 'commands.dart';
import 'errors.dart';
import 'filesystem.dart';
import 'models.dart';
import 'transport.dart';
import 'api.dart';
import 'connection.dart';
import 'secret.dart';
import 'network.dart';
import 'paginator.dart';
import 'signature.dart';
import 'volume.dart';
import 'template.dart';
import 'content_transport.dart';

/// Reusable client. Explicit API keys work on Dart VM and Flutter web alike.
/// Close this client once all sandbox operations have finished.
class E2BClient extends ApiClient {
  late final Templates templates = Templates(this);
  late final Secrets secrets = Secrets(this);
  late final Volumes volumes = Volumes(this);
  E2BClient(
      {super.apiKey,
      super.validateApiKey,
      super.logger,
      super.proxy,
      super.httpVersion,
      super.domain,
      super.apiUrl,
      super.sandboxUrl,
      super.volumeApiUrl,
      super.debug,
      super.requestTimeout,
      super.retries,
      super.httpClient,
      super.clientPool,
      super.headers,
      super.apiHeaders})
      : super(deferApiKeyValidation: true);

  E2BClient withOptions(RequestOptions? options) {
    if (options == null) return this;
    return E2BClient(
        apiKey: options.apiKey ?? config.apiKey,
        validateApiKey: options.validateApiKey ?? config.validateApiKey,
        logger: options.logger ?? config.logger,
        proxy: options.proxy ?? config.proxy,
        httpVersion: options.httpVersion ?? config.httpVersion,
        domain: options.domain ?? domain,
        apiUrl: options.apiUrl ?? config.explicitApiUrl,
        sandboxUrl: options.sandboxUrl ?? sandboxUrl,
        volumeApiUrl: config.volumeApiUrl,
        debug: options.debug ?? config.debug,
        requestTimeout: options.requestTimeout ?? requestTimeout,
        retries: options.retries ?? config.retries,
        clientPool: clientPool,
        headers: options.hasHeadersOverride ? options.headers : headers);
  }

  Future<Sandbox> create(
      {String? template,
      Duration? timeout,
      Map<String, String>? metadata,
      Map<String, String>? envs,
      bool? allowInternetAccess,
      // Accepted for JS compatibility; every sandbox secures envd access.
      bool? secure,
      bool? autoPause,
      bool? autoResume,
      Object? network,
      SandboxIam? iam,
      SandboxLifecycle? lifecycle,
      Object? mcp,
      RequestOptions? options,
      Map<String, Object>? volumeMounts}) async {
    if (options?.debug ?? config.debug) {
      return Sandbox._(
          this, {'sandboxID': 'debug_sandbox_id', 'envdVersion': '99.99.99'},
          options: options);
    }
    if (lifecycle != null && (autoPause != null || autoResume != null)) {
      throw const InvalidArgumentException(
          'Pass lifecycle or deprecated autoPause/autoResume, not both');
    }
    if (autoResume == true && autoPause != true) {
      throw const InvalidArgumentException('Auto-resume requires autoPause');
    }
    final iamBody = iam?.toJson();
    final data = await request('POST', '/v2/sandboxes',
        options: options,
        responseError: _sandboxApiError,
        body: {
          'templateID': template ?? (mcp == null ? 'base' : 'mcp-gateway'),
          if (timeout != null) 'timeout': _seconds(timeout),
          if (metadata != null) 'metadata': metadata,
          if (envs != null) 'envVars': envs,
          if (allowInternetAccess != null)
            'allow_internet_access': allowInternetAccess,
          if (autoPause != null) 'autoPause': autoPause,
          if (lifecycle != null) ...lifecycle.toJson(),
          if (iamBody != null) 'iam': iamBody,
          if (mcp != null) 'mcp': mcp,
          if (autoResume != null) 'autoResume': {'enabled': autoResume},
          if (network != null)
            'network': network is SandboxNetwork
                ? network.toJson(
                    tokenNames:
                        (iamBody?['tokens'] as Map<String, dynamic>?)?.keys ??
                            [])
                : network as Map<String, dynamic>,
          if (volumeMounts != null)
            'volumeMounts': volumeMounts.entries
                .map((e) => {
                      'path': e.key,
                      'name': e.value is Volume
                          ? (e.value as Volume).name
                          : e.value as String
                    })
                .toList(),
        });
    final result = data as Map<String, dynamic>;
    final version = result['envdVersion'] as String?;
    if (version != null) {
      final parts =
          version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      if (parts.first == 0 && (parts.length < 2 || parts[1] < 1)) {
        await kill(result['sandboxID'] as String, options: options);
        throw const TemplateException(
            'You need to update the template to use the new SDK.');
      }
    }
    return Sandbox._(this, result, options: options);
  }

  Future<Sandbox> connect(String sandboxId,
      {Duration? timeout, OnResume? onResume, RequestOptions? options}) async {
    if (options?.debug ?? config.debug) {
      return Sandbox._(
          this, {'sandboxID': sandboxId, 'envdVersion': '99.99.99'},
          options: options);
    }
    return Sandbox._(
        this,
        await request('POST', '/v2/sandboxes/${_id(sandboxId)}/connect',
            body: {
              if (timeout != null) 'timeout': _seconds(timeout),
              if (onResume == OnResume.reboot) 'memory': false
            },
            options: options, responseError: (status, body, reason) {
          if (body is Map && body['code'] == 404) {
            return SandboxNotFoundException(
                'Paused sandbox $sandboxId not found',
                statusCode: status);
          }
          return _sandboxApiError(status, body, reason);
        }) as Map<String, dynamic>,
        options: options);
  }

  Future<SandboxInfo> getInfo(String sandboxId,
      {RequestOptions? options}) async {
    final data = await request('GET', '/sandboxes/${_id(sandboxId)}',
        options: options,
        responseError: (status, body, reason) =>
            _sandboxResponseError(sandboxId, status, body, reason));
    if (data == null) throw const E2BException('Sandbox not found');
    return SandboxInfo(data as Map<String, dynamic>);
  }

  Future<SandboxInfo> getFullInfo(String sandboxId,
          {RequestOptions? options}) =>
      getInfo(sandboxId, options: options);
  Future<bool> kill(String sandboxId, {RequestOptions? options}) async {
    if (options?.debug ?? config.debug) return true;
    try {
      await request('DELETE', '/sandboxes/${_id(sandboxId)}',
          options: options, responseError: _deleteResponseError);
      return true;
    } on _ResourceAbsent {
      return false;
    }
  }

  Future<bool> pause(String sandboxId,
      {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) async {
    if (mode != null && keepMemory != null) {
      throw const InvalidArgumentException(
          'Pass either mode or the deprecated keepMemory, not both.');
    }
    try {
      await request('POST', '/sandboxes/${_id(sandboxId)}/pause',
          body: {
            if (mode != null || keepMemory != null)
              'memory': mode != null ? mode == SnapshotMode.full : keepMemory
          },
          options: options, responseError: (status, body, reason) {
        if (body is Map && body['code'] == 409) {
          return const _AlreadyPaused();
        }
        return _sandboxResponseError(sandboxId, status, body, reason);
      });
      return true;
    } on _AlreadyPaused {
      return false;
    }
  }

  Future<bool> betaPause(String sandboxId,
          {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) =>
      pause(sandboxId, mode: mode, keepMemory: keepMemory, options: options);
  Future<void> setTimeout(String sandboxId, Duration timeout,
      {RequestOptions? options}) async {
    await request('POST', '/sandboxes/${_id(sandboxId)}/timeout',
        body: {'timeout': _seconds(timeout)},
        options: options,
        responseError: (status, body, reason) =>
            _sandboxResponseError(sandboxId, status, body, reason));
  }

  Future<void> updateNetwork(String sandboxId, SandboxNetwork network,
      {RequestOptions? options}) async {
    await request('PUT', '/sandboxes/${_id(sandboxId)}/network',
        body: network.toJson(update: true),
        options: options,
        responseError: (status, body, reason) =>
            _sandboxResponseError(sandboxId, status, body, reason));
  }

  Object _deleteResponseError(int status, Object? body, String? reason) {
    if (body is Map && body['code'] == 404) return const _ResourceAbsent();
    return _sandboxApiError(status, body, reason);
  }

  Object _sandboxApiError(int status, Object? body, String? reason) =>
      resourceApiError(status, body, reason,
          fallback: (message, status) =>
              SandboxException(message, statusCode: status));

  Object _sandboxResponseError(
      String sandboxId, int status, Object? body, String? reason) {
    if (body is Map && body['code'] == 404) {
      return SandboxNotFoundException('Sandbox $sandboxId not found',
          statusCode: status);
    }
    return _sandboxApiError(status, body, reason);
  }

  Future<List<SandboxMetrics>> getMetrics(String sandboxId,
      {DateTime? start, DateTime? end, RequestOptions? options}) async {
    if (options?.debug ?? config.debug) return [];
    return (await request('GET', '/sandboxes/${_id(sandboxId)}/metrics',
                query: {
                  if (start != null)
                    'start':
                        '${(start.millisecondsSinceEpoch / 1000 + 0.5).floor()}',
                  if (end != null)
                    'end':
                        '${(end.millisecondsSinceEpoch / 1000 + 0.5).floor()}',
                },
                options: options, responseError: (status, body, reason) {
              return _sandboxResponseError(sandboxId, status, body, reason);
            }) as List? ??
            const [])
        .map((e) => SandboxMetrics(e as Map<String, dynamic>))
        .toList();
  }

  Future<SnapshotInfo> createSnapshot(String sandboxId,
          {String? name, SnapshotMode? mode, RequestOptions? options}) async =>
      SnapshotInfo(await request(
              'POST', '/sandboxes/${_id(sandboxId)}/snapshots',
              body: {
                if (name != null && name.isNotEmpty) 'name': name,
                if (mode != null) 'memory': mode == SnapshotMode.full,
              },
              options: options,
              responseError: (status, body, reason) =>
                  _sandboxResponseError(sandboxId, status, body, reason))
          as Map<String, dynamic>);
  Paginator<SnapshotInfo> listSnapshots(
          {String? sandboxId,
          String? name,
          num? limit,
          String? nextToken,
          RequestOptions? options}) =>
      SnapshotPaginator(
          client: this,
          sandboxId: sandboxId,
          name: name,
          limit: limit,
          nextToken: nextToken,
          options: options);
  Future<bool> deleteSnapshot(String snapshotId,
      {RequestOptions? options}) async {
    try {
      await request('DELETE', '/templates/${_id(snapshotId)}',
          options: options, responseError: _deleteResponseError);
      return true;
    } on _ResourceAbsent {
      return false;
    }
  }

  Future<List<SandboxForkResult>> fork(String sandboxId,
      {num? count, Duration? timeout, RequestOptions? options}) async {
    if (count != null &&
        (!count.isFinite || count % 1 != 0 || count < 1 || count > 20)) {
      throw const InvalidArgumentException(
          'count must be an integer between 1 and 20');
    }
    final data = await request('POST', '/sandboxes/${_id(sandboxId)}/fork',
            options: options, responseError: (status, body, reason) {
          if (status == 404) {
            return SandboxNotFoundException(
                body is Map && body['message'] != null
                    ? body['message'].toString()
                    : 'Sandbox $sandboxId not found',
                statusCode: status);
          }
          return _sandboxApiError(status, body, reason);
        }, body: {
          if (count != null) 'count': count.toInt(),
          if (timeout != null) 'timeout': _seconds(timeout)
        }) as List? ??
        const [];
    return data.map((value) {
      final result = value as Map<String, dynamic>;
      if (result['error'] != null || result['sandbox'] == null) {
        final error = result['error'] as Map?;
        if (error == null) {
          return SandboxForkResult.failure(
              const SandboxException('Failed to start forked sandbox'));
        }
        final code = error['code'] as int;
        final message = '$code: ${error['message'] ?? 'undefined'}';
        if (code == 404) {
          return SandboxForkResult.failure(
              NotFoundException(message, statusCode: code));
        }
        return SandboxForkResult.failure(resourceApiError(
            code, error['message'], null,
            fallback: (_, status) =>
                SandboxException(message, statusCode: status)) as E2BException);
      }
      return SandboxForkResult.success(Sandbox._(
          this, result['sandbox'] as Map<String, dynamic>,
          options: options));
    }).toList();
  }

  SandboxPaginator listPaginator(
          {num? limit,
          String? nextToken,
          List<SandboxState>? state,
          Map<String, String>? metadata,
          String? template,
          DateTime? startedAfter,
          SandboxListOrder? order,
          RequestOptions? options}) =>
      SandboxPaginator(
          client: this,
          limit: limit,
          nextToken: nextToken,
          state: state,
          metadata: metadata,
          template: template,
          startedAfter: startedAfter,
          order: order,
          options: options);

  Future<SandboxPage> list(
      {num? limit,
      String? nextToken,
      List<SandboxState>? state,
      Map<String, String>? metadata,
      String? template,
      DateTime? startedAfter,
      SandboxListOrder? order,
      RequestOptions? options}) async {
    final pages = listPaginator(
        limit: limit,
        nextToken: nextToken,
        state: state,
        metadata: metadata,
        template: template,
        startedAfter: startedAfter,
        order: order,
        options: options);
    return SandboxPage(await pages.nextItems(), pages.nextToken);
  }

  /// Iterate all pages lazily, performing one request per page.
  Stream<SandboxInfo> listAll(
      {int pageSize = 100,
      List<SandboxState>? state,
      Map<String, String>? metadata,
      String? template,
      DateTime? startedAfter,
      SandboxListOrder? order,
      RequestOptions? options}) async* {
    String? token;
    do {
      final page = await list(
          limit: pageSize,
          nextToken: token,
          state: state,
          metadata: metadata,
          template: template,
          startedAfter: startedAfter,
          order: order,
          options: options);
      yield* Stream.fromIterable(page.items);
      token = page.hasNext ? page.nextToken : null;
    } while (token != null);
  }
}

String _id(String value) {
  if (value.isEmpty) throw ArgumentError.value(value, 'sandboxId');
  return Uri.encodeComponent(value);
}

int _seconds(Duration duration) {
  return (duration.inMicroseconds / Duration.microsecondsPerSecond).ceil();
}

String _metadataQuery(Map<String, String> metadata) => Uri(
        queryParameters: metadata.map(
            (k, v) => MapEntry(Uri.encodeComponent(k), Uri.encodeComponent(v))))
    .query;

/// Sandbox cursor pagination, usable directly or through a bound client.
class SandboxPaginator extends Paginator<SandboxInfo> {
  SandboxPaginator(
      {ApiClient? client,
      num? limit,
      String? nextToken,
      List<SandboxState>? state,
      Map<String, String>? metadata,
      String? template,
      DateTime? startedAfter,
      SandboxListOrder? order,
      RequestOptions? options})
      : super(client, '/v2/sandboxes', SandboxInfo.new,
            clientFactory: client == null
                ? () => ApiClient(deferApiKeyValidation: true)
                : null,
            responseError: (status, body, reason) => resourceApiError(
                status, body, reason,
                fallback: (message, status) =>
                    SandboxException(message, statusCode: status)),
            limit: limit,
            nextToken: nextToken,
            options: options,
            queryBuilder: () => {
                  if (state != null) 'state': state.join(','),
                  if (metadata != null) 'metadata': _metadataQuery(metadata),
                  if (template != null && template.isNotEmpty)
                    'template': template,
                  if (startedAfter != null)
                    'startedAfter': _jsTimestamp(startedAfter),
                  if (order != null) 'order': order,
                });
}

/// Lazy snapshot pages, with an optional caller-owned management client.
class SnapshotPaginator extends Paginator<SnapshotInfo> {
  SnapshotPaginator(
      {ApiClient? client,
      String? sandboxId,
      String? name,
      num? limit,
      String? nextToken,
      RequestOptions? options})
      : super(client, '/snapshots', SnapshotInfo.new,
            clientFactory: client == null
                ? () => ApiClient(deferApiKeyValidation: true)
                : null,
            responseError: (status, body, reason) => resourceApiError(
                status, body, reason,
                fallback: (message, status) =>
                    SandboxException(message, statusCode: status)),
            limit: limit,
            nextToken: nextToken,
            options: options,
            query: {
              if (sandboxId != null) 'sandboxID': sandboxId,
              if (name != null) 'name': name
            });
}

class SandboxForkResult {
  final Sandbox? sandbox;
  final E2BException? error;
  bool get isSuccess => sandbox != null;
  const SandboxForkResult.success(Sandbox value)
      : sandbox = value,
        error = null;
  const SandboxForkResult.failure(E2BException value)
      : error = value,
        sandbox = null;
}

class Sandbox {
  @Deprecated('Use getInfo instead')
  static Future<SandboxInfo> getFullInfo(String sandboxId,
          {RequestOptions? options, E2BClient? client}) =>
      getInfo(sandboxId, options: options, client: client);

  static Future<List<SandboxMetrics>> getMetrics(String sandboxId,
          {DateTime? start,
          DateTime? end,
          RequestOptions? options,
          E2BClient? client}) =>
      _manage(
          client,
          (resolved) => resolved.getMetrics(sandboxId,
              start: start, end: end, options: options));

  static Future<SnapshotInfo> createSnapshot(String sandboxId,
          {String? name,
          SnapshotMode? mode,
          RequestOptions? options,
          E2BClient? client}) =>
      _manage(
          client,
          (resolved) => resolved.createSnapshot(sandboxId,
              name: name, mode: mode, options: options));

  static SnapshotPaginator listSnapshots(
          {String? sandboxId,
          String? name,
          num? limit,
          String? nextToken,
          RequestOptions? options,
          E2BClient? client}) =>
      SnapshotPaginator(
          client: client,
          sandboxId: sandboxId,
          name: name,
          limit: limit,
          nextToken: nextToken,
          options: options);

  static Future<bool> deleteSnapshot(String snapshotId,
          {RequestOptions? options, E2BClient? client}) =>
      _manage(client,
          (resolved) => resolved.deleteSnapshot(snapshotId, options: options));

  static Future<T> _manage<T>(
      E2BClient? client, Future<T> Function(E2BClient) operation) async {
    final resolved = client ?? E2BClient();
    try {
      return await operation(resolved);
    } finally {
      if (client == null) resolved.close();
    }
  }

  static Future<SandboxInfo> getInfo(String sandboxId,
          {RequestOptions? options, E2BClient? client}) =>
      _manage(
          client, (resolved) => resolved.getInfo(sandboxId, options: options));
  static Future<bool> kill(String sandboxId,
          {RequestOptions? options, E2BClient? client}) =>
      _manage(client, (resolved) => resolved.kill(sandboxId, options: options));
  static Future<bool> pause(String sandboxId,
          {SnapshotMode? mode,
          bool? keepMemory,
          RequestOptions? options,
          E2BClient? client}) =>
      _manage(
          client,
          (resolved) => resolved.pause(sandboxId,
              mode: mode, keepMemory: keepMemory, options: options));
  static Future<bool> betaPause(String sandboxId,
          {SnapshotMode? mode,
          bool? keepMemory,
          RequestOptions? options,
          E2BClient? client}) =>
      pause(sandboxId,
          mode: mode, keepMemory: keepMemory, options: options, client: client);
  static Future<void> setTimeout(String sandboxId, Duration timeout,
          {RequestOptions? options, E2BClient? client}) =>
      _manage(
          client,
          (resolved) =>
              resolved.setTimeout(sandboxId, timeout, options: options));
  static Future<void> updateNetwork(String sandboxId, SandboxNetwork network,
          {RequestOptions? options, E2BClient? client}) =>
      _manage(
          client,
          (resolved) =>
              resolved.updateNetwork(sandboxId, network, options: options));

  /// Returns a Sandbox or E2BException for each fork, preserving server order.
  static Future<List<Object>> fork(String sandboxId,
      {num? count,
      Duration? timeout,
      RequestOptions? options,
      E2BClient? client}) async {
    final resolved = client ?? E2BClient();
    try {
      final results = await resolved.fork(sandboxId,
          count: count, timeout: timeout, options: options);
      final successes = results.where((result) => result.isSuccess).length;
      var remaining = successes;
      if (client == null && successes == 0) resolved.close();
      return results.map<Object>((result) {
        final sandbox = result.sandbox;
        if (sandbox == null) return result.error!;
        if (client == null) {
          sandbox._releaseClient = () {
            remaining--;
            if (remaining == 0) resolved.close();
          };
        }
        return sandbox;
      }).toList();
    } catch (_) {
      if (client == null) resolved.close();
      rethrow;
    }
  }

  /// Lists sandbox pages lazily, using the same filters as a bound client.
  static SandboxPaginator list(
          {num? limit,
          String? nextToken,
          List<SandboxState>? state,
          Map<String, String>? metadata,
          String? template,
          DateTime? startedAfter,
          SandboxListOrder? order,
          RequestOptions? options,
          E2BClient? client}) =>
      SandboxPaginator(
          client: client,
          limit: limit,
          nextToken: nextToken,
          state: state,
          metadata: metadata,
          template: template,
          startedAfter: startedAfter,
          order: order,
          options: options);

  E2BClient? _ownedClient;
  void Function()? _releaseClient;

  /// Releases the client created by a static factory. Does not kill the sandbox.
  /// Sandboxes obtained from a caller-owned client leave that client open.
  void close() {
    _ownedClient?.close();
    _ownedClient = null;
    final release = _releaseClient;
    _releaseClient = null;
    release?.call();
  }

  static Future<Sandbox> _fromClient(
      E2BClient? client, Future<Sandbox> Function(E2BClient) operation) async {
    final resolved = client ?? E2BClient();
    try {
      final sandbox = await operation(resolved);
      if (client == null) sandbox._ownedClient = resolved;
      return sandbox;
    } catch (_) {
      if (client == null) resolved.close();
      rethrow;
    }
  }

  static Future<Sandbox> create(
          {String? template,
          Duration? timeout,
          Map<String, String>? metadata,
          Map<String, String>? envs,
          bool? allowInternetAccess,
          bool? secure,
          bool? autoPause,
          bool? autoResume,
          Object? network,
          SandboxIam? iam,
          SandboxLifecycle? lifecycle,
          Object? mcp,
          RequestOptions? options,
          Map<String, Object>? volumeMounts,
          E2BClient? client}) =>
      _fromClient(
          client,
          (resolved) => resolved.create(
              template: template,
              timeout: timeout,
              metadata: metadata,
              envs: envs,
              allowInternetAccess: allowInternetAccess,
              secure: secure,
              autoPause: autoPause,
              autoResume: autoResume,
              network: network,
              iam: iam,
              lifecycle: lifecycle,
              mcp: mcp,
              options: options,
              volumeMounts: volumeMounts));

  static Future<Sandbox> connect(String sandboxId,
          {Duration? timeout,
          OnResume? onResume,
          RequestOptions? options,
          E2BClient? client}) =>
      _fromClient(
          client,
          (resolved) => resolved.connect(sandboxId,
              timeout: timeout, onResume: onResume, options: options));

  final E2BClient _client;
  final String sandboxId;
  String sandboxDomain;
  String envdVersion;
  late Commands _commands;
  Commands get commands => _commands;
  late Git _git;
  Git get git => _git;
  late Filesystem _files;
  Filesystem get files => _files;
  late Pty _pty;
  Pty get pty => _pty;
  late EnvdTransport _transport;
  String? _envdAccessToken;
  String? _mcpToken;
  final String? trafficAccessToken;
  Sandbox._(E2BClient client, Map<String, dynamic> data,
      {RequestOptions? options})
      : _client = client.withOptions(options),
        sandboxId = data['sandboxID'] as String,
        sandboxDomain = _nonEmpty(data['domain'] as String?) ??
            options?.domain ??
            client.domain,
        trafficAccessToken = _nonEmpty(data['trafficAccessToken'] as String?),
        envdVersion = data['envdVersion'] as String? ?? '' {
    final transport = EnvdTransport(
        _client.envdHttpClientFor(null, rpc: true),
        _client.config.getSandboxUrl(sandboxId, sandboxDomain: sandboxDomain),
        {
          'User-Agent': _client.headers['User-Agent'] ?? '',
          'E2b-Sandbox-Id': sandboxId,
          'E2b-Sandbox-Port': '49983',
          if (data['envdAccessToken'] != null)
            'X-Access-Token': data['envdAccessToken'] as String,
        },
        options?.requestTimeout ?? _client.requestTimeout,
        logger: _client.config.logger,
        clientResolver: (options) =>
            _client.envdHttpClientFor(options, rpc: true),
        restClientResolver: _client.envdHttpClientFor,
        restClient: _client.envdHttpClientFor(null));
    transport.version = envdVersion;
    _transport = transport;
    _envdAccessToken = data['envdAccessToken'] as String?;
    final version =
        envdVersion.split('.').map((v) => int.tryParse(v) ?? 0).toList();
    if (version.length >= 2 && version[0] == 0 && version[1] < 4) {
      transport.defaultUser = 'user';
    }
    _commands = Commands(transport);
    _git = Git(commands);
    _files = Filesystem(transport);
    _pty = Pty(transport);
  }
  String getHost(num port) {
    return _client.config
        .getHost(sandboxId, port, sandboxDomain: sandboxDomain);
  }

  Future<bool> isRunning({RequestOptions? options}) async {
    final transport = _transport.withOptions(options);
    final response = await ContentTransport(transport.restClient,
            transport.baseUrl, transport.headers, transport.requestTimeout,
            signal: transport.signal,
            logger: transport.logger,
            resolveError: transport.resolveError)
        .request('GET', '/health', validateStatus: false);
    if (response.statusCode == 502) return false;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw envdApiError(response.statusCode, decodeBody(response.body),
          response.reasonPhrase);
    }
    return true;
  }

  String getMcpUrl() => 'https://${getHost(50005)}/mcp';
  Future<String> getMcpToken() async {
    if (_mcpToken == null || _mcpToken!.isEmpty) {
      _mcpToken = await files.read('/etc/mcp-gateway/.token', user: 'root');
    }
    return _mcpToken!;
  }

  Uri uploadUrl({String? path, String? user, num? useSignatureExpiration}) =>
      _fileUrl(path ?? '', 'write', user, useSignatureExpiration);
  Uri downloadUrl(String path, {String? user, num? useSignatureExpiration}) =>
      _fileUrl(path, 'read', user, useSignatureExpiration);
  Uri _fileUrl(String path, String operation, String? user, num? expires) {
    user ??= _transport.defaultUser;
    if ((_envdAccessToken == null || _envdAccessToken!.isEmpty) &&
        expires != null) {
      throw const InvalidArgumentException(
          'Signature expiration can be used only when sandbox is created as secured.');
    }
    final signature = _envdAccessToken == null || _envdAccessToken!.isEmpty
        ? null
        : getSignature(
            path: path,
            operation: operation,
            user: user,
            envdAccessToken: _envdAccessToken!,
            expirationInSeconds: expires);
    return _client.config
        .getSandboxDirectUrl(sandboxId, sandboxDomain: sandboxDomain)
        .resolve('/files')
        .replace(queryParameters: {
      if (user != null && user.isNotEmpty) 'username': user,
      if (path.isNotEmpty) 'path': path,
      if (signature != null) 'signature': signature.signature,
      if (signature?.expiration != null)
        'signature_expiration': signature!.expirationText!,
    });
  }
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

String _jsTimestamp(DateTime value) =>
    DateTime.fromMillisecondsSinceEpoch(value.millisecondsSinceEpoch,
            isUtc: true)
        .toIso8601String();

class _AlreadyPaused {
  const _AlreadyPaused();
}

class _ResourceAbsent {
  const _ResourceAbsent();
}

/// Instance reconnect coexists with the static Sandbox.connect factory.
extension SandboxReconnect on Sandbox {
  Future<List<SandboxMetrics>> getMetrics(
          {DateTime? start, DateTime? end, RequestOptions? options}) =>
      _client.getMetrics(sandboxId, start: start, end: end, options: options);
  Future<SnapshotInfo> createSnapshot(
          {String? name, SnapshotMode? mode, RequestOptions? options}) =>
      _client.createSnapshot(sandboxId,
          name: name, mode: mode, options: options);
  Paginator<SnapshotInfo> listSnapshots(
          {String? name,
          num? limit,
          String? nextToken,
          RequestOptions? options}) =>
      _client.listSnapshots(
          sandboxId: sandboxId,
          name: name,
          limit: limit,
          nextToken: nextToken,
          options: options);

  Future<SandboxInfo> getInfo({RequestOptions? options}) =>
      _client.getInfo(sandboxId, options: options);
  Future<bool> kill({RequestOptions? options}) =>
      _client.kill(sandboxId, options: options);
  Future<bool> pause(
          {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) =>
      _client.pause(sandboxId,
          mode: mode, keepMemory: keepMemory, options: options);
  Future<bool> betaPause(
          {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) =>
      pause(mode: mode, keepMemory: keepMemory, options: options);
  Future<void> setTimeout(Duration timeout, {RequestOptions? options}) async {
    if (_client.config.debug) return;
    await _client.setTimeout(sandboxId, timeout, options: options);
  }

  Future<void> updateNetwork(SandboxNetwork network,
          {RequestOptions? options}) =>
      _client.updateNetwork(sandboxId, network, options: options);

  Future<List<Object>> fork(
          {num? count, Duration? timeout, RequestOptions? options}) =>
      Sandbox.fork(sandboxId,
          client: _client, count: count, timeout: timeout, options: options);

  Future<Sandbox> connect(
      {Duration? timeout, OnResume? onResume, RequestOptions? options}) async {
    if (_client.config.debug) return this;
    final next = await _client.connect(sandboxId,
        timeout: timeout, onResume: onResume, options: options);
    _transport = next._transport;
    _envdAccessToken = next._envdAccessToken;
    sandboxDomain = next.sandboxDomain;
    envdVersion = next.envdVersion;
    _commands = next.commands;
    _git = next.git;
    _files = next.files;
    _pty = next.pty;
    return this;
  }
}
