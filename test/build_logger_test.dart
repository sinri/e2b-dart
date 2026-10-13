import 'package:e2b/e2b.dart';
import 'package:test/test.dart';

void main() {
  test('build log timestamp field matches JS Date precision', () {
    final time = DateTime.parse('2026-10-12T08:00:00.123456+08:00');
    final entries = [
      LogEntry(time, 'info', 'text'),
      LogEntryStart(time, 'start'),
      LogEntryEnd(time, 'end')
    ];
    for (final entry in entries) {
      expect(entry.timestamp.toIso8601String(), '2026-10-12T00:00:00.123Z');
    }
    expect(entries[1].level, 'debug');
    expect(entries[2].level, 'debug');
  });

  test('nonterminal logger filters levels and preserves elapsed build format',
      () {
    final lines = <String>[];
    var time = DateTime.utc(2026);
    final logger = defaultBuildLogger(
      write: lines.add,
      isTerminal: false,
      useColor: false,
      now: () => time,
      formatTimestamp: (_) => '12:34:56',
    );
    logger(LogEntryStart(time, 'hidden start'));
    time = time.add(const Duration(milliseconds: 1200));
    logger(LogEntry(time, 'debug', 'hidden'));
    logger(LogEntry(time, 'info', '\x1b[31mhello\x1b[0m'));
    logger(LogEntry(time, 'warn', 'warning'));
    logger(LogEntry(time, 'error', 'failure'));
    logger(LogEntryEnd(time, 'hidden end'));
    expect(lines, [
      '1.2s  | 12:34:56 INFO  hello\n',
      '1.2s  | 12:34:56 WARN  warning\n',
      '1.2s  | 12:34:56 ERROR failure\n',
    ]);
  });

  test('terminal logger animates and stops on end even above debug level',
      () async {
    final lines = <String>[];
    final time = DateTime.utc(2026);
    final logger = defaultBuildLogger(
      minLevel: 'error',
      write: lines.add,
      isTerminal: true,
      useColor: false,
      now: () => time,
    );
    logger(LogEntryStart(time, 'start'));
    expect(lines.single, '⣽ Building 0.0s\r');
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(lines.length, greaterThan(1));
    logger(LogEntryEnd(time, 'end'));
    final count = lines.length;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(lines.length, count);
  });

  test('debug threshold and optional color output', () {
    final lines = <String>[];
    final time = DateTime.utc(2026);
    final logger = defaultBuildLogger(
      minLevel: 'debug',
      write: lines.add,
      isTerminal: false,
      useColor: true,
      now: () => time,
      formatTimestamp: (_) => '00:00:00',
    );
    logger(LogEntry(time, 'debug', 'trace'));
    expect(lines.single,
        '0.0s  | \x1b[2m00:00:00\x1b[0m \x1b[90mDEBUG\x1b[0m trace\n');
    expect(() => defaultBuildLogger(minLevel: 'invalid'), throwsArgumentError);
  });
}
