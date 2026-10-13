import 'dart:async';
import 'dart:convert';
import 'package:e2b/e2b.dart';
import 'package:e2b/src/transport.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  StreamingClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse response(Object json) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(json))), 200);

void main() {
  test('command and watch reject non-start first events before callbacks',
      () async {
    for (final watch in [false, true]) {
      var canceled = false;
      final output = StreamController<List<int>>(onCancel: () {
        canceled = true;
      });
      final transport = EnvdTransport(StreamingClient((_) async {
        output.add(envelope(watch
            ? {'keepalive': {}}
            : {
                'event': {
                  'data': {'stdout': base64Encode(utf8.encode('ignored'))}
                }
              }));
        return http.StreamedResponse(output.stream, 200);
      }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
      var callback = false;
      await expectLater(
          watch
              ? Filesystem(transport).watch('/', (_) {
                  callback = true;
                })
              : Commands(transport).start('echo', onStdout: (_) {
                  callback = true;
                }),
          throwsA(isA<E2BException>()
              .having((e) => e.message, 'message', 'Expected start event')));
      expect(callback, isFalse);
      expect(canceled, isTrue);
      await output.close();
    }
  });

  test(
      'multipart logs headers before body and cancels when response logger throws',
      () async {
    final logs = <List<Object?>>[];
    final client = StreamingClient((_) async => http.StreamedResponse(
        Stream.value(utf8.encode('[{"path":"/file"}]')), 200,
        reasonPhrase: 'OK'));
    final transport = EnvdTransport(client,
        Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    await Filesystem(transport).write('/file', 'data',
        options: RequestOptions(logger: Logger(info: logs.add)));
    expect(logs.first.single,
        startsWith('Request POST https://sandbox.example/files?'));
    expect(logs.last, ['Response:', 200, 'OK']);
    var canceled = false;
    final body = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final failure = StateError('logger failed');
    final failingTransport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(body.stream, 400,
            reasonPhrase: 'Bad Request')),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    await expectLater(
        Filesystem(failingTransport).write('/file', 'data',
            options:
                RequestOptions(logger: Logger(error: (_) => throw failure))),
        throwsA(same(failure)));
    expect(canceled, isTrue);
    await body.close();
  });

  test('multipart upload uses per-call client and bound cancellation',
      () async {
    var calls = 0;
    final options = RequestOptions(proxy: 'http://proxy.example:8080');
    final selected = StreamingClient((request) async {
      calls++;
      expect(request, isA<http.MultipartRequest>());
      return response([
        {'path': '/file', 'name': 'file', 'type': 'FILE_TYPE_FILE'}
      ]);
    });
    final transport = EnvdTransport(
        StreamingClient((_) async => throw StateError('wrong client')),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1), clientResolver: (value) {
      expect(identical(value, options), isTrue);
      return selected;
    });
    expect(
        (await Filesystem(transport).write('/file', 'data', options: options))
            .path,
        '/file');
    final signal = CancellationSignal()..cancel();
    final canceled = Filesystem(EnvdTransport(selected,
        Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1),
        signal: signal));
    await expectLater(
        canceled.write('/file', 'data'), throwsA(isA<CancellationException>()));
    expect(calls, 1);
  });

  test('file HTTP errors use status text for absent or empty messages',
      () async {
    Object? payload;
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(
            Stream.value(
                utf8.encode(payload == null ? '' : jsonEncode(payload))),
            404,
            reasonPhrase: 'Not Found')),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    final files = Filesystem(transport);
    for (final value in <Object?>[
      null,
      {},
      {'message': ''},
      []
    ]) {
      payload = value;
      await expectLater(
          files.read('/missing'),
          throwsA(isA<FileNotFoundException>()
              .having((e) => e.message, 'message', 'Not Found')));
    }
    payload = {'message': 'specific'};
    await expectLater(
        files.read('/missing'),
        throwsA(isA<FileNotFoundException>()
            .having((e) => e.message, 'message', 'specific')));
  });

  test(
      'file downloads resolve per-call HTTP clients and inherit bound cancellation',
      () async {
    var calls = 0;
    var resolutions = 0;
    final fallback =
        StreamingClient((_) async => throw StateError('wrong client'));
    final selected = StreamingClient((_) async {
      calls++;
      return http.StreamedResponse(Stream.value(utf8.encode('selected')), 200);
    });
    final options = RequestOptions(proxy: 'http://proxy.example:8080');
    final transport = EnvdTransport(
        fallback,
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1), clientResolver: (requestOptions) {
      expect(identical(requestOptions, options), isTrue);
      resolutions++;
      return selected;
    });
    final files = Filesystem(transport);
    expect(await files.read('/file', options: options), 'selected');
    expect(
        await files
            .readStream('/file', options: options)
            .expand((chunk) => chunk)
            .toList(),
        utf8.encode('selected'));
    expect(calls, 2);
    expect(resolutions, 2);
    final cancellation = CancellationSignal()..cancel();
    final canceled = Filesystem(EnvdTransport(selected,
        Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1),
        signal: cancellation));
    await expectLater(canceled.read('/file'), throwsA(isA<E2BException>()));
    expect(calls, 2);
  });

  test('filesystem gzip read option reaches all download formats', () async {
    final transport = EnvdTransport(StreamingClient((request) async {
      expect(request.headers['Accept-Encoding'], 'gzip');
      return http.StreamedResponse(Stream.value(utf8.encode('hello')), 200);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final files = Filesystem(transport);
    expect(await files.read('/file', gzip: true), 'hello');
    expect(await files.readBytes('/file', gzip: true), utf8.encode('hello'));
    expect(
        await files.readStream('/file', gzip: true).expand((e) => e).toList(),
        utf8.encode('hello'));
  });

  test('PTY defaults preserve explicit environment overrides and zero size',
      () async {
    for (final envs in <Map<String, String>>[
      {},
      {'TERM': '', 'LANG': 'custom'}
    ]) {
      final events = StreamController<List<int>>();
      final transport = EnvdTransport(StreamingClient((request) async {
        if (request.url.path.endsWith('/Start')) {
          final bytes = await request.finalize().toBytes();
          final body = jsonDecode(utf8.decode(bytes.sublist(5))) as Map;
          expect(body['process']['envs'], {
            'TERM': 'xterm-256color',
            'LANG': 'C.UTF-8',
            'LC_ALL': 'C.UTF-8',
            ...envs
          });
          expect(body['pty']['size'], {'cols': 0, 'rows': 0});
          return http.StreamedResponse(events.stream, 200);
        }
        final body =
            jsonDecode(await request.finalize().bytesToString()) as Map;
        expect(body['pty']['size'], {'cols': 0, 'rows': 0});
        return response({});
      }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
      final pty = Pty(transport);
      final opening = pty.create(cols: 0, rows: 0, envs: envs);
      events.add(envelope({
        'event': {
          'start': {'pid': 42}
        }
      }));
      final handle = await opening;
      await pty.resize(42, cols: 0, rows: 0);
      await handle.disconnect();
      await events.close();
      expect(envs.containsKey('LC_ALL'), isFalse);
    }
  });

  test('filesystem missing entry responses surface descriptive errors',
      () async {
    final transport = EnvdTransport(StreamingClient((_) async => response({})),
        Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final files = Filesystem(transport);
    await expectLater(
        files.getInfo('/file'),
        throwsA(isA<E2BException>().having((e) => e.message, 'message',
            'Expected to receive information about the file or directory')));
    await expectLater(
        files.rename('/a', '/b'),
        throwsA(isA<E2BException>().having((e) => e.message, 'message',
            'Expected to receive information about moved object')));
    await expectLater(
        files.list('/', depth: 0), throwsA(isA<InvalidArgumentException>()));
  });

  for (final connect in [false, true]) {
    for (final unlimited in [false, true]) {
      test('PTY connect=$connect unlimited=$unlimited timeout headers',
          () async {
        final events = StreamController<List<int>>();
        final transport = EnvdTransport(StreamingClient((request) async {
          expect(request.headers['Keepalive-Ping-Interval'], '50');
          expect(request.headers['Connect-Timeout-Ms'],
              unlimited ? null : '60000');
          return http.StreamedResponse(events.stream, 200);
        }), Uri.parse('https://sandbox.example'), {},
            const Duration(seconds: 1));
        final pty = Pty(transport);
        final opening = connect
            ? (unlimited
                ? pty.connect(42, timeout: Duration.zero)
                : pty.connect(42))
            : (unlimited
                ? pty.create(cols: 80, rows: 24, timeout: Duration.zero)
                : pty.create(cols: 80, rows: 24));
        events.add(envelope({
          'event': {
            'start': {'pid': 42}
          }
        }));
        final handle = await opening;
        await handle.disconnect();
        await events.close();
      });
    }
  }

  test('PTY resource input and kill use process selector and handle not-found',
      () async {
    var calls = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      final body = jsonDecode(await request.finalize().bytesToString());
      expect(request.headers['X-Call'], isNull);
      expect(body['process'], {'pid': 42});
      calls++;
      if (calls == 1) {
        expect(request.url.path, '/process.Process/SendInput');
        expect(body['input'], {
          'pty': base64Encode([0, 255])
        });
      } else {
        expect(request.url.path, '/process.Process/SendSignal');
        expect(body['signal'], 'SIGNAL_SIGKILL');
        if (calls == 3) {
          return http.StreamedResponse(
              Stream.value(
                  utf8.encode('{"code":"not_found","message":"missing"}')),
              404);
        }
      }
      return response({});
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final pty = Pty(transport);
    final options = RequestOptions(headers: {'X-Call': 'value'});
    await pty.sendInput(42, [0, 255], options: options);
    expect(await pty.kill(42, options: options), true);
    expect(await pty.kill(42, options: options), false);
  });

  test('command list flattens protobuf process config into typed ProcessInfo',
      () async {
    final transport = EnvdTransport(StreamingClient((request) async {
      expect(request.url.path, '/process.Process/List');
      expect(request.headers['X-Call'], isNull);
      return response({
        'processes': [
          {
            'pid': 42,
            'tag': 'start',
            'config': {
              'cmd': '/bin/bash',
              'args': ['-l'],
              'envs': {'A': 'B'},
              'cwd': '/app'
            }
          },
          {
            'pid': 43,
            'tag': '',
            'config': {'cmd': 'sh', 'cwd': ''}
          },
        ]
      });
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final processes = await Commands(transport)
        .list(options: RequestOptions(headers: {'X-Call': 'value'}));
    expect(processes.first.pid, 42);
    expect(processes.first.tag, 'start');
    expect(processes.first.cmd, '/bin/bash');
    expect(processes.first.args, ['-l']);
    expect(processes.first.envs, {'A': 'B'});
    expect(processes.first.cwd, '/app');
    expect(processes.last.tag, isNull);
    expect(processes.last.cwd, isNull);
    expect(processes.last.args, isEmpty);
    expect(processes.last.envs, isEmpty);
  });

  test('command handle stdin encodes text and bytes and forwards close',
      () async {
    final events = StreamController<List<int>>();
    final requests = <Map<String, dynamic>>[];
    final transport = EnvdTransport(StreamingClient((request) async {
      if (request.url.path.endsWith('/Start')) {
        final body = jsonDecode(
                utf8.decode((await request.finalize().toBytes()).sublist(5)))
            as Map;
        expect(body['stdin'], true);
        return http.StreamedResponse(events.stream, 200);
      }
      requests.add(jsonDecode(await request.finalize().bytesToString())
          as Map<String, dynamic>);
      expect(request.headers['Custom'], isNull);
      return response({});
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1))
      ..version = '0.5.2';
    final opening = Commands(transport).start('cat', stdin: true);
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    final options = RequestOptions(headers: {'Custom': 'value'});
    await handle.sendStdin('你好', options: options);
    await handle.sendStdin([0, 255, 1], options: options);
    await handle.closeStdin(options: options);
    expect(requests, [
      {
        'process': {'pid': 42},
        'input': {'stdin': base64Encode(utf8.encode('你好'))}
      },
      {
        'process': {'pid': 42},
        'input': {
          'stdin': base64Encode([0, 255, 1])
        }
      },
      {
        'process': {'pid': 42}
      },
    ]);
    await handle.disconnect();
    await events.close();
  });

  test('stdin version gates reject before HTTP', () async {
    var calls = 0;
    final transport = EnvdTransport(StreamingClient((_) async {
      calls++;
      return response({});
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1))
      ..version = '0.2.9';
    final commands = Commands(transport);
    expect(() => commands.start('cat', stdin: false),
        throwsA(isA<E2BException>()));
    expect(commands.supportsStdinClose, false);
    await expectLater(commands.closeStdin(42), throwsA(isA<E2BException>()));
    expect(calls, 0);
    transport.version = '0.5.1';
    expect(commands.supportsStdinClose, false);
    transport.version = '0.5.2';
    expect(commands.supportsStdinClose, true);
  });

  test('command awaits async output callbacks in order before completing',
      () async {
    final events = StreamController<List<int>>();
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(events.stream, 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    final entered = Completer<void>(), release = Completer<void>();
    final received = <String>[];
    final opening = Commands(transport).start('echo', onStdout: (value) async {
      received.add(value);
      if (value == 'first') {
        entered.complete();
        await release.future;
      }
    });
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    for (final value in ['first', 'second']) {
      events.add(envelope({
        'event': {
          'data': {'stdout': base64Encode(utf8.encode(value))}
        }
      }));
    }
    events.add(envelope({
      'event': {
        'end': {'exitCode': 0}
      }
    }));
    await entered.future;
    expect(received, ['first']);
    expect(handle.stdout, 'first');
    expect(handle.exitCode, isNull);
    release.complete();
    expect((await handle.wait()).stdout, 'firstsecond');
    expect(received, ['first', 'second']);
    await events.close();
  });

  test(
      'disconnect returns while async callback waits and suppresses later output',
      () async {
    final events = StreamController<List<int>>();
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(events.stream, 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    final entered = Completer<void>(), release = Completer<void>();
    final received = <String>[];
    final opening = Commands(transport).start('echo', onStdout: (value) async {
      received.add(value);
      entered.complete();
      await release.future;
    });
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    events.add(envelope({
      'event': {
        'data': {'stdout': base64Encode(utf8.encode('first'))}
      }
    }));
    events.add(envelope({
      'event': {
        'data': {'stdout': base64Encode(utf8.encode('late'))}
      }
    }));
    await entered.future;
    await handle.disconnect().timeout(const Duration(seconds: 1));
    await expectLater(handle.wait(), throwsA(isA<E2BException>()));
    release.complete();
    await events.close();
    expect(received, ['first']);
  });

  test('async callback failure surfaces through command wait', () async {
    final events = StreamController<List<int>>();
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(events.stream, 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    final failure = StateError('callback failed');
    final opening = Commands(transport).start('echo', onStdout: (_) async {
      await Future<void>.value();
      throw failure;
    });
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    events.add(envelope({
      'event': {
        'data': {
          'stdout': base64Encode([65])
        }
      }
    }));
    await expectLater(handle.wait(), throwsA(same(failure)));
    expect(handle.stdout, 'A');
    await events.close();
  });

  test('abrupt stream close flushes incomplete UTF8 before failure', () async {
    final events = StreamController<List<int>>();
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(events.stream, 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    final received = <String>[];
    final opening = Commands(transport).start('echo', onStdout: received.add);
    events.add(envelope({
      'event': {
        'start': {'pid': 42}
      }
    }));
    final handle = await opening;
    events.add(envelope({
      'event': {
        'data': {
          'stdout': base64Encode([0xe2, 0x82])
        }
      }
    }));
    await events.close();
    await expectLater(handle.wait(), throwsA(isA<E2BException>()));
    expect(received, ['\uFFFD']);
    expect(handle.stdout, '\uFFFD');
  });

  for (final exit in [0, 7]) {
    test('command result getters retain exit $exit and server error', () async {
      final events = StreamController<List<int>>();
      final transport = EnvdTransport(
          StreamingClient(
              (_) async => http.StreamedResponse(events.stream, 200)),
          Uri.parse('https://sandbox.example'),
          {},
          const Duration(seconds: 1));
      final opening = CommandHandle.open(transport, 'Start', {});
      events.add(envelope({
        'event': {
          'start': {'pid': 42}
        }
      }));
      final handle = await opening;
      expect(handle.exitCode, isNull);
      expect(handle.error, isNull);
      events.add(envelope({
        'event': {
          'data': {'stdout': base64Encode(utf8.encode('out'))}
        }
      }));
      events.add(envelope({
        'event': {
          'end': {'exitCode': exit, 'error': 'server detail'}
        }
      }));
      if (exit == 0) {
        final result = await handle.wait();
        expect(result.error, 'server detail');
      } else {
        await expectLater(
            handle.wait(),
            throwsA(isA<CommandExitException>()
                .having((e) => e.error, 'server error', 'server detail')
                .having((e) => e.message, 'message', 'server detail')
                .having((e) => e.stdout, 'stdout', 'out')));
      }
      expect(handle.exitCode, exit);
      expect(handle.error, 'server detail');
      expect(handle.stdout, 'out');
      await events.close();
    });
  }

  test('file HTTP errors use filesystem-specific types without probing',
      () async {
    var status = 404;
    var probes = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      if (request.url.path == '/health') probes++;
      return http.StreamedResponse(
          Stream.value(utf8.encode('{"message":"file error"}')), status);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final files = Filesystem(transport);
    await expectLater(
        files.read('/missing'), throwsA(isA<FileNotFoundException>()));
    await expectLater(
        files.getInfo('/missing'), throwsA(isA<FileNotFoundException>()));
    status = 507;
    await expectLater(
        files.write('/full', 'data'), throwsA(isA<NotEnoughSpaceException>()));
    await expectLater(files.readStream('/full').toList(),
        throwsA(isA<NotEnoughSpaceException>()));
    expect(probes, 0);
  });
  test('file buffered and streaming connection failures probe sandbox health',
      () async {
    var probes = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      if (request.url.path == '/health') {
        probes++;
        return http.StreamedResponse(
            Stream.value(utf8.encode('sandbox was not found')), 502);
      }
      throw http.ClientException('connection lost');
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final files = Filesystem(transport);
    await expectLater(
        files.read('/file'), throwsA(isA<SandboxNotRunningException>()));
    await expectLater(files.readStream('/file').toList(),
        throwsA(isA<SandboxNotRunningException>()));
    await expectLater(files.write('/file', 'data'),
        throwsA(isA<SandboxNotRunningException>()));
    expect(probes, 3);
  });
  test('mid-download failure probes and closes the source', () async {
    var canceled = false;
    final output = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final transport = EnvdTransport(StreamingClient((request) async {
      if (request.url.path == '/health') {
        return http.StreamedResponse(
            Stream.value(utf8.encode('sandbox was not found')), 502);
      }
      scheduleMicrotask(() {
        output.add([1]);
        output.addError(http.ClientException('terminated'));
      });
      return http.StreamedResponse(output.stream, 200);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    await expectLater(Filesystem(transport).readStream('/file').toList(),
        throwsA(isA<SandboxNotRunningException>()));
    expect(canceled, isTrue);
    await output.close();
  });
  test('ambiguous envd failures probe health and preserve original cause',
      () async {
    var probes = 0;
    final original =
        const EnvdRpcException('connection ended', code: 'unavailable');
    final transport = EnvdTransport(StreamingClient((request) async {
      expect(request.url.path, '/health');
      probes++;
      return http.StreamedResponse(
          Stream.value(utf8.encode('sandbox was not found')), 502);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final mapped = await transport.resolveError(original);
    expect(
        mapped,
        isA<SandboxNotRunningException>()
            .having((e) => e.cause, 'cause', same(original)));
    expect(probes, 1);
    expect(
        await transport.resolveError(
            const EnvdRpcException('port is not open', code: 'unavailable')),
        isA<SandboxUnreachableException>());
    expect(probes, 1);
    const canceled = CancellationException('canceled');
    expect(await transport.resolveError(canceled), same(canceled));
    expect(probes, 1);
  });
  test('health response distinguishes transient, unknown and unreachable',
      () async {
    var status = 200;
    var fail = false;
    final transport = EnvdTransport(StreamingClient((_) async {
      if (fail) throw http.ClientException('network down');
      return http.StreamedResponse(Stream.value(utf8.encode('probe')), status);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    final original = http.ClientException('connection lost');
    expect(await transport.resolveError(original), same(original));
    status = 500;
    expect(await transport.resolveError(original), same(original));
    fail = true;
    expect(
        await transport.resolveError(original),
        isA<SandboxUnreachableException>()
            .having((e) => e.cause, 'cause', same(original)));
  });
  test('streaming plain proxy 502 maps before command handshake', () async {
    var probes = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      if (request.url.path == '/health') probes++;
      return http.StreamedResponse(
          Stream.value(utf8.encode('sandbox was not found')), 502);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    await expectLater(Commands(transport).run('echo'),
        throwsA(isA<SandboxNotRunningException>()));
    expect(probes, 0);
  });
  test('isRunning uses envd health and treats every proxy 502 as false',
      () async {
    var health = 200;
    final client = E2BClient(
        apiKey: 'key',
        httpClient: StreamingClient((request) async {
          if (request.url.host.startsWith('api.')) {
            return response({'sandboxID': 's', 'envdVersion': '0.6.4'});
          }
          expect(request.url.path, '/health');
          return http.StreamedResponse(
              Stream.value(utf8.encode('port is not open')), health);
        }));
    final sandbox = await client.create();
    expect(await sandbox.isRunning(), isTrue);
    health = 502;
    expect(await sandbox.isRunning(), isFalse);
    client.close();
  });
  test('directory RPC honors cancellation and excludes management headers',
      () async {
    var calls = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      calls++;
      expect(request.headers['x-call'], isNull);
      return response({'entries': []});
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1));
    expect(
        await Filesystem(transport)
            .list('/', options: RequestOptions(headers: {'x-call': 'yes'})),
        isEmpty);
    final signal = CancellationSignal()..cancel();
    await expectLater(
        Filesystem(transport)
            .exists('/', options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    expect(calls, 1);
    expect(transport.headers, isEmpty);
  });
  test('watch start event timeout cancels the pending response stream',
      () async {
    var canceled = false;
    final output = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final transport = EnvdTransport(
        StreamingClient((_) async => http.StreamedResponse(output.stream, 200)),
        Uri.parse('https://sandbox.example'),
        {},
        const Duration(seconds: 1));
    await expectLater(
        Filesystem(transport).watch('/', (_) {},
            options: RequestOptions(
                requestTimeout: const Duration(milliseconds: 20))),
        throwsA(isA<TimeoutException>()));
    expect(canceled, isTrue);
    await output.close();
  });
  test('watch callback backpressure routes failure to exactly one exit',
      () async {
    var canceled = false;
    final output = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final transport = EnvdTransport(StreamingClient((request) async {
      scheduleMicrotask(() {
        output.add(envelope({'start': {}}));
        output.add(envelope({
          'filesystem': {'name': 'ignored', 'type': 0}
        }));
        output.add(envelope({
          'filesystem': {'name': 'first', 'type': 1}
        }));
        output.add(envelope({
          'filesystem': {'name': 'second', 'type': 1}
        }));
      });
      return http.StreamedResponse(output.stream, 200);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1))
      ..version = '0.6.4';
    final gate = Completer<void>();
    final names = <String>[];
    final failures = <Object?>[];
    const reason = E2BException('callback failed');
    final handle = await Filesystem(transport).watch('/', (event) async {
      names.add(event.name);
      await gate.future;
      throw reason;
    }, onExit: (error) {
      failures.add(error);
      throw StateError('terminal callback');
    });
    await Future<void>.delayed(Duration.zero);
    expect(names, ['first']);
    gate.complete();
    await handle.done;
    expect(failures, [same(reason)]);
    expect(canceled, isTrue);
    await output.close();
  });
  test('watch stop exits cleanly and version gates reject before HTTP',
      () async {
    final output = StreamController<List<int>>();
    var calls = 0;
    final transport = EnvdTransport(StreamingClient((request) async {
      calls++;
      scheduleMicrotask(() => output.add(envelope({'start': {}})));
      return http.StreamedResponse(output.stream, 200);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 1))
      ..version = '0.6.2';
    final files = Filesystem(transport);
    await expectLater(files.watch('/', (_) {}, includeEntry: true),
        throwsA(isA<TemplateException>()));
    await expectLater(files.watch('/', (_) {}, allowNetworkMounts: true),
        throwsA(isA<TemplateException>()));
    expect(calls, 0);
    final exits = <Object?>[];
    final handle = await files.watch('/', (_) {}, onExit: exits.add);
    await handle.stop();
    await handle.done;
    await handle.stop();
    expect(exits, [null]);
    await output.close();
  });
  test('command per-call cancellation releases output and preserves reason',
      () async {
    final output = StreamController<List<int>>();
    var canceled = false;
    output.onCancel = () {
      canceled = true;
    };
    final signal = CancellationSignal();
    final transport = EnvdTransport(StreamingClient((request) async {
      expect(request.headers['x-call'], isNull);
      scheduleMicrotask(() => output.add(envelope({
            'event': {
              'start': {'pid': 9}
            }
          })));
      return http.StreamedResponse(output.stream, 200);
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 10));
    final handle = await Commands(transport).start('sleep 10',
        timeout: Duration.zero,
        options: RequestOptions(signal: signal, headers: {'x-call': 'value'}));
    const reason = CancellationException('caller stopped');
    final waiting = expectLater(handle.wait(), throwsA(same(reason)));
    signal.cancel(reason);
    await waiting;
    await Future<void>.delayed(Duration.zero);
    expect(canceled, isTrue);
    expect(transport.headers, isEmpty);
    await output.close();
  });
  test('per-call handshake timeout aborts and pre-cancel sends no request',
      () async {
    var calls = 0;
    final aborted = Completer<void>();
    final transport = EnvdTransport(StreamingClient((request) {
      calls++;
      (request as http.AbortableRequest)
          .abortTrigger!
          .then((_) => aborted.complete());
      return Completer<http.StreamedResponse>().future;
    }), Uri.parse('https://sandbox.example'), {}, const Duration(seconds: 10));
    await expectLater(
        Commands(transport).start('sleep',
            timeout: Duration.zero,
            options: RequestOptions(
                requestTimeout: const Duration(milliseconds: 20))),
        throwsA(isA<TimeoutException>()));
    await aborted.future.timeout(const Duration(seconds: 1));
    final signal = CancellationSignal()..cancel();
    await expectLater(
        Commands(transport)
            .run('echo', options: RequestOptions(signal: signal)),
        throwsA(isA<CancellationException>()));
    expect(calls, 1);
  });
  test('process timeout cancels connection and preserves caller HTTP client',
      () async {
    final output = StreamController<List<int>>();
    var canceled = false;
    output.onCancel = () {
      canceled = true;
    };
    final httpClient = StreamingClient((request) async {
      if (request.url.host.startsWith('api.')) {
        return response({'sandboxID': 's', 'envdVersion': '0.6.4'});
      }
      scheduleMicrotask(() => output.add(envelope({
            'event': {
              'start': {'pid': 4}
            }
          })));
      return http.StreamedResponse(output.stream, 200);
    });
    final client = E2BClient(apiKey: 'key', httpClient: httpClient);
    final sandbox = await client.create();
    final process = await sandbox.commands
        .start('sleep 100', timeout: const Duration(milliseconds: 50));
    await expectLater(process.wait(), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(Duration.zero);
    expect(canceled, true);
    client.close();
    await output.close();
  });

  test('PTY creation, input and resize follow protobuf JSON schema', () async {
    final output = StreamController<List<int>>();
    final received = <int>[];
    final httpClient = StreamingClient((request) async {
      if (request.url.host.startsWith('api.')) {
        return response({'sandboxID': 's', 'envdVersion': '0.6.4'});
      }
      final bytes = await request.finalize().toBytes();
      if (request.url.path.endsWith('/Start')) {
        final body = jsonDecode(utf8.decode(bytes.sublist(5)));
        expect(body['pty'], {
          'size': {'cols': 80, 'rows': 24}
        });
        scheduleMicrotask(() {
          output.add(envelope({
            'event': {
              'start': {'pid': 10}
            }
          }));
          output.add(envelope({
            'event': {
              'data': {
                'pty': base64Encode([27, 91, 65])
              }
            }
          }));
        });
        return http.StreamedResponse(output.stream, 200);
      }
      final body = jsonDecode(utf8.decode(bytes));
      expect(body['process'], {'pid': 10});
      if (request.url.path.endsWith('/SendInput')) {
        expect(body['input'], {
          'pty': base64Encode([65, 10])
        });
      }
      if (request.url.path.endsWith('/Update')) {
        expect(body['pty'], {
          'size': {'cols': 120, 'rows': 40}
        });
      }
      return response({});
    });
    final sandbox =
        await E2BClient(apiKey: 'key', httpClient: httpClient).create();
    final pty =
        await sandbox.pty.create(cols: 80, rows: 24, onData: received.addAll);
    await pty.sendInput([65, 10]);
    await sandbox.pty.resize(pty.pid, cols: 120, rows: 40);
    expect(received, [27, 91, 65]);
    await pty.disconnect();
    await expectLater(pty.wait(), throwsA(isA<E2BException>()));
    await output.close();
  });

  test('watch ignores start and keepalive and cancels upstream', () async {
    var canceled = false;
    final output = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final client = StreamingClient((request) async {
      if (request.url.host.startsWith('api.')) {
        return response({'sandboxID': 's', 'envdVersion': '0.6.4'});
      }
      scheduleMicrotask(() {
        output.add(envelope({'start': {}}));
        output.add(envelope({'keepalive': {}}));
        output.add(envelope({
          'filesystem': {
            'name': 'a',
            'type': 'EVENT_TYPE_CREATE',
            'entry': {'path': '/a', 'type': 'FILE_TYPE_FILE'}
          }
        }));
      });
      return http.StreamedResponse(output.stream, 200);
    });
    final sandbox = await E2BClient(apiKey: 'key', httpClient: client).create();
    final event = await sandbox.files.watchDir('/', includeEntry: true).first;
    expect(event.name, 'a');
    expect(event.type, FilesystemEventType.create);
    expect(event.entry!.path, '/a');
    expect(canceled, true);
    await output.close();
  });
}
