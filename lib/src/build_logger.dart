import 'dart:async';

import 'build_log_output_stub.dart'
    if (dart.library.io) 'build_log_output_io.dart' as output;
import 'template.dart';

/// Creates the standard build logger, with a timer on interactive terminals.
///
/// [write], [isTerminal], [useColor], [now] and [formatTimestamp] allow Flutter
/// applications to route output and customize presentation for their host.
/// Send [LogEntryEnd] to stop the terminal timer when using this independently.
void Function(LogEntry) defaultBuildLogger({
  String minLevel = 'info',
  void Function(String)? write,
  bool? isTerminal,
  bool? useColor,
  DateTime Function()? now,
  String Function(DateTime)? formatTimestamp,
}) {
  const order = {'debug': 0, 'info': 1, 'warn': 2, 'error': 3};
  if (!order.containsKey(minLevel)) {
    throw ArgumentError.value(minLevel, 'minLevel', 'Unknown log level');
  }
  final clock = now ?? DateTime.now;
  final emit = write ?? output.writeBuildLog;
  final terminal = isTerminal ?? output.buildLogIsTerminal;
  final color = useColor ?? output.buildLogSupportsAnsi;
  final timestamp = formatTimestamp ??
      (DateTime time) {
        final local = time.toLocal();
        String two(int value) => value.toString().padLeft(2, '0');
        return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
      };
  var start = clock();
  var frame = 0;
  Timer? timer;
  String elapsed() =>
      '${(clock().difference(start).inMilliseconds / 1000).toStringAsFixed(1)}s';
  void update() {
    if (!terminal) return;
    const frames = ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'];
    frame++;
    emit('${frames[frame % frames.length]} Building ${elapsed()}\r');
  }

  String paint(String value, String code) =>
      color ? '\x1b[${code}m$value\x1b[0m' : value;
  return (entry) {
    if (entry is LogEntryStart) {
      if (terminal) {
        // Dispose any previous timer if this logger is reused for another build.
        timer?.cancel();
        timer =
            Timer.periodic(const Duration(milliseconds: 150), (_) => update());
        start = clock();
        frame = 0;
        update();
      }
      return;
    }
    if (entry is LogEntryEnd) {
      timer?.cancel();
      timer = null;
      return;
    }
    if ((order[entry.level] ?? order['info']!) < order[minLevel]!) return;
    final label = switch (entry.level) {
      'error' => paint('ERROR', '31'),
      'warn' => paint('WARN ', '38;2;255;68;0'),
      'debug' => paint('DEBUG', '90'),
      _ => paint('INFO ', '38;2;255;136;0'),
    };
    emit(
        '${elapsed().padRight(5)} | ${paint(timestamp(entry.timestamp), '2')} $label ${entry.message}\n');
    update();
  };
}
