import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../shell.dart';

/// `run_bash` on Android: `/system/bin/sh -c` (toybox) inside the app
/// sandbox. There is no setsid binary, so a timeout kills the shell and its
/// direct process group via `kill -- -pid` where possible.
class AndroidShell implements Shell {
  AndroidShell({required this.defaultWorkingDirectory, required this.environment});

  final String defaultWorkingDirectory;
  final Map<String, String> environment;

  static const shellPath = '/system/bin/sh';

  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) async {
    final sw = Stopwatch()..start();
    final proc = await Process.start(
      shellPath,
      ['-c', command],
      workingDirectory: workingDirectory ?? defaultWorkingDirectory,
      environment: environment,
    );
    unawaited(proc.stdin.close().catchError((_) {}));
    final out = StringBuffer();
    final err = StringBuffer();
    final cap = maxOutputChars * 4;
    final outDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) => out.length < cap ? out.write(s) : null)
        .asFuture<void>();
    final errDone = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) => err.length < cap ? err.write(s) : null)
        .asFuture<void>();
    var timedOut = false;
    int exitCode;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        Process.runSync('/system/bin/kill', ['-9', '--', '-${proc.pid}']);
      } catch (_) {}
      Process.killPid(proc.pid, ProcessSignal.sigkill);
      exitCode = await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -9);
    }
    await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    sw.stop();
    final (so, t1) = truncateMiddle(out.toString(), maxOutputChars);
    final (se, t2) = truncateMiddle(err.toString(), maxOutputChars ~/ 2);
    return ShellResult(
      exitCode: exitCode,
      stdout: so,
      stderr: se,
      elapsed: sw.elapsed,
      timedOut: timedOut,
      truncated: t1 || t2,
    );
  }
}
