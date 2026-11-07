import 'package:flutter/services.dart';

import '../python_runner.dart';
import '../shell.dart';
import 'android_bridge.dart';

/// Bundled CPython runs in a separate Android service process. The native
/// deadline kills that process, including blocked code, without closing Woi.
class AndroidPythonRunner implements PythonRunner {
  const AndroidPythonRunner({this.channel = AndroidBridge.method});
  final MethodChannel channel;

  @override
  Future<ShellResult> run(
    String code, {
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputChars = 8000,
  }) async {
    final result = await channel.invokeMapMethod<String, Object?>('pythonRun', {
      'code': code,
      'cwd': workingDirectory,
      'timeout_ms': timeout.inMilliseconds,
      'max_output_chars': maxOutputChars,
    });
    if (result == null) throw StateError('Python returned no result');
    return ShellResult(
      exitCode: (result['exit_code'] as num?)?.toInt() ?? -1,
      stdout: result['stdout'] as String? ?? '',
      stderr: result['stderr'] as String? ?? '',
      elapsed: Duration(milliseconds: (result['ms'] as num?)?.toInt() ?? 0),
      timedOut: result['timed_out'] == true,
      truncated: result['truncated'] == true,
    );
  }
}
