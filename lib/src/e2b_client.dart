// Official resource names intentionally retain their JavaScript capitalization.
// ignore_for_file: non_constant_identifier_names
import 'client.dart';
import 'secret.dart';
import 'volume.dart';
import 'template.dart';
import 'connection.dart';
import 'models.dart';
import 'paginator.dart';
import 'network.dart';

/// Connection defaults bound to an E2B client; cancellation is per request.
class E2BClientOpts extends RequestOptions {
  final Map<String, String> _boundHeaders;
  final Map<String, String> _boundApiHeaders;
  E2BClientOpts(
      {super.apiKey,
      super.validateApiKey,
      super.logger,
      super.proxy,
      super.httpVersion,
      super.debug,
      super.domain,
      super.apiUrl,
      super.sandboxUrl,
      super.headers,
      super.apiHeaders,
      super.requestTimeout,
      super.retries})
      : _boundHeaders = headers ?? const {},
        _boundApiHeaders = apiHeaders ?? const {};
}

/// Client-bound resource entry points corresponding to the official E2B client.
/// Call [close] when operations on this client and its resources have finished.
class E2B extends E2BClient {
  final Map<String, String> _boundHeaders;
  final Map<String, String> _boundApiHeaders;
  E2B.fromOptions(E2BClientOpts options, {super.httpClient})
      : _boundHeaders = options._boundHeaders,
        _boundApiHeaders = options._boundApiHeaders,
        super(
            apiKey: options.apiKey,
            validateApiKey: options.validateApiKey,
            logger: options.logger,
            proxy: options.proxy,
            httpVersion: options.httpVersion,
            debug: options.debug,
            domain: options.domain,
            apiUrl: options.apiUrl,
            sandboxUrl: options.sandboxUrl,
            headers: options.headers,
            requestTimeout:
                options.requestTimeout ?? const Duration(seconds: 60),
            retries: options.retries ?? 3);
  E2B(
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
      super.headers = const {},
      super.apiHeaders = const {}})
      : _boundHeaders = headers,
        _boundApiHeaders = apiHeaders;

  @override
  Map<String, String> get headers =>
      ConnectionConfig(headers: _boundHeaders, apiHeaders: _boundApiHeaders)
          .headers;

  @override
  Map<String, String> requestHeaders(RequestOptions? options) =>
      ConnectionConfig(
              headers: options?.legacyHeaders ?? _boundHeaders,
              apiHeaders: options?.apiHeaders ?? _boundApiHeaders)
          .headers;

  @override
  E2B withOptions(RequestOptions? options) {
    if (options == null) return this;
    final derived = super.withOptions(options);
    return E2B(
        apiKey: derived.config.apiKey,
        validateApiKey: derived.config.validateApiKey,
        logger: derived.config.logger,
        proxy: derived.config.proxy,
        httpVersion: derived.config.httpVersion,
        debug: derived.config.debug,
        domain: derived.domain,
        apiUrl: derived.config.explicitApiUrl,
        sandboxUrl: derived.sandboxUrl,
        volumeApiUrl: derived.config.volumeApiUrl,
        headers: options.legacyHeaders ?? _boundHeaders,
        apiHeaders: options.apiHeaders ?? _boundApiHeaders,
        requestTimeout: derived.requestTimeout,
        retries: derived.config.retries,
        clientPool: clientPool);
  }

  late final SandboxResource Sandbox = SandboxResource(this);
  late final SecretResource Secret = SecretResource(secrets);
  Volumes get Volume => volumes;
  Templates get Template => templates;
}

/// Sandbox management factory bound to a client's connection defaults.
class SandboxResource {
  final E2BClient _client;
  SandboxResource(this._client);

  SandboxPaginator list(
          {num? limit,
          String? nextToken,
          List<SandboxState>? state,
          Map<String, String>? metadata,
          String? template,
          DateTime? startedAfter,
          SandboxListOrder? order,
          RequestOptions? options}) =>
      _client.listPaginator(
          limit: limit,
          nextToken: nextToken,
          state: state,
          metadata: metadata,
          template: template,
          startedAfter: startedAfter,
          order: order,
          options: options);

  Future<Sandbox> connect(String sandboxId,
          {Duration? timeout, OnResume? onResume, RequestOptions? options}) =>
      _client.connect(sandboxId,
          timeout: timeout, onResume: onResume, options: options);
  Future<SandboxInfo> getInfo(String sandboxId, {RequestOptions? options}) =>
      _client.getInfo(sandboxId, options: options);
  Future<bool> kill(String sandboxId, {RequestOptions? options}) =>
      _client.kill(sandboxId, options: options);
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
          Map<String, Object>? volumeMounts}) =>
      _client.create(
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
          volumeMounts: volumeMounts);
  Future<SandboxInfo> getFullInfo(String sandboxId,
          {RequestOptions? options}) =>
      _client.getFullInfo(sandboxId, options: options);
  Future<bool> pause(String sandboxId,
          {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) =>
      _client.pause(sandboxId,
          mode: mode, keepMemory: keepMemory, options: options);
  Future<bool> betaPause(String sandboxId,
          {SnapshotMode? mode, bool? keepMemory, RequestOptions? options}) =>
      _client.betaPause(sandboxId,
          mode: mode, keepMemory: keepMemory, options: options);
  Future<void> setTimeout(String sandboxId, Duration timeout,
          {RequestOptions? options}) =>
      _client.setTimeout(sandboxId, timeout, options: options);
  Future<void> updateNetwork(String sandboxId, SandboxNetwork network,
          {RequestOptions? options}) =>
      _client.updateNetwork(sandboxId, network, options: options);
  Future<List<SandboxMetrics>> getMetrics(String sandboxId,
          {DateTime? start, DateTime? end, RequestOptions? options}) =>
      _client.getMetrics(sandboxId, start: start, end: end, options: options);
  Future<SnapshotInfo> createSnapshot(String sandboxId,
          {String? name, SnapshotMode? mode, RequestOptions? options}) =>
      _client.createSnapshot(sandboxId,
          name: name, mode: mode, options: options);
  Paginator<SnapshotInfo> listSnapshots(
          {String? sandboxId,
          String? name,
          num? limit,
          String? nextToken,
          RequestOptions? options}) =>
      _client.listSnapshots(
          sandboxId: sandboxId,
          name: name,
          limit: limit,
          nextToken: nextToken,
          options: options);
  Future<bool> deleteSnapshot(String snapshotId, {RequestOptions? options}) =>
      _client.deleteSnapshot(snapshotId, options: options);
  Future<List<SandboxForkResult>> fork(String sandboxId,
          {num? count, Duration? timeout, RequestOptions? options}) =>
      _client.fork(sandboxId, count: count, timeout: timeout, options: options);
}

/// Secret management and formatting helpers bound to a client.
class SecretResource {
  final Secrets _resource;
  SecretResource(this._resource);
  String fill(String name) => Secret.fill(name);
  IamToken iamToken({required String audience, required String tokenType}) =>
      Secret.iamToken(audience: audience, tokenType: tokenType);
  Future<SecretInfo> create(String name, String value,
          {Map<String, String>? metadata, RequestOptions? options}) =>
      _resource.create(name, value, metadata: metadata, options: options);
  Future<SecretInfo> update(String secret, String value,
          {Map<String, String>? metadata, RequestOptions? options}) =>
      _resource.update(secret, value, metadata: metadata, options: options);
  Future<SecretInfo> getInfo(String secret, {RequestOptions? options}) =>
      _resource.getInfo(secret, options: options);
  Future<bool> exists(String secret, {RequestOptions? options}) =>
      _resource.exists(secret, options: options);
  Future<bool> destroy(String secret, {RequestOptions? options}) =>
      _resource.destroy(secret, options: options);
  SecretPaginator list(
          {num? limit, String? nextToken, RequestOptions? options}) =>
      _resource.list(limit: limit, nextToken: nextToken, options: options);
}
