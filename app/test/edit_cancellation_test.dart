import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_actions.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/fakes.dart';

const _calls = [
  DelegationToolCall(
    callId: 'review-edit',
    name: 'note_control',
    arguments: '{"action":"append","text":"- reviewed edit"}',
  ),
  DelegationToolCall(callId: 'continue-view', name: 'app_control', arguments: '{"action":"show_view","view":"chat"}'),
];

class _EditThenViewModel implements DelegationModel {
  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    for (final call in _calls) {
      onToolCall?.call(call);
    }
    return const DelegationModelTurn(text: '', calls: _calls);
  }

  @override
  void close() {}
}

// Keep the real controller, review queue and executor. This transport only
// supplies transcript events and forwards its cancellation API to the executor.
class _ApprovalBackend extends ScriptedBackend {
  DelegationExecutor? executor;

  @override
  void cancelPendingTools() => executor?.cancelPending();
}

void main() {
  late FakePlatform platform;
  late AppController controller;
  late _ApprovalBackend backend;
  late DelegationExecutor executor;

  setUp(() async {
    platform = await FakePlatform.create();
    controller = AppController(
      platform: platform.services,
      confirmations: FakeConfirmations(),
      backendFactory: () => backend = _ApprovalBackend(),
      authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
    );
    await controller.init();
    await controller.updateSettings(
      controller.settings.copyWith(
        autoScreenshot: false,
        editApplyDelay: kRequireApproval,
        idleStandbySeconds: 0,
        micMode: MicMode.muted,
      ),
    );
    executor = DelegationExecutor(
      model: _EditThenViewModel(),
      tools: controller.tools.specs,
      speculativeCapture: false,
      maxSteps: 1,
      runTool: (callId, name, args) async => (await controller.tools.dispatch(name, args, callId: callId)).json,
    );
    backend.executor = executor;
  });

  tearDown(() async {
    await controller.shutdown();
    await platform.dispose();
  });

  test('Stop during a quiet edit countdown prevents apply and queued continuation', () async {
    await controller.updateSettings(controller.settings.copyWith(editApplyDelay: 1));
    final before = controller.notes.text;
    final running = executor.execute('Carry out the two prepared steps.');
    await waitFor(() => controller.review.hasPending);
    expect(controller.review.current?.deadline, isNotNull);
    expect(controller.pipeline.conversation.messages.where((m) => m.kind == MessageKind.assistant), isEmpty);

    controller.pipeline.interrupt();
    final report = await running.timeout(const Duration(seconds: 3));
    expect(report.error, isNotNull);
    expect(controller.review.hasPending, isFalse);
    expect(controller.notes.text, before);
    expect(controller.actions.view.value, HomeView.note);
    expect(report.tools.map((tool) => tool.name), ['note_control']);
    expect(controller.review.apply(), isFalse, reason: 'The stopped edit cannot be applied later.');

    await Future<void>.delayed(const Duration(milliseconds: 1150));
    expect(controller.notes.text, before, reason: 'The original countdown must not write after Stop.');
    expect(controller.actions.view.value, HomeView.note);
  });

  for (final assistantActive in [false, true]) {
    test('spoken Apply ${assistantActive ? 'during an active assistant response' : 'while quiet'} '
        'completes the accepted edit and its legitimate queued continuation', () async {
      if (assistantActive) {
        await controller.updateSettings(controller.settings.copyWith(micMode: MicMode.handsFree));
      }
      final running = executor.execute('Carry out the two prepared steps.');
      await waitFor(() => controller.review.hasPending);
      expect(controller.notes.text, isNot(contains('- reviewed edit')));
      expect(controller.actions.view.value, HomeView.note);

      if (assistantActive) {
        backend.emit(const AssistantTranscriptDelta('The edit is ready for your approval.'));
        expect(
          controller.pipeline.conversation.messages.any((m) => m.kind == MessageKind.assistant && m.streaming),
          isTrue,
        );
      }
      final responseCancels = backend.cancels;
      backend.emit(const SpeechStarted(itemId: 'spoken-approval'));
      if (assistantActive) {
        expect(
          backend.cancels,
          greaterThan(responseCancels),
          reason: 'Apply first interrupts the active response before its transcript is known.',
        );
      }
      backend.emit(const SpeechStopped(itemId: 'spoken-approval'));
      backend.emit(const UserTranscriptDone('apply', itemId: 'spoken-approval'));

      final report = await running.timeout(const Duration(seconds: 3));
      expect(controller.review.hasPending, isFalse);
      expect(controller.notes.text.split('- reviewed edit'), hasLength(2), reason: 'The edit applies exactly once.');
      expect(controller.actions.view.value, HomeView.chat, reason: 'The accepted task can finish its next step.');
      expect(report.error, isNull);
      expect(report.tools.map((tool) => tool.name), ['note_control', 'app_control']);
      expect(report.tools.every((tool) => tool.ok), isTrue);
      expect(report.resultText, isNot(contains('cancelled')));
      expect(backend.stopDrops, greaterThan(0), reason: 'The local approval still suppresses its redundant reply.');
    });
  }
}
