import 'dart:convert';
import 'dart:typed_data';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:test/test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

List<int> trailer(Map<String, dynamic> data) => envelope(data)..[0] = 2;
void main() {
  test('per-call management headers cannot replace envd protocol headers',
      () async {
    final transport = EnvdTransport(MockClient((request) async {
      expect(request.headers['X-Access-Token'], 'token');
      expect(request.headers['User-Agent'], 'agent');
      expect(request.headers['Custom'], isNull);
      expect(request.headers['Connect-Protocol-Version'], '1');
      expect(request.headers['Authorization'],
          'Basic ${base64Encode(utf8.encode('user:'))}');
      return http.Response('{}', 200);
    }),
        Uri.parse('https://envd.test'),
        {
          'X-Access-Token': 'token',
          'User-Agent': 'agent',
        },
        const Duration(seconds: 1));
    await transport
        .withOptions(RequestOptions(
            headers: {'Custom': 'legacy', 'X-Access-Token': 'wrong'},
            apiHeaders: {'User-Agent': 'wrong', 'Custom': 'modern'}))
        .rpc('process.Process', 'List', {}, user: 'user');
  });

  test('Connect envelopes survive every byte boundary and coalescing',
      () async {
    final frame = [
      ...envelope({'text': '你好🌍'}),
      ...envelope({'n': 2}),
      ...trailer({})
    ];
    final events =
        await decodeEnvelopes(Stream.fromIterable(frame.map((b) => [b])))
            .toList();
    expect(events, [
      {'text': '你好🌍'},
      {'n': 2}
    ]);
    expect(await decodeEnvelopes(Stream.value(frame)).toList(), events);
  });
  test('Connect trailers propagate typed errors', () async {
    expect(
        decodeEnvelopes(Stream.value(trailer({
          'error': {'code': 'not_found', 'message': 'gone'}
        }))).toList(),
        throwsA(isA<NotFoundException>()));
  });
  test('Connect rejects truncation and missing end envelope', () async {
    expect(decodeEnvelopes(Stream.value([0, 0])).toList(),
        throwsA(isA<E2BException>()));
    expect(decodeEnvelopes(Stream.value(envelope({}))).toList(),
        throwsA(isA<E2BException>()));
  });
  test('Connect rejects compressed and oversized frames', () async {
    final compressed = envelope({})..[0] = 1;
    expect(decodeEnvelopes(Stream.value(compressed)).toList(),
        throwsA(isA<E2BException>()));
    final header = Uint8List(5);
    ByteData.sublistView(header).setUint32(1, 17 * 1024 * 1024);
    expect(decodeEnvelopes(Stream.value(header)).toList(),
        throwsA(isA<E2BException>()));
  });
  test('Connect request uses big endian JSON framing', () {
    final frame = envelope({'x': '文'});
    expect(ByteData.sublistView(frame).getUint32(1), frame.length - 5);
    expect(jsonDecode(utf8.decode(frame.sublist(5))), {'x': '文'});
  });
}
