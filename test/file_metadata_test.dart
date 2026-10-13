import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('entry info implements upload result and normalizes optional metadata',
      () {
    final WriteInfo empty =
        EntryInfo({'name': 'a', 'path': '/a', 'metadata': {}});
    expect(empty.name, 'a');
    expect(empty.path, '/a');
    expect(empty.metadata, isNull);
    expect(EntryInfo({}).metadata, isNull);
    final entry = EntryInfo({
      'metadata': {'key': 'value'}
    });
    expect(entry.metadata, {'key': 'value'});
    expect(() => entry.metadata!['key'] = 'changed', throwsUnsupportedError);
  });

  test('modified timestamps match JS millisecond precision', () {
    final string =
        EntryInfo({'modifiedTime': '2026-01-02T03:04:05.123456789Z'});
    expect(string.modifiedTime, DateTime.utc(2026, 1, 2, 3, 4, 5, 123));
    final protobuf = EntryInfo({
      'modifiedTime': {'seconds': '1', 'nanos': 999999999}
    });
    expect(protobuf.modifiedTime!.millisecondsSinceEpoch, 1999);
    expect(EntryInfo({}).modifiedTime, isNull);
  });

  test('symlink flags override target type and retain older envd enum', () {
    expect(EntryInfo({'type': 'FILE_TYPE_DIRECTORY', 'isSymlink': true}).type,
        FileType.symlink);
    expect(EntryInfo({'type': 'FILE_TYPE_SYMLINK'}).type, FileType.symlink);
    expect(EntryInfo({'type': 'FILE_TYPE_DIRECTORY'}).type, FileType.directory);
  });
}
