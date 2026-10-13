import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('Git string union adapters serialize official values', () {
    expect(jsonEncode(GitConfigScope.values), '["global","local","system"]');
    expect(jsonEncode(GitStatusLabel.values),
        '["conflict","renamed","copied","deleted","added","modified","typechange","untracked","unknown"]');
    final GitResetMode mode = 'mixed';
    expect(mode, 'mixed');
  });

  test('volume type retains unknown server strings instead of collapsing them',
      () {
    final entry = VolumeEntryStat({'type': 'socket'});
    expect(entry.type.value, 'socket');
    expect(jsonEncode(entry.type), '"socket"');
    expect(entry.type, const VolumeFileType('socket'));
    expect(entry.type, isNot(VolumeFileType.unknown));
    expect(VolumeFileType.fromValue('file'), same(VolumeFileType.file));
    expect({entry.type, const VolumeFileType('socket')}, hasLength(1));
  });

  test('entry unknown or omitted type maps to absent SDK type', () {
    for (final raw in [null, 0, 'FILE_TYPE_UNSPECIFIED', 'future-type']) {
      final WriteInfo entry = EntryInfo({'type': raw});
      expect(entry.type, isNull);
    }
    expect(EntryInfo({'isSymlink': true}).type, FileType.symlink);
    expect(EntryInfo({'type': 'FILE_TYPE_DIRECTORY'}).type, FileType.directory);
  });

  test('filesystem events expose mapped SDK types instead of protobuf values',
      () {
    final cases = {
      'EVENT_TYPE_CREATE': FilesystemEventType.create,
      'EVENT_TYPE_WRITE': FilesystemEventType.write,
      'EVENT_TYPE_REMOVE': FilesystemEventType.remove,
      'EVENT_TYPE_RENAME': FilesystemEventType.rename,
      'EVENT_TYPE_CHMOD': FilesystemEventType.chmod,
    };
    var number = 1;
    for (final pair in cases.entries) {
      for (final input in [pair.key, number, pair.value.value]) {
        final event = FilesystemEvent({'type': input, 'name': 'a'});
        expect(event.type, pair.value);
        expect(event.eventType, pair.value);
        expect(event.rawType, input.toString());
      }
      number++;
    }
    final unknown = FilesystemEvent({'type': 'EVENT_TYPE_UNSPECIFIED'});
    expect(unknown.type, isNull);
    expect(unknown.eventType, FilesystemEventType.unknown);
  });

  test('filesystem enum JSON values match official string constants', () {
    expect(jsonEncode([FileType.file, FileType.directory, FileType.symlink]),
        '["file","dir","symlink"]');
    expect(FileType.directory.value, 'dir');
    expect(
        jsonEncode([
          FilesystemEventType.chmod,
          FilesystemEventType.create,
          FilesystemEventType.remove,
          FilesystemEventType.rename,
          FilesystemEventType.write,
        ]),
        '["chmod","create","remove","rename","write"]');
  });
  test('volume directory value is distinct from sandbox dir', () {
    expect(jsonEncode(VolumeFileType.values),
        '["unknown","file","directory","symlink"]');
    expect(VolumeFileType.directory.value, 'directory');
  });
}
