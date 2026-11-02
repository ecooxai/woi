class ShellResult {
  const ShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
    this.timedOut = false,
    this.truncated = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;
  final bool timedOut;
  final bool truncated;

  Map<String, Object?> toJson() => {
        'exit_code': exitCode,
        if (stdout.isNotEmpty) 'stdout': stdout,
        if (stderr.isNotEmpty) 'stderr': stderr,
        if (timedOut) 'timed_out': true,
        if (truncated) 'truncated': true,
        'ms': elapsed.inMilliseconds,
      };
}

abstract class Shell {
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  });
}

/// Keeps the head and tail of long output.
(String, bool) truncateMiddle(String s, int max) {
  if (s.length <= max) return (s, false);
  final head = (max * 0.75).floor();
  final tail = max - head;
  final cut = s.length - head - tail;
  return (
    '${s.substring(0, head)}\n…[$cut chars truncated]…\n'
        '${s.substring(s.length - tail)}',
    true
  );
}
