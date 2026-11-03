import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

/// A process attached to a terminal: a real PTY in the app, a plain pipe
/// process in tests (the native PTY library is not built for `flutter test`).
abstract class TermProcess {
  int get pid;

  /// Raw output bytes (PTYs merge stdout and stderr).
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int cols);

  /// Signals the whole process group (the child is a session leader).
  void kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

typedef TermProcessStarter =
    TermProcess Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      int rows,
      int columns,
    });

/// flutter_pty: forkpty + one blocking reader thread per PTY, so an idle
/// terminal costs no CPU (no polling).
class PtyTermProcess implements TermProcess {
  PtyTermProcess.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 24,
    int columns = 80,
  }) : _pty = Pty.start(
         executable,
         arguments: arguments,
         workingDirectory: workingDirectory,
         environment: environment,
         rows: rows,
         columns: columns,
       );

  final Pty _pty;

  @override
  int get pid => _pty.pid;
  @override
  Stream<Uint8List> get output => _pty.output;
  @override
  Future<int> get exitCode => _pty.exitCode;
  @override
  void write(Uint8List data) => _pty.write(data);
  @override
  void resize(int rows, int cols) {
    if (rows > 0 && cols > 0) _pty.resize(rows, cols);
  }

  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) => killGroup(pid, signal);
}

TermProcess startPty(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  int rows = 24,
  int columns = 80,
}) => PtyTermProcess.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  rows: rows,
  columns: columns,
);

/// Pipe-based stand-in (no TTY): used by tests (the PTY library is not
/// loaded under `flutter test`). Constructed synchronously; writes made
/// before the process is up are queued.
class PipeTermProcess implements TermProcess {
  PipeTermProcess.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    int rows = 24,
    int columns = 80,
  }) {
    final setsid = File('/usr/bin/setsid').existsSync() ? '/usr/bin/setsid' : null;
    _started = Process.start(
      setsid ?? executable,
      [if (setsid != null) ...['--wait', executable], ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
    );
    _started.then(
      (p) {
        _proc = p;
        var open = 2;
        void done() {
          if (--open == 0) _ctl.close();
        }

        p.stdout.listen((d) => _ctl.add(Uint8List.fromList(d)), onDone: done);
        p.stderr.listen((d) => _ctl.add(Uint8List.fromList(d)), onDone: done);
        for (final d in _queued) {
          p.stdin.add(d);
        }
        _queued.clear();
        p.exitCode.then(_exit.complete);
      },
      onError: (Object e) {
        _ctl.close();
        _exit.complete(-1);
      },
    );
  }

  late final Future<Process> _started;
  Process? _proc;
  final _queued = <Uint8List>[];
  final _ctl = StreamController<Uint8List>();
  final _exit = Completer<int>();

  @override
  int get pid => _proc?.pid ?? 0;
  @override
  Stream<Uint8List> get output => _ctl.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) {
    final p = _proc;
    if (p == null) {
      _queued.add(data);
    } else {
      p.stdin.add(data);
    }
  }

  @override
  void resize(int rows, int cols) {}
  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final p = _proc;
    if (p != null) {
      killGroup(p.pid, signal);
    } else {
      _started.then((p) => killGroup(p.pid, signal), onError: (Object _) {});
    }
  }
}

/// Signals the process group led by [pid] (forkpty/setsid children lead
/// their own), then the process itself.
void killGroup(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) {
  if (pid <= 0) return;
  if (Platform.isLinux || Platform.isAndroid || Platform.isMacOS) {
    try {
      Process.runSync('kill', ['-${signal.name.replaceFirst('SIG', '')}', '--', '-$pid']);
    } catch (_) {}
  }
  Process.killPid(pid, signal);
}
