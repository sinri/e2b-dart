@TestOn('browser')
library;

import 'dart:async';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test('real browser CORS management request and error response', () async {
    const origin = 'http://127.0.0.1:18763';
    final client = ApiClient(
        apiKey: 'browser-test-key', apiUrl: Uri.parse(origin), retries: 0);
    try {
      final response = await client.api.GET('/echo', query: {
        'state': ['running', 'paused']
      });
      expect((response.data as Map)['query'], 'state=running,paused');
      expect((response.data as Map)['key'], 'browser-test-key');
      final error = await client.api.GET('/error');
      expect(error.response.statusCode, 403);
      expect((error.error as Map)['message'], 'browser forbidden');
    } finally {
      client.close();
    }
  });
  test('browser cancellation closes the peer and leaves client reusable',
      () async {
    final client = ApiClient(
        apiKey: 'browser-test-key',
        apiUrl: Uri.parse('http://127.0.0.1:18763'),
        retries: 0);
    final signal = CancellationSignal();
    final reason = StateError('browser cancellation');
    try {
      final pending =
          client.api.GET('/slow', options: RequestOptions(signal: signal));
      final canceled = expectLater(pending, throwsA(same(reason)));
      Future<bool> waitFor(String field) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          final stats = await client.api.GET('/stats');
          if ((stats.data as Map)[field] == true) return true;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return false;
      }

      expect(await waitFor('started'), isTrue);
      signal.cancel(reason);
      await canceled.timeout(const Duration(seconds: 3));
      expect(await waitFor('closed'), isTrue);
      final next = await client.api.GET('/echo');
      expect((next.data as Map)['key'], 'browser-test-key');
    } finally {
      signal.cancel(reason);
      client.close();
    }
  });
  test('browser files preserve bytes and deliver chunks before EOF', () async {
    final client = http.Client();
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('http://127.0.0.1:18763'), {}, const Duration(seconds: 5)));
    final control = ApiClient(
        apiKey: 'browser-test-key',
        apiUrl: Uri.parse('http://127.0.0.1:18763'),
        retries: 0);
    try {
      expect(await files.readBytes('/bytes'), [0, 128, 255, 1, 2, 3]);
      final iterator = StreamIterator(files.readStream('/stream'));
      try {
        expect(await iterator.moveNext().timeout(const Duration(seconds: 3)),
            isTrue);
        final bytes = <int>[...iterator.current];
        expect(bytes, [0, 128, 255]);
        await control.api.GET('/release-file');
        while (await iterator.moveNext()) {
          bytes.addAll(iterator.current);
        }
        expect(bytes, [0, 128, 255, 1, 2, 3]);
      } finally {
        await iterator.cancel();
      }
    } finally {
      client.close();
      control.close();
    }
  });
  test('browser file subscription cancellation closes body and permits reuse',
      () async {
    final client = http.Client();
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('http://127.0.0.1:18763'), {}, const Duration(seconds: 5)));
    final control = ApiClient(
        apiKey: 'browser-test-key',
        apiUrl: Uri.parse('http://127.0.0.1:18763'),
        retries: 0);
    final iterator = StreamIterator(files.readStream('/cancel'));
    try {
      expect(await iterator.moveNext().timeout(const Duration(seconds: 3)),
          isTrue);
      expect(iterator.current, [0, 128, 255]);
      await iterator.cancel().timeout(const Duration(seconds: 3));
      var closed = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        final stats = await control.api.GET('/stats');
        if ((stats.data as Map)['fileClosed'] == true) {
          closed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(closed, isTrue, reason: 'peer must observe body cancellation');
      expect(await files.readBytes('/bytes'), [0, 128, 255, 1, 2, 3]);
    } finally {
      await iterator.cancel();
      client.close();
      control.close();
    }
  });
  test('browser file signal cancellation closes body and preserves reason',
      () async {
    final client = http.Client();
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('http://127.0.0.1:18763'), {}, const Duration(seconds: 5)));
    final control = ApiClient(
        apiKey: 'browser-test-key',
        apiUrl: Uri.parse('http://127.0.0.1:18763'),
        retries: 0);
    final signal = CancellationSignal();
    final reason = StateError('file body cancellation');
    final iterator = StreamIterator(files.readStream('/signal-cancel',
        options: RequestOptions(signal: signal)));
    try {
      expect(await iterator.moveNext().timeout(const Duration(seconds: 3)),
          isTrue);
      expect(iterator.current, [0, 128, 255]);
      final canceled = expectLater(iterator.moveNext(), throwsA(same(reason)));
      signal.cancel(reason);
      await canceled.timeout(const Duration(seconds: 3));
      var closed = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        final stats = await control.api.GET('/stats');
        if ((stats.data as Map)['fileSignalClosed'] == true) {
          closed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(closed, isTrue, reason: 'peer must observe body cancellation');
      expect(await files.readBytes('/bytes'), [0, 128, 255, 1, 2, 3]);
    } finally {
      await iterator.cancel();
      client.close();
      control.close();
    }
  });
  test(
      'browser multipart upload preserves filenames and binary/text/stream inputs',
      () async {
    final client = http.Client();
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('http://127.0.0.1:18763'), {}, const Duration(seconds: 5)));
    try {
      final results = await files.writeFiles([
        WriteEntry('/binary', [0, 128, 255]),
        WriteEntry('/text', '你好'),
        WriteEntry(
            '/stream-input',
            Stream<List<int>>.fromIterable([
              [1],
              [2, 3]
            ])),
      ]);
      expect(results.map((entry) => entry.path),
          ['/binary', '/text', '/stream-input']);
      expect(results.map((entry) => entry.size), [3, 6, 3]);
    } finally {
      client.close();
    }
  });
  test('browser automatically decodes gzip files without double decompression',
      () async {
    final client = http.Client();
    final files = Filesystem(EnvdTransport(client,
        Uri.parse('http://127.0.0.1:18763'), {}, const Duration(seconds: 5)));
    try {
      expect(await files.readBytes('/compressed', gzip: true),
          [0, 128, 255, 1, 2, 3]);
      final chunks = await files.readStream('/compressed', gzip: true).toList();
      expect(chunks.expand((chunk) => chunk), [0, 128, 255, 1, 2, 3]);
    } finally {
      client.close();
    }
  });
  test('browser gzip upload preserves binary data and metadata', () async {
    final client = http.Client();
    final transport = EnvdTransport(client, Uri.parse('http://127.0.0.1:18763'),
        {}, const Duration(seconds: 5))
      ..version = '0.6.4';
    final files = Filesystem(transport);
    try {
      final result = await files.write('/gzip-upload', [0, 128, 255, 1, 2, 3],
          gzip: true, metadata: {'source': 'browser'});
      expect(result.path, '/gzip-upload');
      expect(result.size, 6);
    } finally {
      client.close();
    }
  });
  test('browser cancels input buffering before multipart or gzip upload',
      () async {
    final client = http.Client();
    final transport = EnvdTransport(client, Uri.parse('http://127.0.0.1:18763'),
        {}, const Duration(seconds: 5))
      ..version = '0.6.4';
    final files = Filesystem(transport);
    try {
      for (final gzip in [false, true]) {
        final listened = Completer<void>();
        var stopped = false;
        final input = StreamController<List<int>>(
            onListen: () => listened.complete(),
            onCancel: () {
              stopped = true;
            });
        final signal = CancellationSignal();
        final reason = StateError('cancel buffering');
        final pending = files.write('/must-not-send', input.stream,
            gzip: gzip, options: RequestOptions(signal: signal));
        final canceled = expectLater(pending, throwsA(same(reason)));
        await listened.future;
        input.add([1, 2, 3]);
        signal.cancel(reason);
        await canceled.timeout(const Duration(seconds: 3));
        expect(stopped, isTrue);
        await input.close();
      }
    } finally {
      client.close();
    }
  });
  test('browser Volume cancels buffering then uploads with isolated token',
      () async {
    final client = E2BClient(apiKey: 'management-key');
    final volume = Volume(
        client,
        VolumeAndToken({
          'volumeID': 'browser-volume',
          'name': 'test',
          'token': 'volume-test-token',
        }));
    final origin = Uri.parse('http://127.0.0.1:18763');
    final signal = CancellationSignal();
    final listened = Completer<void>();
    var stopped = false;
    final input = StreamController<List<int>>(
        onListen: () => listened.complete(),
        onCancel: () {
          stopped = true;
        });
    final reason = StateError('cancel volume buffering');
    try {
      final pending = volume.writeFile('/must-not-send', input.stream,
          options: VolumeRequestOptions(apiUrl: origin, signal: signal));
      final canceled = expectLater(pending, throwsA(same(reason)));
      await listened.future;
      signal.cancel(reason);
      await canceled.timeout(const Duration(seconds: 3));
      expect(stopped, isTrue);
      final result = await volume.writeFile(
          '/data',
          Stream<List<int>>.fromIterable([
            [0, 255],
            [1, 2]
          ]),
          options: VolumeRequestOptions(apiUrl: origin));
      expect(result.size, 4);
      expect(result.path, '/data');
    } finally {
      await input.close();
      client.close();
    }
  });
}
