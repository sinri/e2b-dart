import 'dart:convert';
import 'dart:io';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/dockerignore.dart';
import 'package:test/test.dart';

void main() {
  test('pattern whitespace and negations use JavaScript trim characters', () {
    expect(DockerIgnoreMatcher(['\u0085']).matches('\u0085'), isTrue);
    expect(DockerIgnoreMatcher(['\uFEFF']).patterns, isEmpty);
    expect(DockerIgnoreMatcher(['*', '!\u0085']).matches('\u0085'), isFalse);
    expect(DockerIgnoreMatcher(['\u2007name\u2007']).matches('name'), isTrue);
    expect(() => DockerIgnoreMatcher(['!\uFEFF']),
        throwsA(isA<TemplateException>()));
  });

  test('class escape translation supports Unicode, hex, octal and controls',
      () {
    for (final pattern in [r'[\x41]', r'[\u0041]', r'[\101]']) {
      expect(DockerIgnoreMatcher([pattern]).matches('A'), isTrue);
    }
    expect(DockerIgnoreMatcher([r'[\U0001f600]']).matches('😀'), isTrue);
    expect(DockerIgnoreMatcher([r'[\a]']).matches('\x07'), isTrue);
    expect(DockerIgnoreMatcher([r'[\b]']).matches('\x08'), isTrue);
    for (final pattern in [r'[\q]', r'[\x4]', r'[\U00110000]', r'[\777]']) {
      expect(() => DockerIgnoreMatcher([pattern]),
          throwsA(isA<TemplateException>()));
    }
  });
  final tables =
      jsonDecode(File('test/dockerignore_vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final row in tables['matchesTests'] as List) {
    test('Moby single pattern ${jsonEncode(row)}', () {
      expect(DockerIgnoreMatcher([row[0] as String]).matches(row[1] as String),
          row[2]);
    });
    if (!(row[0] as String).contains(r'\')) {
      test('Moby Windows pattern ${jsonEncode(row)}', () {
        expect(
            DockerIgnoreMatcher([(row[0] as String).replaceAll('/', r'\')],
                    backslashIsSeparator: true)
                .matches((row[1] as String).replaceAll('/', r'\')),
            row[2]);
      });
    }
  }
  for (final row in tables['multiPatternTests'] as List) {
    test('Moby ordered patterns ${jsonEncode(row)}', () {
      expect(
          DockerIgnoreMatcher((row[0] as List).cast<String>())
              .matches(row[1] as String),
          row[2]);
    });
  }
  for (final row in tables['matchTests'] as List) {
    test('Moby character class ${jsonEncode(row)}', () {
      if (row[3] == true) {
        expect(() => DockerIgnoreMatcher([row[0] as String]),
            throwsA(isA<TemplateException>()));
      } else {
        expect(
            DockerIgnoreMatcher([row[0] as String]).matches(row[1] as String),
            row[2]);
      }
    });
  }
  test('mayMatchUnder follows negative patterns with wildcard descendants', () {
    final matcher = DockerIgnoreMatcher(['*', '!src/lib/**', '!a/b/c']);
    expect(matcher.mayMatchUnder('src'), isTrue);
    expect(matcher.mayMatchUnder('src/lib'), isTrue);
    expect(matcher.mayMatchUnder('a/b'), isTrue);
    expect(matcher.mayMatchUnder('a/b/c'), isFalse);
    expect(matcher.mayMatchUnder('other'), isFalse);
  });
  test('parent match results preserve directory exclusions and reinclusions',
      () {
    final matcher = DockerIgnoreMatcher(['build', '!build/keep']);
    expect(matcher.matches('build/out.js'), isTrue);
    expect(matcher.matches('build/keep/file'), isFalse);
    expect(() => DockerIgnoreMatcher(['!']), throwsA(isA<TemplateException>()));
  });
}
