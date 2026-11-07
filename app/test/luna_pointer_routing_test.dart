import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/pointer_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _PointerClient extends ResponsesClient {
  _PointerClient() : super(credentials: () async => null);
  final requests = <List<Map<String, Object?>>>[];
  Completer<ResponsesResult>? gate;
  String name = 'click_screen';
  ResponsesResult result() => ResponsesResult(
    text: '',
    status: 'completed',
    functionCalls: [
      FunctionCallItem(
        callId: 'luna-pointer',
        name: name,
        arguments: jsonEncode({
          'target_found': true,
          'x': 40,
          'y': 20,
          if (name == 'click_screen') ...{'button': 'left', 'double': false},
        }),
      ),
    ],
  );
  @override
  Future<ResponsesResult> pointerAction({
    required List<Map<String, Object?>> input,
    required String instructions,
    required List<Map<String, Object?>> tools,
  }) async {
    requests.add(input);
    return gate == null ? result() : await gate!.future;
  }
}

Future<void> _until(bool Function() done) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > const Duration(seconds: 5)) fail('Pointer routing did not settle.');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  for (final mode in BackendMode.values) {
    test('$mode exposes Luna pointer control and updates active schemas on toggle', () async {
      final platform = await FakePlatform.create();
      final client = _PointerClient();
      final backends = <ScriptedBackend>[];
      final controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        pointerClient: client,
        backendFactory: () {
          final backend = ScriptedBackend();
          backends.add(backend);
          return backend;
        },
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      addTearDown(() async {
        await controller.shutdown();
        await platform.dispose();
      });
      await controller.init();
      await controller.updateSettings(controller.settings.copyWith(backendMode: mode, autoScreenshot: false));
      if (backends.isEmpty) await controller.pipeline.connect();
      expect(controller.settings.useLunaPointer, isTrue);
      expect(backends.last.config!.tools.map((t) => t.name), contains('control_pointer'));
      final realtime = RealtimeWsBackend();
      addTearDown(realtime.close);
      final wire = realtime.sessionUpdate(backends.last.config!)['session'] as Map;
      expect((wire['tools'] as List).map((t) => t['name']), contains('control_pointer'));
      controller.notes.setText('Private note unrelated to this pointer request');
      final result = await controller.tools.dispatch(
        'control_pointer',
        jsonEncode({'action': 'click', 'request': 'Click the green button'}),
        callId: 'pointer-test',
      );
      expect(result.ok, isTrue, reason: result.json);
      expect(platform.input.log, ['click 80 40 left']);
      expect(client.requests, hasLength(1));
      expect(jsonEncode(client.requests.single), isNot(contains('Private note')));
      final shot = controller.pipeline.conversation.messages.singleWhere(
        (m) => m.meta['pointerCallId'] == 'pointer-test',
      );
      expect(shot.meta['type'], 'screenshot');
      expect(shot.image, isNotNull);

      final before = backends.last;
      await controller.updateSettings(controller.settings.copyWith(useLunaPointer: false));
      expect(backends.last, isNot(same(before)));
      expect(backends.last.config!.tools.map((t) => t.name), isNot(contains('control_pointer')));
      expect(
        (await controller.tools.dispatch('control_pointer', '{"action":"click","request":"Click Save"}')).ok,
        isFalse,
      );
      final raw = await controller.tools.dispatch('click_screen', '{"x":10,"y":20}');
      expect(raw.ok, isTrue, reason: raw.json);
      expect(platform.input.log.last, 'click 20 40 left');
      expect(client.requests, hasLength(1), reason: 'Disabled setting keeps the original coordinate handler.');

      await controller.updateSettings(controller.settings.copyWith(useLunaPointer: true));
      expect(backends.last.config!.tools.map((t) => t.name), contains('control_pointer'));
      controller.pipeline.sendText('Move the pointer to the green button');
      client.name = 'move_pointer';
      final move = await controller.tools.dispatch('move_pointer', '{"x":10,"y":20}', callId: 'move-test');
      expect(move.ok, isTrue, reason: move.json);
      expect(platform.input.log.last, 'move 80 40');
      expect(client.requests, hasLength(2), reason: 'The raw move tool cannot bypass enabled Luna.');
      final click = await controller.tools.dispatch('click_screen', '{"x":10,"y":20}', callId: 'click-test');
      expect(click.ok, isFalse, reason: 'A Luna move response must never execute for a click request.');
      expect(platform.input.log, hasLength(3));
    });
  }

  for (final stop in ['button', 'typed', 'spoken']) {
    test('$stop stop cancels a pending Luna action before native input', () async {
      final platform = await FakePlatform.create();
      final client = _PointerClient()..gate = Completer<ResponsesResult>();
      late ScriptedBackend backend;
      final controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        pointerClient: client,
        backendFactory: () => backend = ScriptedBackend(),
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      addTearDown(() async {
        await controller.shutdown();
        await platform.dispose();
      });
      await controller.init();
      await controller.updateSettings(controller.settings.copyWith(autoScreenshot: false));
      await controller.pipeline.connect();
      final pending = controller.tools.dispatch('control_pointer', '{"action":"click","request":"Click Save"}');
      await _until(() => client.requests.isNotEmpty);
      switch (stop) {
        case 'button':
          controller.pipeline.interrupt();
        case 'typed':
          controller.pipeline.sendText('stop');
        case 'spoken':
          backend.emit(const UserTranscriptDone('stop', itemId: 'spoken-stop'));
      }
      client.gate!.complete(client.result());
      final outcome = await pending;
      expect(outcome.ok, isFalse);
      expect(outcome.json, contains('cancelled'));
      expect(platform.input.log, isEmpty);
    });
  }

  test('screenshot metadata is merged when attaching to an existing user message', () async {
    final platform = await FakePlatform.create();
    final controller = AppController(
      platform: platform.services,
      confirmations: FakeConfirmations(),
      backendFactory: () => ScriptedBackend(),
      authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
    );
    addTearDown(() async {
      await controller.shutdown();
      await platform.dispose();
    });
    await controller.init();
    final message = Message(kind: MessageKind.user, text: 'Click Save', meta: {'preserved': true});
    controller.pipeline.conversation.add(message);
    await controller.pipeline.attachScreenshot(
      await platform.screen.capture(),
      note: 'fixture',
      to: message,
      meta: {'pointerCallId': 'existing-row'},
    );
    expect(message.meta['pointerCallId'], 'existing-row');
    expect(message.meta['preserved'], isTrue);
    expect(message.image, isNotNull);
  });

  test('single pointer intents bypass the general live model and pass clear request', () async {
    for (final text in [
      'Click the green Save button',
      'Could you right-click the folder?',
      'move the mouse pointer to the red circle',
      'Hover over Save',
    ]) {
      final calls = <(String, String, String)>[];
      final registry = ToolRegistry()
        ..register(
          pointerControlTool(
            enabled: () => true,
            control: (action, request, callId) async {
              calls.add((action, request, callId));
              return {'ok': true, 'action': action, 'model': 'gpt-6-luna', 'reasoning': 'none'};
            },
          ),
        );
      final model = FakeDelegationModel([]);
      final executor = DelegationExecutor(
        model: model,
        tools: registry.specs,
        runTool: (id, name, args) async => (await registry.dispatch(name, args, callId: id)).json,
        pinnedNote: () => 'Irrelevant private note',
        contextNote: () => 'Irrelevant older chat',
        fastModel: 'another-model',
        speculativeCapture: false,
      );
      final result = await executor.execute(text, id: 'pointer-route');
      expect(result.ok, isTrue);
      expect(result.model, 'gpt-6-luna');
      expect(model.requests, isEmpty);
      expect(calls, hasLength(1));
      expect(calls.single.$2, text);
      expect(calls.single.$3, 'pointer_pointer-route');
    }
  });

  test('disabled pointer agent uses the original general live planner', () async {
    final registry = ToolRegistry()
      ..register(
        pointerControlTool(enabled: () => false, control: (_, _, _) async => throw StateError('must not run')),
      )
      ..register(
        ToolDefinition(
          spec: const ToolSpec(name: 'click_screen', description: 'click', parameters: {'type': 'object'}),
          handler: (_, _) async => {'ok': true},
        ),
      );
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('click_screen', {'x': 1, 'y': 2}),
        ],
      ),
    ]);
    final executor = DelegationExecutor(
      model: model,
      tools: registry.specs,
      runTool: (id, name, args) async => (await registry.dispatch(name, args)).json,
      fastModel: 'selected-model',
      speculativeCapture: false,
    );
    final result = await executor.execute('Click Save');
    expect(result.ok, isTrue);
    expect(model.requests, hasLength(1));
    expect(model.requests.single.model, 'selected-model');
  });

  test('mixed requests stay with the planner and do not silently drop later work', () {
    for (final text in [
      'click Save then type hello',
      'click Save and press Enter',
      'move the pointer if the dialog opens',
      'click Save; click Close',
      'what happens if I click Save?',
      'move the file to Downloads',
    ]) {
      expect(pointerAction(text), isNull, reason: text);
    }
    expect(pointerAction('Click the Cancel button'), 'click');
    expect(pointerAction('Please move the cursor to the top right'), 'move');
  });
}
