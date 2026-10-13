import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'errors.dart';
import 'models.dart';
import 'transport.dart';
import 'connection.dart';

class Commands {
  final EnvdTransport _transport;
  Commands(this._transport);

  Future<CommandResult> run(String command,
      {RequestOptions? options,
      String? cwd,
      String? user,
      Map<String, String> envs = const {},
      bool? stdin,
      Duration timeout = const Duration(seconds: 60),
      FutureOr<void> Function(String)? onStdout,
      FutureOr<void> Function(String)? onStderr}) async {
    final handle = await start(command,
        options: options,
        cwd: cwd,
        user: user,
        envs: envs,
        stdin: stdin,
        timeout: timeout,
        onStdout: onStdout,
        onStderr: onStderr);
    return handle.wait();
  }

  /// Start in the background. Keep the handle to wait, send input, or disconnect.
  Future<CommandHandle> start(String command,
      {RequestOptions? options,
      String? cwd,
      String? user,
      Map<String, String> envs = const {},
      bool? stdin,
      Duration timeout = const Duration(seconds: 60),
      FutureOr<void> Function(String)? onStdout,
      FutureOr<void> Function(String)? onStderr}) {
    if (stdin == false && !_transport.supports('0.3.0')) {
      throw E2BException(
          "Sandbox envd version ${_transport.version} can't specify stdin, it's always turned on. Please rebuild your template if you need this feature.");
    }
    return CommandHandle.open(
        _transport.withOptions(options),
        'Start',
        {
          'process': {
            'cmd': '/bin/bash',
            'args': ['-l', '-c', command],
            if (cwd != null) 'cwd': cwd,
            'envs': envs
          },
          'stdin': stdin ?? false,
        },
        user: user,
        timeout: timeout,
        onStdout: onStdout,
        onStderr: onStderr);
  }

  Future<CommandHandle> connect(int pid,
          {RequestOptions? options,
          String? user,
          Duration timeout = const Duration(seconds: 60),
          FutureOr<void> Function(String)? onStdout,
          FutureOr<void> Function(String)? onStderr}) =>
      CommandHandle.open(
          _transport.withOptions(options),
          'Connect',
          {
            'process': {'pid': pid}
          },
          user: user,
          timeout: timeout,
          onStdout: onStdout,
          onStderr: onStderr);

  Future<List<ProcessInfo>> list(
          {String? user, RequestOptions? options}) async =>
      ((await _transport.withOptions(options).rpc('process.Process', 'List', {},
                  user: user))['processes'] as List? ??
              [])
          .map((value) => ProcessInfo.fromJson(value as Map<String, dynamic>))
          .toList();

  Future<void> sendStdin(int pid, Object data,
      {String? user, RequestOptions? options}) async {
    await _transport.withOptions(options).rpc(
        'process.Process',
        'SendInput',
        {
          'process': {'pid': pid},
          'input': {'stdin': base64Encode(_stdinBytes(data))}
        },
        user: user);
  }

  bool get supportsStdinClose => _transport.supports('0.5.2');

  Future<void> closeStdin(int pid,
      {String? user, RequestOptions? options}) async {
    if (!supportsStdinClose) {
      throw E2BException(
          "Sandbox envd version ${_transport.version} doesn't support closeStdin. Please rebuild your template to pick up the latest sandbox version.");
    }
    await _transport.withOptions(options).rpc(
        'process.Process',
        'CloseStdin',
        {
          'process': {'pid': pid}
        },
        user: user);
  }

  Future<bool> kill(int pid, {String? user, RequestOptions? options}) async {
    try {
      await _transport.withOptions(options).rpc(
          'process.Process',
          'SendSignal',
          {
            'process': {'pid': pid},
            'signal': 'SIGNAL_SIGKILL'
          },
          user: user);
      return true;
    } on NotFoundException {
      return false;
    }
  }
}

/// Live command connection. Output is accumulated with incremental UTF-8 decoding.
class CommandHandle {
  final EnvdTransport _transport;
  final String? _user;
  final bool _pty;
  final _started = Completer<int>();
  final _done = Completer<CommandResult>();
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  late final ByteConversionSink _stdoutDecoder;
  late final ByteConversionSink _stderrDecoder;
  final _stdout = StringBuffer();
  final _stderr = StringBuffer();
  Timer? _timer;
  bool _finished = false;
  bool _disconnected = false;
  bool _decodersClosed = false;
  CommandResult? _result;
  int get pid => _pid!;
  int? _pid;
  String get stdout => _stdout.toString();
  String get stderr => _stderr.toString();

  /// Null while running, including when the connection fails before an exit.
  int? get exitCode => _result?.exitCode;
  String? get error => _result?.error;

  CommandHandle._(this._transport, this._user, this._pty);

  static Future<CommandHandle> open(
      EnvdTransport transport, String method, Map<String, dynamic> body,
      {RequestOptions? options,
      String? user,
      Duration timeout = const Duration(seconds: 60),
      bool pty = false,
      FutureOr<void> Function(String)? onStdout,
      FutureOr<void> Function(String)? onStderr,
      FutureOr<void> Function(Uint8List)? onData}) async {
    transport = transport.withOptions(options);
    if (timeout < Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    final handle = CommandHandle._(transport, user, pty);
    // Consumers may wait after a process exits; prevent an unhandled async error
    // without swallowing the error from subsequent wait() calls.
    unawaited(handle._done.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    final chunks = <(bool, String)>[];
    handle._stdoutDecoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(
            _CallbackSink(
                handle._stdout, (value) => chunks.add((true, value)))));
    handle._stderrDecoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(
            _CallbackSink(
                handle._stderr, (value) => chunks.add((false, value)))));
    Future<void> dispatch() async {
      while (chunks.isNotEmpty) {
        final chunk = chunks.removeAt(0);
        if (handle._disconnected || handle._finished) continue;
        if (chunk.$1) {
          await onStdout?.call(chunk.$2);
        } else {
          await onStderr?.call(chunk.$2);
        }
      }
    }

    Future<void> failed(Object error, StackTrace stack) async {
      handle._closeDecoders();
      try {
        await dispatch();
      } catch (callbackError, callbackStack) {
        error = callbackError;
        stack = callbackStack;
      }
      handle._fail(error, stack);
    }

    handle._subscription = transport
        .stream('process.Process', method, body, user: user, timeout: timeout)
        .listen((message) async {
      if (handle._finished || handle._disconnected) return;
      handle._subscription.pause();
      try {
        final event = message['event'] as Map<String, dynamic>? ?? {};
        if (handle._pid == null && event['start'] == null) {
          throw const E2BException('Expected start event');
        }
        if (event['start'] != null) {
          handle._pid = (event['start'] as Map)['pid'] as int? ?? 0;
          if (!handle._started.isCompleted) {
            handle._started.complete(handle._pid);
          }
        }
        if (event['data'] != null) {
          final data = event['data'] as Map;
          if (data['stdout'] != null) {
            handle._stdoutDecoder.add(base64Decode(data['stdout'] as String));
          }
          if (data['stderr'] != null) {
            handle._stderrDecoder.add(base64Decode(data['stderr'] as String));
          }
          await dispatch();
          if (data['pty'] != null &&
              !handle._disconnected &&
              !handle._finished) {
            await onData?.call(base64Decode(data['pty'] as String));
          }
        }
        if (event['end'] != null && !handle._finished) {
          if (handle._pid == null) {
            throw const E2BException('Process ended before start event');
          }
          final end = event['end'] as Map;
          handle._closeDecoders();
          // Record the result before flushing callbacks, matching JS even when
          // the callback disconnects while handling a trailing replacement.
          handle._result = CommandResult(
              pid: handle.pid,
              exitCode: end['exitCode'] as int? ?? 0,
              stdout: handle.stdout,
              stderr: handle.stderr,
              error: end['error'] as String?);
          await dispatch();
          handle._completeResult();
        }
      } catch (error, stack) {
        await failed(error, stack);
      } finally {
        if (!handle._finished && !handle._disconnected) {
          handle._subscription.resume();
        }
      }
    }, onError: (Object error, StackTrace stack) async {
      handle._subscription.pause();
      await failed(error, stack);
    }, onDone: () async {
      if (!handle._finished) {
        await failed(
            const E2BException('Process stream ended without an exit event'),
            StackTrace.current);
      }
    });
    // The handshake is bounded even for an unlimited process duration.
    final bound = timeout == Duration.zero ? transport.requestTimeout : timeout;
    if (bound > Duration.zero) {
      handle._timer = Timer(
          bound,
          () => handle._fail(
              TimeoutException('Command connection timed out', bound),
              StackTrace.current));
    }
    try {
      await (transport.requestTimeout == Duration.zero
          ? handle._started.future
          : handle._started.future.timeout(transport.requestTimeout));
    } catch (error, stack) {
      handle._fail(error, stack);
      rethrow;
    }
    if (timeout == Duration.zero) {
      handle._timer?.cancel();
    }
    return handle;
  }

  void _closeDecoders() {
    if (_decodersClosed) return;
    _decodersClosed = true;
    _stdoutDecoder.close();
    _stderrDecoder.close();
  }

  void _completeResult() {
    if (_finished) return;
    final result = _result!;
    _finished = true;
    _timer?.cancel();
    if (result.exitCode != 0) {
      _done.completeError(CommandExitException.fromResult(result));
    } else {
      _done.complete(result);
    }
    unawaited(_subscription.cancel());
  }

  void _fail(Object error, StackTrace stack) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _closeDecoders();
    if (!_started.isCompleted) _started.completeError(error, stack);
    if (!_done.isCompleted) _done.completeError(error, stack);
    unawaited(_subscription.cancel());
  }

  Future<CommandResult> wait() => _done.future;
  Future<bool> kill({RequestOptions? options}) =>
      Commands(_transport).kill(pid, user: _user, options: options);
  Future<void> sendInput(List<int> bytes, {RequestOptions? options}) async {
    await _transport.withOptions(options).rpc(
        'process.Process',
        'SendInput',
        {
          'process': {'pid': pid},
          'input': {_pty ? 'pty' : 'stdin': base64Encode(bytes)}
        },
        user: _user);
  }

  /// Send text (UTF-8) or bytes to a command started with stdin enabled.
  Future<void> sendStdin(Object data, {RequestOptions? options}) async {
    if (_pty) {
      throw const E2BException(
          'Sending stdin is not supported for this command handle.');
    }
    await Commands(_transport)
        .sendStdin(pid, data, user: _user, options: options);
  }

  Future<void> closeStdin({RequestOptions? options}) async {
    if (_pty) {
      throw const E2BException(
          'Closing stdin is not supported for this command handle.');
    }
    await Commands(_transport).closeStdin(pid, user: _user, options: options);
  }

  /// Disconnect the output connection; the remote process continues running.
  Future<void> disconnect() async {
    _disconnected = true;
    if (!_finished) {
      if (_result != null) {
        _completeResult();
      } else {
        _fail(const E2BException('Command disconnected'), StackTrace.current);
      }
    }
    await _subscription.cancel();
  }
}

class _CallbackSink implements StringSink {
  final StringBuffer buffer;
  final void Function(String)? callback;
  _CallbackSink(this.buffer, this.callback);
  @override
  void write(Object? object) {
    final value = '$object';
    buffer.write(value);
    if (value.isNotEmpty) callback?.call(value);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
}

class Pty {
  final EnvdTransport _transport;
  Pty(this._transport);

  Future<void> sendInput(int pid, List<int> data,
      {String? user, RequestOptions? options}) async {
    await _transport.withOptions(options).rpc(
        'process.Process',
        'SendInput',
        {
          'process': {'pid': pid},
          'input': {'pty': base64Encode(data)},
        },
        user: user);
  }

  Future<bool> kill(int pid, {String? user, RequestOptions? options}) =>
      Commands(_transport).kill(pid, user: user, options: options);

  Future<CommandHandle> create(
      {RequestOptions? options,
      required int cols,
      required int rows,
      String? cwd,
      String? user,
      Map<String, String> envs = const {},
      Duration timeout = const Duration(seconds: 60),
      FutureOr<void> Function(Uint8List)? onData}) {
    return CommandHandle.open(
        _transport.withOptions(options),
        'Start',
        {
          'process': {
            'cmd': '/bin/bash',
            'args': ['-i', '-l'],
            'envs': {
              'TERM': 'xterm-256color',
              'LANG': 'C.UTF-8',
              'LC_ALL': 'C.UTF-8',
              ...envs
            },
            if (cwd != null) 'cwd': cwd
          },
          'pty': {
            'size': {'cols': cols, 'rows': rows}
          },
        },
        user: user,
        timeout: timeout,
        pty: true,
        onData: onData);
  }

  Future<CommandHandle> connect(int pid,
          {RequestOptions? options,
          String? user,
          Duration timeout = const Duration(seconds: 60),
          FutureOr<void> Function(Uint8List)? onData}) =>
      CommandHandle.open(
          _transport.withOptions(options),
          'Connect',
          {
            'process': {'pid': pid}
          },
          user: user,
          timeout: timeout,
          pty: true,
          onData: onData);
  Future<void> resize(int pid,
      {RequestOptions? options,
      required int cols,
      required int rows,
      String? user}) async {
    await _transport.withOptions(options).rpc(
        'process.Process',
        'Update',
        {
          'process': {'pid': pid},
          'pty': {
            'size': {'cols': cols, 'rows': rows}
          }
        },
        user: user);
  }
}

List<int> _stdinBytes(Object data) {
  if (data is String) return utf8.encode(data);
  if (data is List<int>) return data;
  throw ArgumentError.value(data, 'data', 'Expected String or List<int>');
}
