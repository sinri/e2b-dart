import 'package:e2b/e2b.dart';

// Compile with dart compile js, then run with Node; this exercises the non-IO
// platform branch instead of only checking that it can be tree-shaken.
void main() {
  if (withGitCredentials('https://0x7f.1/repo', 'u', 'p') !=
      'https://u:p@127.0.0.1/repo') {
    throw StateError('Web numeric host normalization failed');
  }
  if (!parseGitStatus('## main [ahead nope]').ahead.isNaN) {
    throw StateError('Web tracking NaN parsing failed');
  }
  for (final items in [
    <CopyItem>[],
    [const CopyItem('a', '/a')]
  ]) {
    try {
      Template().copyItems(items);
      throw StateError('Browser copyItems must reject even empty input');
    } on TemplateException catch (error) {
      if (error.message != 'Browser runtime is not supported for copyItems') {
        rethrow;
      }
    }
  }
  for (final domain in ['e2b.app', 'e2b.dev', 'e2b.pro', 'e2b-staging.dev']) {
    final config = ConnectionConfig(domain: domain);
    final expected = 'https://49983-s.$domain';
    if (config.getSandboxUrl('s').toString() != expected ||
        config.getSandboxDirectUrl('s').toString() != expected) {
      throw StateError('Browser sandbox routing mismatch: $domain');
    }
  }
  final debug = ConnectionConfig(debug: true);
  if (debug.getSandboxUrl('s').toString() != 'http://localhost:49983') {
    throw StateError('Browser debug routing mismatch');
  }
  print('Browser sandbox routing passed');
}
