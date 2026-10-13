import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';

/// Creates one short-lived sandbox. Run explicitly with E2B_API_KEY configured.
Future<void> main() async {
  final key = Platform.environment['E2B_API_KEY'];
  if (key == null || key.isEmpty) {
    stdout.writeln(jsonEncode({
      'status': 'not_run',
      'reason': 'E2B_API_KEY is not configured',
      'checks': <String>[],
    }));
    exitCode = 78;
    return;
  }
  final checks = <String>[];
  final failures = <String>[];
  final client = E2BClient(apiKey: key);
  Sandbox? sandbox;
  Future<void> check(String name, Future<void> Function() action) async {
    try {
      await action();
      checks.add(name);
    } catch (error) {
      failures.add('$name: ${error.runtimeType}');
      rethrow;
    }
  }

  try {
    await check('create', () async {
      sandbox = await client.create(
          timeout: const Duration(minutes: 2),
          metadata: {'sdk-test': 'dart-cloud-smoke'});
    });
    final active = sandbox!;
    await check('health', () async {
      if (!await active.isRunning()) throw StateError('Sandbox not running');
    });
    await check('info', () async {
      if ((await active.getInfo()).sandboxId != active.sandboxId) {
        throw StateError('Sandbox ID mismatch');
      }
    });
    const path = '/tmp/e2b-dart-cloud-smoke.bin';
    final payload = <int>[0, 1, 127, 128, 255];
    await check('file_write_read', () async {
      await active.files.write(path, payload);
      final actual = await active.files.readBytes(path);
      if (jsonEncode(actual) != jsonEncode(payload)) {
        throw StateError('File bytes differ');
      }
    });
    await check('file_stream', () async {
      final chunks = await active.files.readStream(path).toList();
      if (jsonEncode(chunks.expand((chunk) => chunk).toList()) !=
          jsonEncode(payload)) {
        throw StateError('Stream bytes differ');
      }
    });
    await check('command_stream', () async {
      final chunks = StringBuffer();
      final result = await active.commands
          .run("printf 'dart-cloud-ok'", onStdout: chunks.write);
      if (result.exitCode != 0 ||
          result.stdout != 'dart-cloud-ok' ||
          chunks.toString() != result.stdout) {
        throw StateError('Command result differs');
      }
    });
  } catch (_) {
    exitCode = 1;
  } finally {
    try {
      if (sandbox != null) {
        await check('kill', () async {
          if (!await sandbox!.kill()) throw StateError('Cleanup not confirmed');
        });
      }
    } catch (_) {
      exitCode = 1;
    } finally {
      client.close();
    }
    stdout.writeln(jsonEncode({
      'status': failures.isEmpty ? 'passed' : 'failed',
      'checks': checks,
      // Deliberately omit exception messages, headers and credentials.
      'failures': failures,
    }));
  }
}
