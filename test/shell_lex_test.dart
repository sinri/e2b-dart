import 'dart:convert';
import 'dart:io';
import 'package:e2b/src/shell_lex.dart';
import 'package:test/test.dart';

void main() {
  for (final name in [
    'wordsTest',
    'wordsTest.rawQuotes',
    'envVarTest',
    'envVarTest.env',
    'wordsTest.env',
    'processWithMatches'
  ]) {
    final rows = jsonDecode(
            File('test/fixtures/buildkit/shell/$name.json').readAsStringSync())
        as List;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index] as Map<String, dynamic>;
      test('$name $index: ${row['input']}', () {
        final expanded = name.endsWith('.env') || name == 'processWithMatches';
        final env = name == 'envVarTest.env'
            ? {'PWD': '/home', 'SHELL': 'bash', 'KOREAN': '한국어', 'NULL': ''}
            : Map<String, String>.from(row['env'] as Map? ?? {});
        final lex = ShellLex(r'\',
            rawQuotes: name == 'wordsTest.rawQuotes',
            env: env,
            skipUnsetEnv: !expanded);
        final input = row['input'] as String;
        final word = name != 'wordsTest.env';
        final words = !['envVarTest.env', 'processWithMatches'].contains(name);
        if (row['error'] == true) {
          if (word) expect(() => lex.processWord(input), throwsFormatException);
          if (words) {
            expect(() => lex.processWords(input), throwsFormatException);
          }
        } else {
          if (word) expect(lex.processWord(input), row['word']);
          if (words) expect(lex.processWords(input), row['words']);
        }
      });
    }
  }
}
