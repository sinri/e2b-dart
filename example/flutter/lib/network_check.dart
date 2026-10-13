import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:flutter/widgets.dart';

/// Local-peer runner used only by the platform validation tool.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final origin = Platform.environment['E2B_LOCAL_TEST_ORIGIN'];
  if (origin == null) exit(78);
  final client =
      E2BClient(apiKey: 'local-macos-test-key', apiUrl: Uri.parse(origin));
  Sandbox? sandbox;
  var passed = false;
  try {
    sandbox = await client.create(
        timeout: const Duration(minutes: 1),
        options: RequestOptions(sandboxUrl: Uri.parse(origin)));
    if (sandbox.sandboxId != 'macos-local') throw StateError('Unexpected ID');
    final payload = [0, 128, 255, 1, 2, 3];
    await sandbox.files.write('/local-data', payload);
    final bytes = await sandbox.files.readBytes('/local-data');
    final chunks = await sandbox.files.readStream('/local-data').toList();
    if (jsonEncode(bytes) != jsonEncode(payload) ||
        jsonEncode(chunks.expand((chunk) => chunk).toList()) !=
            jsonEncode(payload)) {
      throw StateError('File bytes differ');
    }
    final output = StringBuffer();
    final command = await sandbox.commands.run('printf local-command',
        onStdout: (chunk) async {
      output.write(chunk);
      await client.api.GET('/command-output-ack');
    });
    if (command.exitCode != 0 ||
        command.stdout != 'local-command' ||
        output.toString() != command.stdout) {
      throw StateError('Command output differs');
    }
    passed = true;
  } catch (_) {
    passed = false;
  } finally {
    try {
      if (sandbox != null && !await sandbox.kill()) passed = false;
    } catch (_) {
      passed = false;
    }
    client.close();
  }
  stdout.writeln(jsonEncode({'macosNetwork': passed ? 'passed' : 'failed'}));
  await stdout.flush();
  exit(passed ? 0 : 1);
}
