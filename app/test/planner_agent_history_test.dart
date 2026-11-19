import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/agents/agent_runs.dart';
import 'package:woi/core/agents/planner_runs.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/usage/model_guard.dart';
import 'package:woi/core/voice/backend_factory.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

const _tools = [
  ToolSpec(name: 'python', description: 'Synthetic calculation tool.', parameters: {'type': 'object'}),
];
const _call = DelegationToolCall(callId: 'provider-python', name: 'python', arguments: '{"code":"print(6 * 7)"}');

class _GateModel extends FakeDelegationModel {
  _GateModel() : super([]);
  final reply = Completer<DelegationModelTurn>();

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    requests.add((model: model, input: List.of(input), tools: tools));
    if (requests.length > 1) {
      return const DelegationModelTurn(text: 'The result is 42.', calls: []);
    }
    final turn = await reply.future;
    for (final call in turn.calls) {
      onToolCall?.call(call);
    }
    return turn;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual planner start and completion record model and full actual tool receipts without extra requests',
    () async {
      final store = AgentRunStore();
      addTearDown(store.dispose);
      final model = _GateModel();
      var executions = 0;
      const receipt = '{"ok":true,"stdout":"42\\n","stderr":"","exit_code":0}';
      final executor = DelegationExecutor(
        model: model,
        tools: _tools,
        observer: AgentPlannerRuns(store: store, conversationId: () => 'conversation'),
        runTool: (_, name, arguments) async {
          executions++;
          expect(name, 'python');
          expect(jsonDecode(arguments), {'code': 'print(6 * 7)'});
          return receipt;
        },
        speculativeCapture: false,
      );
      final pending = executor.execute('Calculate six times seven with Python.', id: 'planner-1');
      await Future<void>.delayed(Duration.zero);
      final run = store.runs.single;
      expect(run.status, AgentRunStatus.running);
      expect(run.model, kCheapModel);
      expect(run.toolName, 'voice_tool_planner');
      expect(run.canCancel, isTrue);
      model.reply.complete(const DelegationModelTurn(text: '', calls: [_call]));
      final report = await pending;
      expect(report.ok, isTrue);
      final baseline = FakeDelegationModel([
        const DelegationModelTurn(text: '', calls: [_call]),
        const DelegationModelTurn(text: 'The result is 42.', calls: []),
      ]);
      await DelegationExecutor(
        model: baseline,
        tools: _tools,
        runTool: (_, _, _) async => receipt,
        speculativeCapture: false,
      ).execute('Calculate six times seven with Python.', id: 'unobserved-baseline');
      expect(baseline.requests, hasLength(2));
      expect(
        model.requests,
        hasLength(baseline.requests.length),
        reason: 'observing the existing tool-result completion loop adds no model calls',
      );
      expect(
        model.requests.last.input.any((item) => item['type'] == 'function_call_output' && item['output'] == receipt),
        isTrue,
      );
      expect(executions, 1);
      expect(run.status, AgentRunStatus.completed);
      expect(run.canCancel, isFalse);
      expect(run.steps.single.result, receipt);
      final saved = jsonDecode(run.result!) as Map;
      final tool = (saved['tool_results'] as List).single as Map;
      expect(tool['call_id'], _call.callId);
      expect(tool['result'], jsonDecode(receipt));
    },
  );

  test('provider failure records failed actual planner with no invented tool result', () async {
    final store = AgentRunStore();
    addTearDown(store.dispose);
    final model = _GateModel();
    var tools = 0;
    final executor = DelegationExecutor(
      model: model,
      tools: _tools,
      observer: AgentPlannerRuns(store: store),
      runTool: (_, _, _) async {
        tools++;
        return '{"ok":true}';
      },
      speculativeCapture: false,
    );
    final pending = executor.execute('Calculate six times seven.', id: 'provider-error');
    await Future<void>.delayed(Duration.zero);
    model.reply.completeError(DelegationModelException('Synthetic provider denial', status: 403));
    final report = await pending;
    expect(report.ok, isFalse);
    expect(tools, 0);
    expect(store.runs.single.status, AgentRunStatus.failed);
    expect(store.runs.single.error, contains('Synthetic provider denial'));
    expect(jsonDecode(store.runs.single.result!)['tool_results'], isEmpty);
    expect(model.requests, hasLength(1));
  });

  test('cancelling one active planner blocks its late streamed tool calls', () async {
    final store = AgentRunStore();
    addTearDown(store.dispose);
    final model = _GateModel();
    var tools = 0;
    final executor = DelegationExecutor(
      model: model,
      tools: _tools,
      observer: AgentPlannerRuns(store: store),
      runTool: (_, _, _) async {
        tools++;
        return '{"ok":true}';
      },
      speculativeCapture: false,
    );
    final pending = executor.execute('Calculate a result.', id: 'cancel-me');
    await Future<void>.delayed(Duration.zero);
    expect(store.cancel(store.runs.single.id), isTrue);
    final report = await pending;
    expect(report.cancelled, isTrue);
    expect(store.runs.single.status, AgentRunStatus.cancelled);
    model.reply.complete(const DelegationModelTurn(text: '', calls: [_call]));
    await Future<void>.delayed(Duration.zero);
    expect(tools, 0);
    expect(model.requests, hasLength(1));
  });

  test('already dispatched child output survives global cancellation without claiming it was undone', () async {
    final store = AgentRunStore();
    addTearDown(store.dispose);
    final child = Completer<String>();
    final entered = Completer<void>();
    final executor = DelegationExecutor(
      model: FakeDelegationModel([
        const DelegationModelTurn(text: '', calls: [_call]),
      ]),
      tools: _tools,
      observer: AgentPlannerRuns(store: store),
      runTool: (_, _, _) {
        entered.complete();
        return child.future;
      },
      speculativeCapture: false,
    );
    final pending = executor.execute('Calculate a result.', id: 'child-in-flight');
    await entered.future;
    final run = store.runs.single;
    expect(run.canCancel, isFalse, reason: 'the child owns its cancellation capability');
    executor.cancelPending();
    const receipt = '{"ok":true,"stdout":"completed action","exit_code":0}';
    child.complete(receipt);
    final report = await pending;
    expect(report.cancelled, isTrue);
    expect(run.status, AgentRunStatus.cancelled);
    expect(run.steps.single.result, receipt);
    expect(jsonDecode(run.result!)['tool_results'].single['result'], jsonDecode(receipt));
    expect(run.error, contains('completed actions are preserved'));
  });

  test('deterministic fast paths and saved reference answers do not create fake planner history', () async {
    final store = AgentRunStore();
    addTearDown(store.dispose);
    final model = FakeDelegationModel([const DelegationModelTurn(text: 'A saved reference answer.', calls: [])]);
    final executor = DelegationExecutor(
      model: model,
      tools: const [
        ToolSpec(name: 'type_text', description: 'type', parameters: {'type': 'object'}),
      ],
      observer: AgentPlannerRuns(store: store),
      runTool: (_, _, _) async => '{"ok":true,"delivery":"applied"}',
      speculativeCapture: false,
    );
    await executor.execute("Type 'hello'.");
    expect(model.requests, isEmpty);
    expect(store.runs, isEmpty);
    await executor.answerFromReference('What was saved?', referenceText: 'Synthetic saved reference.');
    expect(model.requests, hasLength(1));
    expect(store.runs, isEmpty);
  });

  test('AppController passes planner history through the actual backend factory context', () async {
    final platform = await FakePlatform.create();
    final previousBuilder = GptLiveHook.builder;
    BackendContext? captured;
    AppController? controller;
    addTearDown(() async {
      await controller?.shutdown();
      if (previousBuilder == null) {
        GptLiveHook.unregister();
      } else {
        GptLiveHook.register(previousBuilder);
      }
      await platform.dispose();
    });
    GptLiveHook.register((context) {
      captured = context;
      return ScriptedBackend();
    });
    await SettingsStore(platform.services.paths.settingsFile)
        .save(const AppSettings().copyWith(backendMode: BackendMode.gptLive, apiKey: 'synthetic-controller-test-key'));
    final app = AppController(
      platform: platform.services,
      confirmations: FakeConfirmations(),
      authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
    );
    controller = app;
    await app.init();
    expect(app.initError, isNull);
    expect(captured?.delegationObserver, isA<AgentPlannerRuns>());
    final planner = DelegationExecutor(
      model: FakeDelegationModel([
        const DelegationModelTurn(text: '', calls: [_call]),
      ]),
      tools: _tools,
      observer: captured!.delegationObserver,
      runTool: (_, _, _) async => '{"ok":true,"stdout":"42","exit_code":0}',
      speculativeCapture: false,
    );
    await planner.execute('Calculate six times seven.', id: 'controller-planner');
    expect(app.agents.runs.single.toolName, 'voice_tool_planner');
    expect(app.agents.runs.single.status, AgentRunStatus.completed);
    expect(app.agents.runs.single.conversationId, app.pipeline.conversation.id);
    await app.agents.flush();
  });
}
