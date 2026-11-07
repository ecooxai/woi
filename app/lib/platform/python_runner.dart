import 'shell.dart';

/// Executes Python without sharing an interpreter with the voice/UI process.
abstract class PythonRunner {
  Future<ShellResult> run(
    String code, {
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputChars = 8000,
  });
}

/// Desktop Python uses the shell's process-group timeout and bounded output.
/// Single quoting preserves Python source literally, including $ and newlines.
class ShellPythonRunner implements PythonRunner {
  const ShellPythonRunner(this.shell);
  final Shell shell;

  @override
  Future<ShellResult> run(
    String code, {
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputChars = 8000,
  }) => shell.run(
    "exec python3 -I -u -c '${code.replaceAll("'", "'\"'\"'")}'",
    workingDirectory: workingDirectory,
    timeout: timeout,
    maxOutputChars: maxOutputChars,
  );
}
