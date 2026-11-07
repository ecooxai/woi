import 'dart:io';

import '../core/models/message.dart';
import '../core/settings/settings.dart';
import '../core/voice/voice_backend.dart';
import '../platform/files.dart';
import '../platform/python_runner.dart';
import 'confirmation.dart';
import 'tool_registry.dart';

ToolDefinition pythonTool({
  required PythonRunner runner,
  required Files files,
  required ConfirmationService confirmations,
  required AppSettings Function() settings,
}) => ToolDefinition(
  spec: const ToolSpec(
    name: 'python',
    description:
        'Run Python 3 code for calculations or data processing. Always use this tool '
        'when a calculation is needed; print the result and answer from its output. '
        'Returns stdout, stderr and exit_code. Each call is independent. '
        'Use write_file/edit_file for requested file changes.',
    parameters: {
      'type': 'object',
      'properties': {
        'code': {
          'type': 'string',
          'description': 'Python source. Use print() to return results.',
        },
        'timeout_s': {
          'type': 'integer',
          'description': 'Default 30 seconds, maximum 300.',
        },
        'cwd': {
          'type': 'string',
          'description': 'Working directory; defaults to the workspace. ~ and \$HOME expand.',
        },
      },
      'required': ['code'],
      'additionalProperties': false,
    },
  ),
  handler: (args, call) async {
    final code = args.str('code');
    if (code.trim().isEmpty) throw ToolFailure('empty Python code');
    if (code.length > 65536) {
      throw ToolFailure('Python code exceeds 65536 characters');
    }
    final cwdArg = args.strOrNull('cwd');
    final cwd = cwdArg == null || cwdArg.trim().isEmpty
        ? files.workspaceDir
        : files.resolveExisting(cwdArg);
    if (!await Directory(cwd).exists()) {
      throw ToolFailure('working directory does not exist: $cwd');
    }
    // Python can perform the same operations as shell commands. Respect the
    // existing command approval preference instead of creating a bypass.
    if (settings().confirmBeforeBash) {
      call.onStatus?.call(ToolStatus.awaitingApproval);
      final allowed = await confirmations.confirmCommand('Python:\n$code');
      if (!allowed) throw ToolDenied('user rejected the Python code');
      call.onStatus?.call(ToolStatus.running);
    }
    final result = await runner.run(
      code,
      workingDirectory: cwd,
      timeout: Duration(seconds: args.integer('timeout_s', 30).clamp(1, 300)),
    );
    return {'ok': result.exitCode == 0 && !result.timedOut, ...result.toJson()};
  },
);
