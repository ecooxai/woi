import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../shell.dart';
import 'exec_util.dart';

/// Runs commands with `bash -c` in their own process group so a timeout
/// kills the whole tree.
class LinuxShell implements Shell {
  LinuxShell({this.defaultWorkingDirectory});

  final String? defaultWorkingDirectory;

  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) async {
    final sw = Stopwatch()..start();
    final setsid = which('setsid');
    final bash = which('bash') ?? '/bin/bash';
    final proc = setsid != null
        ? await Process.start(
            setsid,
            ['--wait', bash, '-c', command],
            workingDirectory: workingDirectory ?? defaultWorkingDirectory,
            environment: x11Env(),
          )
        : await Process.start(
            bash,
            ['-c', command],
            workingDirectory: workingDirectory ?? defaultWorkingDirectory,
            environment: x11Env(),
          );
    // Nothing to feed on stdin; close so commands reading it don't hang.
    unawaited(proc.stdin.close().catchError((_) {}));

    final out = StringBuffer();
    final err = StringBuffer();
    final cap = maxOutputChars * 4; // keep memory bounded on runaway output
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
      _killTree(proc.pid, setsid != null);
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

  void _killTree(int pid, bool ownGroup) {
    if (ownGroup) {
      // setsid made the child a group leader: signal the whole group.
      Process.runSync('kill', ['-KILL', '--', '-$pid']);
    }
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}
