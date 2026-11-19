import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/agents/agent_runs.dart';
import 'package:woi/core/agents/luna_tool_executor.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/core/edits/edit_review.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_ops.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/usage/model_guard.dart';
import 'package:woi/platform/python_runner.dart';
import 'package:woi/platform/shell.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/note_tools.dart';
import 'package:woi/tools/python_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

class _Planner extends ResponsesClient {
  _Planner(this.requests) : super(credentials: () async => null);
  final List<Map<String, dynamic>> requests;

  @override
  Future<ResponsesResult> automaticToolAction({
    required List<Map<String, Object?>> input,
    required String instructions,
    required List<Map<String, Object?>> tools,
  }) async {
    final content = input.single['content'] as List;
    final request = (jsonDecode((content.single as Map)['text'] as String) as Map).cast<String, dynamic>();
    requests.add(request);
    return ResponsesResult(
      text: '',
      status: 'completed',
      functionCalls: [
        FunctionCallItem(
          callId: 'synthetic-child',
          name: request['tool'] as String,
          arguments: jsonEncode(request['arguments']),
        ),
      ],
    );
  }
}

class _Python implements PythonRunner {
  final codes = <String>[];
  final workingDirectories = <String>[];
  String stdout = '42\n';

  @override
  Future<ShellResult> run(
    String code, {
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputChars = 8000,
  }) async {
    codes.add(code);
    workingDirectories.add(workingDirectory);
    return ShellResult(exitCode: 0, stdout: stdout, stderr: '', elapsed: const Duration(milliseconds: 4));
  }
}

class _DelegateClient extends ResponsesClient {
  _DelegateClient() : super(credentials: () async => null);
  final models = <String>[];
  final inputs = <List<Map<String, Object?>>>[];
  final instructionsSeen = <String?>[];
  int callsPerStep = 1;

  @override
  Future<ResponsesResult> create({
    required String model,
    required List<Map<String, Object?>> input,
    String? instructions,
    List<Map<String, Object?>>? tools,
    Map<String, Object?>? reasoning,
    void Function(String delta)? onTextDelta,
    void Function(FunctionCallItem call)? onFunctionCall,
    bool parallelToolCalls = false,
  }) async {
    models.add(model);
    inputs.add(List.of(input));
    instructionsSeen.add(instructions);
    if (models.length == 1) {
      final calls = [
        for (var i = 0; i < callsPerStep; i++)
          FunctionCallItem(callId: 'nested-python-$i', name: 'python', arguments: '{"code":"print(6 * 7)","cwd":"~"}'),
      ];
      for (final call in calls) {
        onFunctionCall?.call(call);
      }
      return ResponsesResult(text: '', status: 'completed', functionCalls: calls);
    }
    return ResponsesResult(text: 'The calculation returned 42.', status: 'completed', functionCalls: const []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlatform platform;
  late FakeConfirmations inner;
  late NoteController notes;
  late EditReview review;
  late EditHistory history;
  late ReviewingConfirmations confirmations;
  late AgentRunStore store;
  late LunaToolExecutor executor;
  late ToolRegistry registry;
  late _Python python;
  late _DelegateClient delegateClient;
  late ResponsesDelegate delegate;
  late List<Map<String, dynamic>> planned;

  setUp(() async {
    platform = await FakePlatform.create();
    await Directory(platform.services.files.workspaceDir).create(recursive: true);
    inner = FakeConfirmations(approveWrites: false, approveCommands: false);
    notes = NoteController(store: NoteStore('${platform.root.path}/notes'));
    await notes.open('automatic-tools');
    review = EditReview(delaySeconds: () => kRequireApproval);
    history = EditHistory(
      backupRoot: '${platform.root.path}/backups',
      notes: notes,
      conversationId: () => 'automatic-tools',
    );
    confirmations = ReviewingConfirmations(inner: inner, review: review, history: history);
    planned = [];
    store = AgentRunStore();
    executor = LunaToolExecutor(
      store: store,
      clientFactory: () => _Planner(planned),
      conversationId: () => 'automatic-tools',
      sessionIdentity: () => 'test-session',
    );
    registry = ToolRegistry(interceptor: executor.dispatch);
    delegateClient = _DelegateClient();
    delegate = ResponsesDelegate(delegateClient, tools: () => registry, reasoningEffort: null);
    final env = ToolEnvironment(
      platform: platform.services,
      confirmations: confirmations,
      delegate: delegate,
      settings: () => const AppSettings(confirmBeforeBash: true, delegateModel: 'gpt-6.1-sol'),
      onScreenshot: (_, _) async {},
    );
    for (final definition in builtinTools(env)) {
      if (definition.name == 'python') continue;
      registry.register(definition);
    }
    python = _Python();
    registry.register(
      pythonTool(
        runner: python,
        files: platform.services.files,
        confirmations: confirmations,
        settings: () => const AppSettings(confirmBeforeBash: true),
      ),
    );
    for (final definition in noteTools(notes, review: review, history: history)) {
      registry.register(definition);
    }
  });

  tearDown(() async {
    await executor.shutdown();
    delegateClient.close();
    store.dispose();
    review.dispose();
    await notes.flush();
    notes.dispose();
    await platform.dispose();
  });

  test('automatic Bash and Python retain exact execution output without app confirmation', () async {
    final bash = await registry.dispatch('run_bash', '{"command":"echo automatic-result","cwd":"~"}', callId: 'bash');
    final script = await registry.dispatch('python', '{"code":"print(6 * 7)","cwd":"~"}', callId: 'python');
    expect(bash.status, ToolStatus.success);
    expect(jsonDecode(bash.json), containsPair('stdout', 'automatic-result\n'));
    expect(jsonDecode(bash.json), containsPair('exit_code', 0));
    expect(platform.shell.commands, ['echo automatic-result']);
    expect(platform.shell.cwds, [platform.root.path]);
    expect(script.status, ToolStatus.success);
    expect(jsonDecode(script.json), containsPair('stdout', '42\n'));
    expect(python.codes, ['print(6 * 7)']);
    expect(python.workingDirectories, [platform.root.path]);
    expect(inner.commandRequests, isEmpty);
    expect(planned.map((r) => r['tool']), ['run_bash', 'python']);
    expect(store.runs.every((r) => r.status == AgentRunStatus.completed), isTrue);
  });

  test('standalone tool dispatch retains existing command approval behavior', () async {
    final local = ToolRegistry()
      ..register(
        pythonTool(
          runner: python,
          files: platform.services.files,
          confirmations: inner,
          settings: () => const AppSettings(confirmBeforeBash: true),
        ),
      );
    final result = await local.dispatch('python', '{"code":"print(7)"}');
    expect(result.status, ToolStatus.denied);
    expect(python.codes, isEmpty);
    expect(inner.commandRequests.single, contains('print(7)'));
    expect(store.runs, isEmpty);
  });

  test('automatic write backs up existing content and undo restores it without pending review', () async {
    final file = File('${platform.services.files.workspaceDir}/example.txt');
    await file.writeAsString('original\n');
    final result = await registry.dispatch(
      'write_file',
      jsonEncode({'path': file.path, 'content': 'updated\n'}),
      callId: 'write',
    );
    expect(result.status, ToolStatus.success, reason: result.json);
    expect(await file.readAsString(), 'updated\n');
    expect(review.hasPending, isFalse);
    expect(inner.writeRequests, isEmpty);
    final applied = history.last as AppliedFileEdit;
    expect(await File(applied.backupPath!).readAsString(), 'original\n');
    expect(await history.undoLast(), contains('restored'));
    expect(await file.readAsString(), 'original\n');
    expect(store.runs.single.steps.single.result, result.json);
  });

  test('automatic notes execute immediately and retain exact read results and undo', () async {
    notes.applyEdit(NoteEditMode.replaceAll, text: 'Original\n');
    final changed = await registry.dispatch(
      'update_note',
      '{"mode":"append","text":"Decision: use Luna."}',
      callId: 'note-edit',
    );
    expect(changed.status, ToolStatus.success, reason: changed.json);
    expect(notes.text, contains('Decision: use Luna.'));
    expect(review.hasPending, isFalse);
    final read = await registry.dispatch('read_note', '{}', callId: 'note-read');
    expect(jsonDecode(read.json)['markdown'], notes.text);
    expect(planned.map((r) => r['tool']), ['update_note', 'read_note']);
    expect(history.last, isA<AppliedNoteEdit>());
    await history.undoLast();
    expect(notes.text, 'Original\n');
  });

  test('an explicit destructive note review still waits for its decision inside a worker', () async {
    notes.applyEdit(NoteEditMode.replaceAll, text: 'Keep this note\n');
    final scope = AutomaticToolScope(cancelled: () => false);
    final pending = scope.run(
      () => reviewNoteEdit(notes, review, '', summary: 'Delete whole note', requireApproval: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(review.hasPending, isTrue);
    expect(review.current!.requireApproval, isTrue);
    review.rejectAll();
    expect(await pending, isFalse);
    expect(notes.text, 'Keep this note\n');
    scope.close();
  });

  test('general delegation uses Luna once and forwards real nested tool receipts with its summary', () async {
    final result = await registry.dispatch(
      'delegate_task',
      '{"task":"Calculate 6 times 7 with Python."}',
      callId: 'general',
    );
    expect(result.status, ToolStatus.success, reason: result.json);
    expect(delegateClient.models, [kCheapModel, kCheapModel]);
    expect(delegateClient.instructionsSeen.first, contains('without another confirmation'));
    expect(planned, isEmpty, reason: 'the existing Luna delegate must not start a second planner');
    expect(python.codes, ['print(6 * 7)']);
    expect(inner.commandRequests, isEmpty);
    final payload = jsonDecode(result.json) as Map;
    expect(payload['output'], 'The calculation returned 42.');
    final receipt = (payload['tool_results'] as List).single as Map;
    expect(receipt['tool'], 'python');
    expect(receipt['status'], 'success');
    expect(receipt['result']['stdout'], '42\n');
    expect(receipt['result']['exit_code'], 0);
    final input = delegateClient.inputs.last;
    final output = input.singleWhere((item) => item['type'] == 'function_call_output');
    expect(jsonDecode(output['output'] as String), receipt['result']);
    expect(store.runs, hasLength(1));
    expect(store.runs.single.steps.map((s) => s.toolName), ['delegate_task', 'python']);
  });

  test('multiple bounded child receipts remain structured when their aggregate exceeds one tool limit', () async {
    python.stdout = 'x' * 8000;
    delegateClient.callsPerStep = 2;
    final result = await registry.dispatch(
      'delegate_task',
      '{"task":"Run the requested Python calculation twice."}',
      callId: 'large-receipts',
    );
    final payload = jsonDecode(result.json) as Map;
    expect(result.json.length, greaterThan(registry.maxResultChars));
    expect(payload['truncated'], isNull);
    final receipts = payload['tool_results'] as List;
    expect(receipts, hasLength(2));
    for (final receipt in receipts) {
      expect(receipt['result']['stdout'], python.stdout);
      expect(receipt['result']['exit_code'], 0);
    }
    expect(python.codes, hasLength(2));
    expect(store.runs.single.result, result.json);
  });
}
