import 'package:e2b/e2b.dart';

// Web compile smoke entry point; no network request or credential embedded.
void main() {
  final client = E2BClient(apiKey: 'compile-only-placeholder');
  client.close();
  final logger = defaultBuildLogger();
  logger(LogEntryEnd(DateTime.now(), 'Compile check complete'));
}
