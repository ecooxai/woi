import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/agents/agent_runs.dart';
import 'package:woi/core/agents/luna_tool_executor.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/linux/linux_files.dart';
import 'package:woi/platform/linux/linux_shell.dart';
import 'package:woi/platform/python_runner.dart';
import 'package:woi/tools/python_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

/// Explicitly opt in to one real provider request using the existing Codex
/// login. Only a synthetic calculation and its isolated counter file are sent.
/// Run with --dart-define=WOI_LUNA_LIVE_SMOKE=true.
void main() {
  const enabled = bool.fromEnvironment('WOI_LUNA_LIVE_SMOKE');
  test(
    'actual Luna dispatches Python once and returns its complete raw receipt',
    () async {
      expect(Platform.isLinux, isTrue, reason: 'This smoke uses the real Linux Python runner.');
      final qa = await Directory('build/qa/luna-live').create(recursive: true);
      final fixture = await Directory('${qa.absolute.path}/case-${DateTime.now().microsecondsSinceEpoch}')
          .create(recursive: true);
      final store = AgentRunStore(path: '${fixture.path}/runs');
      await store.restore();
      final auth = CodexAuthManager();
      final executor = LunaToolExecutor(
        store: store,
        clientFactory: () => ResponsesClient(credentials: auth.credentials, timeout: const Duration(seconds: 60)),
        conversationId: () => 'synthetic-live-smoke',
        sessionIdentity: () => 'synthetic-live-session',
        preparationTimeout: const Duration(seconds: 60),
      );
      final confirmations = FakeConfirmations(approveCommands: false, approveWrites: false);
      final registry = ToolRegistry(interceptor: executor.dispatch);
      registry.register(
        pythonTool(
          runner: ShellPythonRunner(LinuxShell(defaultWorkingDirectory: fixture.path)),
          files: LocalFiles(homeDir: fixture.path, workspaceDir: fixture.path),
          confirmations: confirmations,
          settings: () => const AppSettings(confirmBeforeBash: true),
        ),
      );
      const code = '''
from pathlib import Path
counter = Path("executions.txt")
count = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(count + 1))
print(137 * 281)
''';
      final arguments = {'code': code, 'cwd': fixture.path, 'timeout_s': 10};
      final watch = Stopwatch()..start();
      final report = <String, Object?>{
        'synthetic_data_only': true,
        'provider': 'Codex Responses',
        'requested_model': 'gpt-6-luna',
        'status': 'failed',
      };
      try {
        final first = await registry.dispatch('python', jsonEncode(arguments), callId: 'synthetic-python-once');
        expect(first.ok, isTrue, reason: redactSecrets(first.json));
        final raw = (jsonDecode(first.json) as Map).cast<String, Object?>();
        expect(raw['stdout'], '38497\n');
        expect(raw.containsKey('stderr'), isFalse, reason: 'ShellResult omits empty stderr.');
        expect(raw['exit_code'], 0);
        expect(confirmations.commandRequests, isEmpty, reason: 'Routine automatic work must not ask again.');
        expect(confirmations.writeRequests, isEmpty);
        expect(store.runs, hasLength(1));
        final run = store.runs.single;
        expect(run.model, 'gpt-6-luna');
        expect(run.status, AgentRunStatus.completed);
        expect(run.result, first.json);
        expect(run.steps, hasLength(1));
        expect(run.steps.single.result, first.json);
        expect(jsonDecode(run.steps.single.arguments), arguments);

        final duplicate = await registry.dispatch('python', jsonEncode(arguments), callId: 'synthetic-python-once');
        expect(duplicate.json, first.json);
        expect(store.runs, hasLength(1));
        expect(await File('${fixture.path}/executions.txt').readAsString(), '1');
        await store.flush();
        expect(store.loadError, isNull);
        final restored = AgentRunStore(path: '${fixture.path}/runs');
        try {
          await restored.restore();
          expect(restored.loadError, isNull);
          expect(restored.runs, hasLength(1));
          expect(restored.runs.single.result, first.json);
          expect(restored.runs.single.status, AgentRunStatus.completed);
        } finally {
          restored.dispose();
        }
        report.addAll({
          'status': 'passed',
          'actual_stdout': raw['stdout'],
          'actual_exit_code': raw['exit_code'],
          'python_executions': 1,
          'persisted_runs': 1,
          'persisted_steps': 1,
          'same_receipt_for_duplicate_id': true,
          'result_survives_store_restart': true,
          'confirmation_requests': 0,
        });
      } catch (error) {
        final safe = redactSecrets('$error');
        report['error'] = safe.length > 1200 ? safe.substring(0, 1200) : safe;
        rethrow;
      } finally {
        await executor.shutdown();
        await store.flush();
        store.dispose();
        watch.stop();
        report['seconds'] = watch.elapsedMicroseconds / 1000000;
        await File('${qa.path}/result.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
