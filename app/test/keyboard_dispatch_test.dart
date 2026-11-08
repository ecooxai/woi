import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/send_keys_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

const _tools = [
  ToolSpec(name: 'send_keys', description: 'keys', parameters: {'type': 'object'}),
  ToolSpec(name: 'type_text', description: 'text', parameters: {'type': 'object'}),
];

void main() {
  for (final request in [
    (text: 'Ctrl+C', keys: 'Ctrl+C'),
    (text: 'Ctrl+V', keys: 'Ctrl+V'),
    (text: 'Ctrl+X', keys: 'Ctrl+X'),
    (text: 'Ctrl+A', keys: 'Ctrl+A'),
    (text: 'type Ctrl+C', keys: 'Ctrl+C'),
    (text: 'Type Ctrl+Alt+Shift+A', keys: 'Ctrl+Alt+Shift+A'),
    (text: 'type control alt shift a', keys: 'control alt shift a'),
    (text: 'Press Meta+Ctrl+Alt+Shift+V', keys: 'Meta+Ctrl+Alt+Shift+V'),
  ]) {
    test('explicit shortcut dispatches without a model: ${request.text}', () async {
      final model = FakeDelegationModel(const []);
      final calls = <(String, String)>[];
      final executor = DelegationExecutor(
        model: model,
        tools: _tools,
        runTool: (_, name, args) async {
          calls.add((name, args));
          return '{"ok":true}';
        },
      );
      final report = await executor.execute(request.text);
      expect(model.requests, isEmpty);
      expect(report.model, 'fast-path');
      expect(report.steps, 0);
      expect(calls.single.$1, 'send_keys');
      expect(jsonDecode(calls.single.$2), {'keys': request.keys});
      expect(looksLikeAction(request.text), isTrue);
    });
  }

  for (final request in ['type "Ctrl+C"', "type 'Ctrl+C'", 'type the text Ctrl+C']) {
    test('literal shortcut spelling remains text: $request', () async {
      final model = FakeDelegationModel(const []);
      final calls = <(String, String)>[];
      final executor = DelegationExecutor(
        model: model,
        tools: _tools,
        runTool: (_, name, args) async {
          calls.add((name, args));
          return '{"ok":true}';
        },
      );
      await executor.execute(request);
      expect(model.requests, isEmpty);
      expect(calls.single.$1, 'type_text');
      expect(jsonDecode(calls.single.$2), {'text': 'Ctrl+C'});
    });
  }

  test('shortcut target and exact terminal modifiers survive the fast path', () async {
    final input = FakeInput()..windowClass = 'xterm XTerm';
    final registry = ToolRegistry()..register(sendKeysTool(input));
    final model = FakeDelegationModel(const []);
    final executor = DelegationExecutor(
      model: model,
      tools: registry.specs,
      runTool: (id, name, args) async => (await registry.dispatch(name, args, callId: id)).json,
    );
    await executor.execute('type Ctrl+C in the xterm');
    await executor.execute('copy in the xterm');
    await executor.execute('type Ctrl+Alt+Shift+A in the xterm');
    expect(model.requests, isEmpty);
    expect(input.log, ['keys ctrl+c @xterm', 'keys ctrl+shift+c @xterm', 'keys ctrl+shift+alt+a @xterm']);
  });

  for (final request in [
    'What does Ctrl+C do?',
    'Explain Ctrl+Alt+Shift+A',
    'Ctrl+C?',
    'Ctrl+C then explain the selection',
    'type Ctrl+C and click Save',
    'press Ctrl+Alt+Shift',
    "don't press Ctrl+C",
  ]) {
    test('questions, mixed tasks, and invalid shortcuts keep the full request: $request', () async {
      expect(DelegationExecutor.keysFastPath(request), isNull);
      final model = FakeDelegationModel([const DelegationModelTurn(text: 'Needs interpretation.', calls: [])]);
      final calls = <String>[];
      final executor = DelegationExecutor(
        model: model,
        tools: _tools,
        runTool: (_, name, args) async {
          calls.add(name);
          return '{"ok":true}';
        },
      );
      await executor.execute(request);
      expect(calls, isEmpty);
      expect(model.requests, hasLength(1));
      final content = model.requests.single.input.single['content'] as List;
      expect(content.last['text'], request);
    });
  }
}
