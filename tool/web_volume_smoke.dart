import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Execute the compiled non-IO branch with Node and an injected HTTP client.
// Real browser networking is a separate integration check.
Future<void> main() async {
  var sent = false;
  final client = E2BClient(
      apiKey: 'key',
      httpClient: MockClient((request) async {
        sent = true;
        if (request.method != 'PUT' ||
            request.url.host != 'api.example.test' ||
            request.headers['Authorization'] != 'Bearer token' ||
            request.headers['lang'] != 'dart' ||
            request.bodyBytes.join(',') != '0,255,1,2') {
          throw StateError('Browser volume upload request mismatch');
        }
        return http.Response(
            jsonEncode({
              'name': 'a',
              'path': '/a',
              'type': 'file',
              'size': 4,
              'mode': 420,
              'uid': 0,
              'gid': 0,
              'atime': '2026-01-01T00:00:00Z',
              'mtime': '2026-01-01T00:00:00Z',
              'ctime': '2026-01-01T00:00:00Z',
            }),
            200);
      }));
  try {
    final volume = Volume(
        client,
        VolumeAndToken({
          'volumeID': 'v',
          'name': 'test',
          'token': 'token',
          'domain': 'example.test',
        }));
    final result = await volume.writeFile(
        '/a',
        Stream<List<int>>.fromIterable([
          [0, 255],
          [1, 2]
        ]));
    if (!sent || result.size != 4) {
      throw StateError('Browser volume upload result mismatch');
    }
    print('Browser volume buffered upload passed');
  } finally {
    client.close();
  }
}
