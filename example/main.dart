import 'dart:io';
import 'package:e2b/e2b.dart';

Future<void> main() async {
  final key = Platform.environment['E2B_API_KEY'];
  if (key == null) {
    throw StateError('Set E2B_API_KEY before running this example');
  }
  final client = E2BClient(apiKey: key);
  Sandbox? sandbox;
  try {
    sandbox = await client.create();
    print('Sandbox: ${sandbox.sandboxId}');
    await sandbox.files.write('/tmp/hello.txt', 'Hello from Dart!');
    final result = await sandbox.commands
        .run('cat /tmp/hello.txt', onStdout: stdout.write);
    if (result.stdout != 'Hello from Dart!') {
      throw StateError('Unexpected command output');
    }
    print('\n${(await sandbox.files.getInfo('/tmp/hello.txt')).size} bytes');
  } finally {
    try {
      await sandbox?.kill();
    } finally {
      client.close();
    }
  }
}
