import 'dart:typed_data';
import 'api_date.dart';

/// Output aliases corresponding to the JS SDK's branded primitive types.
typedef Stdout = String;
typedef Stderr = String;
typedef PtyOutput = Uint8List;

/// Official string unions; aliases retain forward-compatible wire values.
typedef SandboxState = String;
typedef SandboxListOrder = String;

/// JSON-shaped sandbox response types. Optional wire fields remain nullable
/// when accessed through the map; egress proxy passwords are never projected.
typedef SandboxNetworkRuleInfo = Map<String, dynamic>;
typedef SandboxEgressProxyInfo = Map<String, dynamic>;
typedef SandboxNetworkInfo = Map<String, dynamic>;
typedef SandboxInfoLifecycle = Map<String, dynamic>;

/// Sandbox metadata. The original response is retained for forward compatibility.
class SandboxInfo {
  final Map<String, dynamic> raw;
  SandboxInfo(Map<String, dynamic> json) : raw = Map.unmodifiable(json);
  String get sandboxId => raw['sandboxID'] as String;
  String? get name => raw['alias'] == '' ? null : raw['alias'] as String?;
  String? get sandboxDomain =>
      raw['domain'] == '' ? null : raw['domain'] as String?;
  int? get cpuCount => raw['cpuCount'] as int?;
  int? get memoryMB => raw['memoryMB'] as int?;
  bool? get allowInternetAccess => raw['allowInternetAccess'] as bool?;
  SandboxNetworkInfo? get network {
    final value = raw['network'] as Map<String, dynamic>?;
    if (value == null) return null;
    final proxy = value['egressProxy'] as Map<String, dynamic>?;
    return {
      for (final key in [
        'allowOut',
        'denyOut',
        'rules',
        'allowPublicTraffic',
        'maskRequestHost',
        'httpsPorts'
      ])
        key: value[key],
      if (proxy != null)
        'egressProxy': {
          'address': proxy['address'],
          if (proxy['username'] != null) 'username': proxy['username']
        }
    };
  }

  SandboxInfoLifecycle? get lifecycle {
    final value = raw['lifecycle'] as Map<String, dynamic>?;
    return value == null
        ? null
        : {'onTimeout': value['onTimeout'], 'autoResume': value['autoResume']};
  }

  List<Map<String, dynamic>> get volumeMounts =>
      (raw['volumeMounts'] as List? ?? []).cast<Map<String, dynamic>>();
  String? get templateId => raw['templateID'] as String?;
  SandboxState? get state => raw['state'] as String?;
  String? get envdVersion => raw['envdVersion'] as String?;
  DateTime? get startedAt => tryParseApiDate(raw['startedAt']?.toString());
  DateTime? get endAt => tryParseApiDate(raw['endAt']?.toString());
  Map<String, String> get metadata =>
      Map<String, String>.from(raw['metadata'] as Map? ?? {});
}

class SandboxPage {
  final List<SandboxInfo> items;
  final String? nextToken;
  bool get hasNext => nextToken != null && nextToken!.isNotEmpty;
  SandboxPage(this.items, this.nextToken);
}

enum FileType {
  unknown('unknown'),
  file('file'),
  directory('dir'),
  symlink('symlink');

  final String value;
  const FileType(this.value);
  String toJson() => value;
}

/// Common result fields for filesystem uploads and filesystem entries.
abstract interface class WriteInfo {
  String get name;
  String get path;
  FileType? get type;
  Map<String, String>? get metadata;
}

class EntryInfo implements WriteInfo {
  final Map<String, dynamic> raw;
  EntryInfo(Map<String, dynamic> json) : raw = Map.unmodifiable(json);
  @override
  String get name => raw['name'] as String? ?? '';
  @override
  String get path => raw['path'] as String? ?? '';
  int get size => int.parse('${raw['size'] ?? 0}');
  int get mode => raw['mode'] as int? ?? 0;
  String get permissions => raw['permissions'] as String? ?? '';
  String get owner => raw['owner'] as String? ?? '';
  String get group => raw['group'] as String? ?? '';
  DateTime? get modifiedTime {
    final value = raw['modifiedTime'];
    if (value == null) return null;
    if (value is Map) {
      final seconds = int.parse('${value['seconds'] ?? 0}');
      final nanos = value['nanos'] as int? ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000 + (nanos / 1000000).floor(),
          isUtc: true);
    }
    final parsed = DateTime.tryParse(value.toString());
    return parsed == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(parsed.millisecondsSinceEpoch,
            isUtc: true);
  }

  String? get symlinkTarget => raw['symlinkTarget'] as String?;
  bool get isSymlink => raw['isSymlink'] == true;
  @override
  Map<String, String>? get metadata {
    final values = raw['metadata'] as Map?;
    return values == null || values.isEmpty
        ? null
        : Map<String, String>.unmodifiable(Map<String, String>.from(values));
  }

  @override
  FileType? get type => isSymlink
      ? FileType.symlink
      : switch (raw['type']) {
          'FILE_TYPE_FILE' || 'file' || 1 => FileType.file,
          'FILE_TYPE_DIRECTORY' ||
          'directory' ||
          'dir' ||
          2 =>
            FileType.directory,
          'FILE_TYPE_SYMLINK' || 'symlink' || 3 => FileType.symlink,
          _ => null,
        };
}

/// A running command, PTY session, or template start command.
class ProcessInfo {
  final int pid;
  final String? tag;
  final String cmd;
  final List<String> args;
  final Map<String, String> envs;
  final String? cwd;

  ProcessInfo(
      {required this.pid,
      this.tag,
      required this.cmd,
      List<String> args = const [],
      Map<String, String> envs = const {},
      this.cwd})
      : args = List.unmodifiable(args),
        envs = Map.unmodifiable(envs);

  factory ProcessInfo.fromJson(Map<String, dynamic> json) {
    final config = json['config'] as Map<String, dynamic>;
    final tag = json['tag'] as String?;
    final cwd = config['cwd'] as String?;
    return ProcessInfo(
      pid: json['pid'] as int,
      tag: tag == null || tag.isEmpty ? null : tag,
      cmd: config['cmd'] as String? ?? '',
      args: (config['args'] as List? ?? []).cast<String>(),
      envs: Map<String, String>.from(config['envs'] as Map? ?? {}),
      cwd: cwd == null || cwd.isEmpty ? null : cwd,
    );
  }
}

class CommandResult {
  /// Dart extension; absent when constructing a result from official fields.
  final int? pid;
  final int exitCode;
  final String stdout;
  final String stderr;
  final String? error;
  const CommandResult(
      {this.pid,
      required this.exitCode,
      required this.stdout,
      required this.stderr,
      this.error});
}

enum FilesystemEventType {
  unknown('unknown'),
  create('create'),
  write('write'),
  remove('remove'),
  rename('rename'),
  chmod('chmod');

  final String value;
  const FilesystemEventType(this.value);
  String toJson() => value;
}

class FilesystemEvent {
  final String name;

  /// Raw envd type retained for protocol diagnostics.
  final String rawType;
  final FilesystemEventType? type;
  final EntryInfo? entry;
  FilesystemEventType get eventType => type ?? FilesystemEventType.unknown;
  static FilesystemEventType? _mapType(Object? value) =>
      switch (value?.toString()) {
        'EVENT_TYPE_CREATE' || 'create' || '1' => FilesystemEventType.create,
        'EVENT_TYPE_WRITE' || 'write' || '2' => FilesystemEventType.write,
        'EVENT_TYPE_REMOVE' || 'remove' || '3' => FilesystemEventType.remove,
        'EVENT_TYPE_RENAME' || 'rename' || '4' => FilesystemEventType.rename,
        'EVENT_TYPE_CHMOD' || 'chmod' || '5' => FilesystemEventType.chmod,
        _ => null,
      };
  FilesystemEvent(Map<String, dynamic> json)
      : name = json['name'] as String? ?? '',
        rawType = json['type']?.toString() ?? 'EVENT_TYPE_UNSPECIFIED',
        type = _mapType(json['type']),
        entry = json['entry'] is Map<String, dynamic>
            ? EntryInfo(json['entry'] as Map<String, dynamic>)
            : null;
}

class SnapshotInfo {
  final String snapshotId;
  final List<String> names;
  SnapshotInfo(Map<String, dynamic> data)
      : snapshotId = data['snapshotID'] as String,
        names =
            List.unmodifiable((data['names'] as List? ?? []).cast<String>());
}

class SandboxMetrics {
  final DateTime timestamp;
  final num cpuUsedPct;
  final int cpuCount;
  final int memUsed;
  final int memTotal;
  final int memCache;
  final int diskUsed;
  final int diskTotal;
  SandboxMetrics(Map<String, dynamic> data)
      : timestamp = parseApiDate(data['timestamp'] as String),
        cpuUsedPct = data['cpuUsedPct'] as num,
        cpuCount = data['cpuCount'] as int,
        memUsed = data['memUsed'] as int,
        memTotal = data['memTotal'] as int,
        memCache = data['memCache'] as int? ?? 0,
        diskUsed = data['diskUsed'] as int,
        diskTotal = data['diskTotal'] as int;
}
