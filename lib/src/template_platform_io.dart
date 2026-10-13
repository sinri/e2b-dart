import 'dart:io';
import 'node_utf8.dart';
import 'package:path/path.dart' as p;

const supportsLocalTemplateFiles = true;
String readTemplateFile(String context, String path) =>
    nodeUtf8Decode(File(p.join(context, path)).readAsBytesSync());

String readDockerfileContent(String input) {
  try {
    final file = File(input);
    if (file.existsSync()) return nodeUtf8Decode(file.readAsBytesSync());
  } catch (_) {}
  return input;
}
