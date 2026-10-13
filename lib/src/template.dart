import 'dockerfile.dart';
import 'dart:convert';
import 'template_files_stub.dart' if (dart.library.io) 'template_files_io.dart'
    as template_files;
import 'package:path/path.dart' as p;
import 'template_platform_stub.dart'
    if (dart.library.io) 'template_platform_io.dart' as platform;
import 'api.dart';
import 'api_date.dart';
import 'connection.dart';
import 'errors.dart';
import 'js_number.dart';
import 'mcp_generated.dart' show McpServerName;

String shellQuote(String value) => value.isEmpty
    ? "''"
    : RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$').hasMatch(value)
        ? value
        : "'${value.replaceAll("'", "'\"'\"'")}'";

class ReadyCmd {
  final String _cmd;
  const ReadyCmd(this._cmd);
  String getCmd() => _cmd;
}

ReadyCmd waitForPort(int port) =>
    ReadyCmd('[ -n "\$(ss -Htuln sport = :$port)" ]');
ReadyCmd waitForURL(String url, [int statusCode = 200]) => ReadyCmd(
    'curl -s -o /dev/null -w "%{http_code}" ${shellQuote(url)} | grep -q "$statusCode"');
ReadyCmd waitForProcess(String name) =>
    ReadyCmd('pgrep ${shellQuote(name)} > /dev/null');
ReadyCmd waitForFile(String path) => ReadyCmd('[ -f ${shellQuote(path)} ]');
ReadyCmd waitForTimeout(Duration timeout) =>
    ReadyCmd('sleep ${timeout.inSeconds < 1 ? 1 : timeout.inSeconds}');

class TemplateInstruction {
  final String type;
  final List<String> args;
  final bool force;
  final bool? forceUpload;
  final bool? resolveSymlinks;
  final bool? gzip;
  final String? filesHash;
  TemplateInstruction(this.type, Iterable<String> args,
      {this.force = false,
      this.forceUpload,
      this.resolveSymlinks,
      this.gzip,
      this.filesHash})
      : args = List.unmodifiable(args);
  Map<String, dynamic> toJson() => {
        'type': type,
        'args': args,
        'force': force,
        if (forceUpload == true) 'forceUpload': true,
        if (resolveSymlinks != null) 'resolveSymlinks': resolveSymlinks,
        if (gzip != null) 'gzip': gzip,
        if (filesHash != null) 'filesHash': filesHash
      };
}

class CopyItem {
  final Object src;
  final String dest;
  final bool? forceUpload;
  final String? user;
  final int? mode;
  final bool? resolveSymlinks;
  final bool? gzip;
  const CopyItem(this.src, this.dest,
      {this.forceUpload,
      this.user,
      this.mode,
      this.resolveSymlinks,
      this.gzip});
}

List<String> _strings(Object value) =>
    value is String ? [value] : List<String>.from(value as Iterable);

/// Mutable chain builder matching the official template instruction format.
/// Dart uses one mutable builder across all template stages.
/// These aliases preserve official type names without stage-restricted methods.
typedef TemplateBase = Template;
typedef TemplateBuilder = Template;
typedef TemplateClass = Template;

class Template {
  static Future<T> _run<T>(Future<T> Function(Templates resource) operation,
      ApiClient? client) async {
    final resolved = client ?? ApiClient(deferApiKeyValidation: true);
    try {
      return await operation(Templates(resolved));
    } finally {
      if (client == null) resolved.close();
    }
  }

  static Future<bool> exists(String name,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.exists(name, options: options), client);

  static Future<bool> aliasExists(String name,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.aliasExists(name, options: options), client);

  static Future<TemplateTagInfo> assignTags(String targetName, Object tags,
          {RequestOptions? options, ApiClient? client}) =>
      _run(
          (resource) => resource.assignTags(targetName, tags, options: options),
          client);

  static Future<void> removeTags(String name, Object tags,
          {RequestOptions? options, ApiClient? client}) =>
      _run((resource) => resource.removeTags(name, tags, options: options),
          client);

  static Future<List<TemplateTag>> getTags(String templateId,
          {RequestOptions? options, ApiClient? client}) =>
      _run(
          (resource) => resource.getTags(templateId, options: options), client);

  static Future<TemplateBuildStatusResponse> getBuildStatus(BuildInfo info,
          {num? logsOffset, RequestOptions? options, ApiClient? client}) =>
      _run(
          (resource) => resource.getBuildStatus(info,
              logsOffset: logsOffset, options: options),
          client);

  static Future<BuildInfo> build(Template template, String name,
          {List<String>? tags,
          num? cpuCount,
          num? memoryMB,
          num? minFreeDiskMb,
          bool skipCache = false,
          void Function(LogEntry)? onBuildLogs,
          RequestOptions? options,
          ApiClient? client,
          Duration pollInterval = const Duration(milliseconds: 200)}) =>
      _run(
          (resource) => resource.build(template, name,
              tags: tags,
              cpuCount: cpuCount,
              memoryMB: memoryMB,
              minFreeDiskMb: minFreeDiskMb,
              skipCache: skipCache,
              onBuildLogs: onBuildLogs,
              options: options,
              pollInterval: pollInterval),
          client);

  static Future<BuildInfo> buildInBackground(Template template, String name,
          {List<String>? tags,
          num? cpuCount,
          num? memoryMB,
          num? minFreeDiskMb,
          bool skipCache = false,
          void Function(LogEntry)? onBuildLogs,
          RequestOptions? options,
          ApiClient? client}) =>
      _run(
          (resource) => resource.buildInBackground(template, name,
              tags: tags,
              cpuCount: cpuCount,
              memoryMB: memoryMB,
              minFreeDiskMb: minFreeDiskMb,
              skipCache: skipCache,
              onBuildLogs: onBuildLogs,
              options: options),
          client);

  static Future<BuildInfo> buildWithOptions(
          Template template, BuildOptions options,
          {ApiClient? client}) =>
      _run((resource) => resource.buildWithOptions(template, options), client);

  static Future<BuildInfo> buildInBackgroundWithOptions(
          Template template, BuildOptions options, {ApiClient? client}) =>
      _run(
          (resource) =>
              resource.buildInBackgroundWithOptions(template, options),
          client);

  String? _baseImage = 'e2bdev/base';
  String? _baseTemplate;
  Map<String, dynamic>? _registry;
  String? _startCmd;
  String? _readyCmd;
  bool _force = false;
  bool _forceNext = false;
  final List<TemplateInstruction> _instructions = [];
  final String fileContextPath;
  final List<String> fileIgnorePatterns;
  Template({this.fileContextPath = '.', this.fileIgnorePatterns = const []});
  List<TemplateInstruction> get instructions =>
      List.unmodifiable(_instructions);
  Template fromImage(String image, {String? username, String? password}) {
    if ((username != null || password != null) &&
        (username == null ||
            username.isEmpty ||
            password == null ||
            password.isEmpty)) {
      throw const InvalidArgumentException(
          'Both username and password are required when providing registry credentials');
    }
    _baseImage = image;
    _baseTemplate = null;
    if (username != null) {
      _registry = {
        'type': 'registry',
        'username': username,
        'password': password
      };
    }
    if (_forceNext) _force = true;
    return this;
  }

  Template fromBaseImage() => fromImage('e2bdev/base');
  Template fromDebianImage([String variant = 'stable']) =>
      fromImage('debian:$variant');
  Template fromUbuntuImage([String variant = 'latest']) =>
      fromImage('ubuntu:$variant');
  Template fromFedoraImage([String variant = '44']) =>
      fromImage('fedora:$variant');
  Template fromAlpineImage([String variant = '3.24']) =>
      fromImage('alpine:$variant');
  Template fromArchImage([String variant = 'latest']) =>
      fromImage('archlinux:$variant');
  Template fromPythonImage([String version = '3']) =>
      fromImage('python:$version');
  Template fromNodeImage([String variant = 'lts']) =>
      fromImage('node:$variant');
  Template fromBunImage([String variant = 'latest']) =>
      fromImage('oven/bun:$variant');
  Template fromTemplate(String template) {
    _baseTemplate = template;
    _baseImage = null;
    if (_forceNext) _force = true;
    return this;
  }

  Template fromDockerfile(String contentOrPath) {
    final image =
        convertDockerfile(platform.readDockerfileContent(contentOrPath), this);
    return fromImage(image);
  }

  Template fromAWSRegistry(String image,
      {required String accessKeyId,
      required String secretAccessKey,
      required String region}) {
    fromImage(image);
    _registry = {
      'type': 'aws',
      'awsAccessKeyId': accessKeyId,
      'awsSecretAccessKey': secretAccessKey,
      'awsRegion': region
    };
    return this;
  }

  Template fromGCPRegistry(String image, {required Object serviceAccountJSON}) {
    _baseImage = image;
    _baseTemplate = null;
    final value = serviceAccountJSON is String
        ? platform.readTemplateFile(fileContextPath, serviceAccountJSON)
        : jsonEncode(serviceAccountJSON);
    _registry = {'type': 'gcp', 'serviceAccountJson': value};
    if (_forceNext) _force = true;
    return this;
  }

  Template _step(String type, List<String> args) {
    _instructions.add(TemplateInstruction(type, args, force: _forceNext));
    return this;
  }

  Template runCmd(Object commands, {String? user}) => _step('RUN', [
        _strings(commands).join(' && '),
        if (user != null && user.isNotEmpty) user
      ]);
  Template setWorkdir(String path) => _step('WORKDIR', [path]);
  Template setUser(String user) => _step('USER', [user]);
  Template setEnvs(Map<String, String> envs) => envs.isEmpty
      ? this
      : _step('ENV', envs.entries.expand((e) => [e.key, e.value]).toList());
  Template skipCache() {
    _forceNext = true;
    return this;
  }

  Template copy(Object sources, String dest,
      {bool? forceUpload,
      String? user,
      int? mode,
      bool? resolveSymlinks,
      bool? gzip}) {
    if (!platform.supportsLocalTemplateFiles) {
      throw const TemplateException(
          'Browser runtime is not supported for copy');
    }
    for (final src in _strings(sources)) {
      final normalized = p.normalize(src);
      if (p.isAbsolute(src) ||
          normalized == '..' ||
          normalized.startsWith('..${p.separator}')) {
        throw const TemplateException(
            'COPY source must be a relative path within the context');
      }
      _instructions.add(TemplateInstruction(
          'COPY',
          [
            src,
            dest,
            user ?? '',
            mode == null ? '' : mode.toRadixString(8).padLeft(4, '0')
          ],
          force: forceUpload == true || _forceNext,
          forceUpload: forceUpload,
          resolveSymlinks: resolveSymlinks,
          gzip: gzip));
    }
    return this;
  }

  Template copyItems(List<CopyItem> items) {
    if (!platform.supportsLocalTemplateFiles) {
      throw const TemplateException(
          'Browser runtime is not supported for copyItems');
    }
    for (final item in items) {
      copy(item.src, item.dest,
          forceUpload: item.forceUpload,
          user: item.user,
          mode: item.mode,
          resolveSymlinks: item.resolveSymlinks,
          gzip: item.gzip);
    }
    return this;
  }

  Template remove(Object paths,
          {bool recursive = false, bool force = false, String? user}) =>
      runCmd(
          [
            'rm',
            if (recursive) '-r',
            if (force) '-f',
            ..._strings(paths).map(shellQuote)
          ].join(' '),
          user: user);
  Template rename(String src, String dest,
          {bool force = false, String? user}) =>
      runCmd(
          ['mv', shellQuote(src), shellQuote(dest), if (force) '-f'].join(' '),
          user: user);
  Template makeDir(Object paths, {int? mode, String? user}) => runCmd(
      [
        'mkdir',
        '-p',
        if (mode != null) '-m ${mode.toRadixString(8).padLeft(4, '0')}',
        ..._strings(paths).map(shellQuote)
      ].join(' '),
      user: user);
  Template makeSymlink(String src, String dest,
          {bool force = false, String? user}) =>
      runCmd(
          ['ln', '-s', if (force) '-f', shellQuote(src), shellQuote(dest)]
              .join(' '),
          user: user);
  Template pipInstall([Object? packages, bool global = true]) => runCmd(
      [
        'pip',
        'install',
        if (!global) '--user',
        ...packages == null || packages == '' ? ['.'] : _strings(packages)
      ].join(' '),
      user: global ? 'root' : null);
  Template npmInstall(
          {Object? packages, bool global = false, bool dev = false}) =>
      runCmd(
          [
            'npm',
            'install',
            if (global) '-g',
            if (dev) '--save-dev',
            if (packages != null && packages != '') ..._strings(packages)
          ].join(' '),
          user: global ? 'root' : null);
  Template bunInstall(
          {Object? packages, bool global = false, bool dev = false}) =>
      runCmd(
          [
            'bun',
            'install',
            if (global) '-g',
            if (dev) '--dev',
            if (packages != null && packages != '') ..._strings(packages)
          ].join(' '),
          user: global ? 'root' : null);
  Template aptInstall(Object packages,
          {bool noInstallRecommends = false, bool fixMissing = false}) =>
      runCmd([
        'apt-get update',
        'DEBIAN_FRONTEND=noninteractive DEBCONF_NOWARNINGS=yes apt-get install -y ${noInstallRecommends ? '--no-install-recommends ' : ''}${fixMissing ? '--fix-missing ' : ''}${_strings(packages).join(' ')}'
      ], user: 'root');
  Template gitClone(String url,
          {String? path, String? branch, num? depth, String? user}) =>
      runCmd(
          [
            'git',
            'clone',
            shellQuote(url),
            if (branch != null && branch.isNotEmpty) ...[
              '--branch ${shellQuote(branch)}',
              '--single-branch'
            ],
            if (depth != null && depth != 0 && !depth.isNaN)
              '--depth ${jsNumberString(depth)}',
            if (path != null && path.isNotEmpty) shellQuote(path)
          ].join(' '),
          user: user);
  Template addMcpServer(Object servers) {
    if (_baseTemplate != 'mcp-gateway') {
      throw const BuildException(
          'MCP servers can only be added to mcp-gateway template');
    }
    String name(Object value) =>
        value is McpServerName ? value.name : value as String;
    final names = servers is Iterable
        ? servers.map((value) => name(value as Object)).toList()
        : [name(servers)];
    return runCmd('mcp-gateway pull ${names.join(' ')}', user: 'root');
  }

  Template setStartCmd(String start, Object ready) {
    _startCmd = start;
    return setReadyCmd(ready);
  }

  Template setReadyCmd(Object ready) {
    _readyCmd = ready is ReadyCmd ? ready.getCmd() : ready as String;
    return this;
  }

  Template betaDevContainerPrebuild(String directory) {
    _requireDevContainer();
    return runCmd(
        'devcontainer build --workspace-folder ${shellQuote(directory)}',
        user: 'root');
  }

  Template betaSetDevContainerStart(String directory) {
    _requireDevContainer();
    final dir = shellQuote(directory);
    return setStartCmd(
        'sudo devcontainer up --workspace-folder $dir && sudo /prepare-exec.sh $dir | sudo tee /devcontainer.sh > /dev/null && sudo chmod +x /devcontainer.sh && sudo touch /devcontainer.up',
        waitForFile('/devcontainer.up'));
  }

  void _requireDevContainer() {
    if (_baseTemplate != 'devcontainer') {
      throw const BuildException(
          'Devcontainers can only used in the devcontainer template');
    }
  }

  Map<String, dynamic> toJson() => {
        if (_startCmd != null) 'startCmd': _startCmd,
        if (_readyCmd != null) 'readyCmd': _readyCmd,
        'steps': _instructions.map((s) => s.toJson()).toList(),
        'force': _force,
        if (_baseImage != null) 'fromImage': _baseImage,
        if (_baseTemplate != null) 'fromTemplate': _baseTemplate,
        if (_registry != null) 'fromImageRegistry': Map.of(_registry!)
      };
  static Future<String> toJSON(Template template,
      {bool computeHashes = true}) async {
    final data = template.toJson();
    if (computeHashes) {
      data['steps'] =
          await Future.wait(template.instructions.map((step) async => {
                ...step.toJson(),
                if (step.type == 'COPY')
                  'filesHash': await template_files.calculateTemplateFilesHash(
                      template.fileContextPath,
                      step.args[0],
                      step.args[1],
                      [
                        ...template_files
                            .readDockerignore(template.fileContextPath),
                        ...template.fileIgnorePatterns,
                      ],
                      step.resolveSymlinks ?? false),
              }));
    }
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  static String toDockerfile(Template template) {
    if (template._baseTemplate != null) {
      throw const E2BException(
          'Cannot convert template built from another template to Dockerfile. '
          'Templates based on other templates can only be built using the E2B API.');
    }
    if (template._baseImage == null) {
      throw const E2BException('No base image specified for template');
    }
    final result = StringBuffer('FROM ${template._baseImage}\n');
    for (final step in template._instructions) {
      final args = switch (step.type) {
        'RUN' => step.args.first,
        'COPY' => step.args.take(2).join(' '),
        'ENV' => [
            for (var i = 0; i < step.args.length; i += 2)
              '${step.args[i]}=${step.args[i + 1]}'
          ].join(' '),
        _ => step.args.join(' '),
      };
      result.writeln('${step.type} $args');
    }
    if (template._startCmd != null && template._startCmd!.isNotEmpty) {
      result.writeln('ENTRYPOINT ${template._startCmd}');
    }
    return result.toString();
  }
}

final _buildAnsiPattern = RegExp(
  r'(?:\u001B[\]PX^_][\s\S]*?(?:\u0007|\u001B\u005C|\u009C))'
  r'|[\u001B\u009B][[\]()#;?]*(?:\d{1,4}(?:[;:]\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]',
);

typedef LogEntryLevel = String;

class LogEntry {
  final DateTime timestamp;
  final LogEntryLevel level;
  final String message;
  LogEntry(DateTime timestamp, this.level, String message)
      : timestamp = DateTime.fromMillisecondsSinceEpoch(
            timestamp.millisecondsSinceEpoch,
            isUtc: true),
        message = message.replaceAll(_buildAnsiPattern, '');
  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
      DateTime.parse(json['timestamp'] as String),
      json['level'] as String,
      json['message'] as String);
  @override
  String toString() =>
      '[${DateTime.fromMillisecondsSinceEpoch(timestamp.millisecondsSinceEpoch, isUtc: true).toIso8601String()}] [$level] $message';
}

class LogEntryStart extends LogEntry {
  LogEntryStart(DateTime timestamp, String message)
      : super(timestamp, 'debug', message);
}

class LogEntryEnd extends LogEntry {
  LogEntryEnd(DateTime timestamp, String message)
      : super(timestamp, 'debug', message);
}

class BuildInfo {
  final String name;
  String get alias => name;
  final String templateId;
  final String buildId;
  final List<String> tags;
  BuildInfo(
      {required this.name,
      required this.templateId,
      required this.buildId,
      List<String> tags = const []})
      : tags = List.unmodifiable(tags);
}

/// Structured counterpart of the official legacy build options overload.
class BuildOptions {
  final String alias;
  final List<String>? tags;
  final num? cpuCount;
  final num? memoryMB;
  final num? minFreeDiskMb;
  final bool skipCache;
  final void Function(LogEntry)? onBuildLogs;
  final RequestOptions? connection;
  const BuildOptions(
      {required this.alias,
      this.tags,
      this.cpuCount,
      this.memoryMB,
      this.minFreeDiskMb,
      this.skipCache = false,
      this.onBuildLogs,
      this.connection});
}

class BuildStatusReason {
  final String message;
  final String? step;
  final List<LogEntry> logEntries;
  BuildStatusReason(Map<String, dynamic> json)
      : message = json['message'] as String,
        step = json['step'] as String?,
        logEntries = (json['logEntries'] as List? ?? [])
            .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
            .toList();
}

/// Build state: building, waiting, ready, or error.
/// Dart strings preserve the official wire representation.
typedef TemplateBuildStatus = String;

class TemplateBuildStatusResponse {
  final String templateId;
  final String buildId;
  String get templateID => templateId;
  String get buildID => buildId;
  final TemplateBuildStatus status;
  final List<LogEntry> logEntries;
  final List<String> logs;
  final BuildStatusReason? reason;
  TemplateBuildStatusResponse(Map<String, dynamic> json)
      : templateId = json['templateID'] as String,
        buildId = json['buildID'] as String,
        status = json['status'] as String,
        logEntries = (json['logEntries'] as List? ?? [])
            .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        logs = (json['logs'] as List? ?? []).cast<String>(),
        reason = json['reason'] == null
            ? null
            : BuildStatusReason(json['reason'] as Map<String, dynamic>);
}

class TemplateTagInfo {
  final String buildId;
  final List<String> tags;
  TemplateTagInfo(Map<String, dynamic> data)
      : buildId = data['buildID'] as String,
        tags = (data['tags'] as List).cast<String>();
}

class TemplateTag {
  final String tag;
  final String buildId;
  final DateTime createdAt;
  TemplateTag(Map<String, dynamic> data)
      : tag = data['tag'] as String,
        buildId = data['buildID'] as String,
        createdAt = parseApiDate(data['createdAt'] as String);
}

/// Client-bound template build and tag management API.
class Templates {
  final ApiClient _client;
  Templates(this._client);

  Future<String> toJSON(Template template, {bool computeHashes = true}) =>
      Template.toJSON(template, computeHashes: computeHashes);

  String toDockerfile(Template template) => Template.toDockerfile(template);

  /// Create a builder through a client-bound template resource.
  Template call(
          {String fileContextPath = '.',
          List<String> fileIgnorePatterns = const []}) =>
      Template(
          fileContextPath: fileContextPath,
          fileIgnorePatterns: fileIgnorePatterns);

  /// Dart adapter for `Template.build(template, {alias, ...options})`.
  Future<BuildInfo> buildWithOptions(Template template, BuildOptions options,
          {Duration pollInterval = const Duration(milliseconds: 200)}) =>
      build(template, options.alias,
          tags: options.tags,
          cpuCount: options.cpuCount,
          memoryMB: options.memoryMB,
          minFreeDiskMb: options.minFreeDiskMb,
          skipCache: options.skipCache,
          onBuildLogs: options.onBuildLogs,
          options: options.connection,
          pollInterval: pollInterval);

  /// Dart adapter for the legacy background build options overload.
  Future<BuildInfo> buildInBackgroundWithOptions(
          Template template, BuildOptions options) =>
      buildInBackground(template, options.alias,
          tags: options.tags,
          cpuCount: options.cpuCount,
          memoryMB: options.memoryMB,
          minFreeDiskMb: options.minFreeDiskMb,
          skipCache: options.skipCache,
          onBuildLogs: options.onBuildLogs,
          options: options.connection);

  Future<Object?> _request(String method, String path,
      {Map<String, dynamic>? body,
      Map<String, String>? query,
      RequestOptions? options,
      String errorKind = 'template'}) async {
    try {
      return await _client.request(method, path,
          body: body, query: query, options: options);
    } on E2BException catch (error) {
      final status = error.statusCode;
      if (status == null || status == 401 || status == 429 || status == 503) {
        rethrow;
      }
      final message = '$status: ${error.message}';
      switch (errorKind) {
        case 'build':
          throw BuildException(message, statusCode: status, code: error.code);
        case 'upload':
          throw FileUploadException(message,
              statusCode: status, code: error.code);
        default:
          throw TemplateException(message,
              statusCode: status, code: error.code);
      }
    }
  }

  Template create(
          {String fileContextPath = '.',
          List<String> fileIgnorePatterns = const []}) =>
      Template(
          fileContextPath: fileContextPath,
          fileIgnorePatterns: fileIgnorePatterns);
  Future<bool> exists(String name, {RequestOptions? options}) async {
    try {
      return await _request(
              'GET', '/templates/aliases/${Uri.encodeComponent(name)}',
              options: options) !=
          null;
    } on E2BException catch (e) {
      if (e.statusCode == 403) return true;
      if (e.statusCode == 404) return false;
      rethrow;
    }
  }

  Future<bool> aliasExists(String name, {RequestOptions? options}) =>
      exists(name, options: options);
  Future<TemplateTagInfo> assignTags(String targetName, Object tags,
          {RequestOptions? options}) async =>
      TemplateTagInfo(await _request('POST', '/templates/tags',
          body: {'target': targetName, 'tags': _strings(tags)},
          options: options) as Map<String, dynamic>);
  Future<void> removeTags(String name, Object tags,
      {RequestOptions? options}) async {
    await _request('DELETE', '/templates/tags',
        body: {'name': name, 'tags': _strings(tags)}, options: options);
  }

  Future<List<TemplateTag>> getTags(String templateId,
          {RequestOptions? options}) async =>
      (await _request(
              'GET', '/templates/${Uri.encodeComponent(templateId)}/tags',
              options: options) as List)
          .map((e) => TemplateTag(e as Map<String, dynamic>))
          .toList();
  Future<TemplateBuildStatusResponse> getBuildStatus(BuildInfo data,
      {num? logsOffset, RequestOptions? options}) async {
    final result = await _request('GET',
        '/templates/${Uri.encodeComponent(data.templateId)}/builds/${Uri.encodeComponent(data.buildId)}/status',
        query: {
          if (logsOffset != null) 'logsOffset': jsNumberString(logsOffset)
        },
        options: options,
        errorKind: 'build');
    if (result == null) {
      throw const BuildException('Failed to get build status');
    }
    return TemplateBuildStatusResponse(result as Map<String, dynamic>);
  }

  Future<BuildInfo> buildInBackground(Template template, String name,
      {List<String>? tags,
      num? cpuCount,
      num? memoryMB,
      num? minFreeDiskMb,
      bool skipCache = false,
      void Function(LogEntry)? onBuildLogs,
      RequestOptions? options}) async {
    if (name.isEmpty) throw const TemplateException('Name must be provided');
    if (skipCache) template._force = true;
    onBuildLogs?.call(LogEntry(DateTime.now(), 'info',
        'Requesting build for template: $name${tags != null && tags.isNotEmpty ? ' with tags ${tags.join(', ')}' : ''}'));
    final rawRequest = await _request('POST', '/v3/templates',
        body: {
          'name': name,
          if (tags != null) 'tags': tags,
          if (cpuCount != null) 'cpuCount': cpuCount.isFinite ? cpuCount : null,
          if (memoryMB != null) 'memoryMB': memoryMB.isFinite ? memoryMB : null,
          if (minFreeDiskMb != null)
            'minFreeDiskMb': minFreeDiskMb.isFinite ? minFreeDiskMb : null
        },
        options: options,
        errorKind: 'build');
    if (rawRequest == null) {
      throw const BuildException('Failed to request build');
    }
    final request = rawRequest as Map<String, dynamic>;
    final info = BuildInfo(
        name: name,
        templateId: request['templateID'] as String,
        buildId: request['buildID'] as String,
        tags: (request['tags'] as List? ?? []).cast<String>());
    onBuildLogs?.call(LogEntry(DateTime.now(), 'info',
        'Template created with ID: ${info.templateId}, Build ID: ${info.buildId}'));
    final data =
        jsonDecode(await Template.toJSON(template)) as Map<String, dynamic>;
    final steps = (data['steps'] as List).cast<Map<String, dynamic>>();
    final patterns = [
      ...template_files.readDockerignore(template.fileContextPath),
      ...template.fileIgnorePatterns
    ];
    await Future.wait(steps.where((s) => s['type'] == 'COPY').map((step) async {
      final src = (step['args'] as List)[0] as String;
      final hash = step['filesHash'] as String;
      final rawLink = await _request('GET',
          '/templates/${Uri.encodeComponent(info.templateId)}/files/$hash',
          options: options, errorKind: 'upload');
      if (rawLink == null) {
        throw const FileUploadException('Failed to get file upload link');
      }
      final link = rawLink as Map<String, dynamic>;
      if ((step['forceUpload'] == true || link['present'] == false) &&
          link['url'] != null) {
        await template_files.uploadTemplateFiles(
            _client.httpClient,
            Uri.parse(link['url'] as String),
            Map<String, String>.from(link['headers'] as Map? ?? {}),
            template.fileContextPath,
            src,
            patterns,
            step['resolveSymlinks'] as bool? ?? false,
            step['gzip'] as bool? ?? true,
            options);
        onBuildLogs?.call(LogEntry(DateTime.now(), 'info', "Uploaded '$src'"));
      } else {
        onBuildLogs?.call(LogEntry(DateTime.now(), 'info',
            "Skipping upload of '$src', already cached"));
      }
    }));
    onBuildLogs
        ?.call(LogEntry(DateTime.now(), 'info', 'All file uploads completed'));
    onBuildLogs?.call(LogEntry(DateTime.now(), 'info', 'Starting building...'));
    await _request('POST',
        '/v2/templates/${Uri.encodeComponent(info.templateId)}/builds/${Uri.encodeComponent(info.buildId)}',
        body: data, options: options, errorKind: 'build');
    return info;
  }

  Future<BuildInfo> build(Template template, String name,
      {List<String>? tags,
      num? cpuCount,
      num? memoryMB,
      num? minFreeDiskMb,
      bool skipCache = false,
      void Function(LogEntry)? onBuildLogs,
      RequestOptions? options,
      Duration pollInterval = const Duration(milliseconds: 200)}) async {
    if (name.isEmpty) throw const TemplateException('Name must be provided');
    try {
      onBuildLogs?.call(LogEntryStart(DateTime.now(), 'Build started'));
      final info = await buildInBackground(template, name,
          tags: tags,
          cpuCount: cpuCount,
          memoryMB: memoryMB,
          minFreeDiskMb: minFreeDiskMb,
          skipCache: skipCache,
          onBuildLogs: onBuildLogs,
          options: options);
      onBuildLogs
          ?.call(LogEntry(DateTime.now(), 'info', 'Waiting for logs...'));
      var offset = 0;
      Future<TemplateBuildStatusResponse> poll() async {
        final status =
            await getBuildStatus(info, logsOffset: offset, options: options);
        offset += status.logEntries.length;
        for (final entry in status.logEntries) {
          onBuildLogs?.call(entry);
        }
        return status;
      }

      while (true) {
        options?.signal?.throwIfCanceled();
        final status = await poll();
        if (status.status == 'ready' || status.status == 'error') {
          var tail = status;
          while (tail.logEntries.isNotEmpty) {
            options?.signal?.throwIfCanceled();
            tail = await poll();
          }
          if (status.status == 'error') {
            throw BuildException(status.reason?.message ?? 'Unknown error',
                step: status.reason?.step);
          }
          return info;
        }
        if (status.status != 'building' && status.status != 'waiting') {
          throw const BuildException('Unknown build error occurred');
        }
        await cancellableDelay(pollInterval, options?.signal);
      }
    } finally {
      onBuildLogs?.call(LogEntryEnd(DateTime.now(), 'Build finished'));
    }
  }
}
