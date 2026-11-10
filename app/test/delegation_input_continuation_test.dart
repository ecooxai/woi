import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';

const _tools = [
  ToolSpec(name: 'control_pointer', description: 'pointer', parameters: {}),
  ToolSpec(name: 'click_screen', description: 'pointer', parameters: {}),
  ToolSpec(name: 'send_keys', description: 'keyboard', parameters: {}),
  ToolSpec(name: 'type_text', description: 'text', parameters: {}),
  ToolSpec(name: 'run_bash', description: 'command', parameters: {}),
  ToolSpec(name: 'read_file', description: 'read', parameters: {}),
];
const _request = 'In the editor, focus its text field, select all its text, and type exactly KEYBOARD-714.';
DelegationToolCall _focus(String id, [String field = 'first']) =>
    call('control_pointer', {'action': 'click', 'request': 'Focus the $field field.'}, id: id);
DelegationToolCall _select(String id) => call('send_keys', {'keys': 'ctrl+a'}, id: id);
DelegationToolCall _type(String id, [String text = 'KEYBOARD-714']) => call('type_text', {'text': text}, id: id);
DelegationModelTurn _turn(List<DelegationToolCall> calls) => DelegationModelTurn(text: '', calls: calls);

class _Target {
  final calls = <(String, String, Map<String, Object?>)>[];
  final fields = {'first': 'alpha beta gamma', 'second': 'old second field'};
  String? focused;
  bool selected = false;
  bool failFocus = false;
  int downCount = 0;
  Completer<void>? focusStarted;
  Completer<void>? releaseFocus;

  Future<String> run(String id, String name, String argsJson) async {
    final args = Map<String, Object?>.from(jsonDecode(argsJson) as Map);
    calls.add((id, name, args));
    switch (name) {
      case 'control_pointer':
        if (failFocus) return '{"ok":false,"error":"synthetic focus failed"}';
        focused = '${args['request']}'.contains('second') ? 'second' : 'first';
        focusStarted?.complete();
        await releaseFocus?.future;
      case 'send_keys':
        if (args['keys'] == 'ArrowDown') {
          downCount++;
        } else {
          if (focused == null) throw StateError('No focused field');
          selected = true;
        }
      case 'type_text':
        if (focused == null) throw StateError('No focused field');
        fields[focused!] = selected ? args['text']! as String : '${fields[focused]}${args['text']}';
        selected = false;
    }
    return jsonEncode({'ok': true, 'delivery': 'dispatched', 'target': focused});
  }
}

DelegationExecutor _executor(DelegationModel model, _Target target, {int maxSteps = 4}) =>
    DelegationExecutor(model: model, tools: _tools, runTool: target.run, speculativeCapture: false, maxSteps: maxSteps);

class _GateModel extends FakeDelegationModel {
  _GateModel(super.turns);
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    if (requests.length == 1) {
      entered.complete();
      await release.future;
    }
    return super.respond(
      model: model,
      instructions: instructions,
      input: input,
      tools: tools,
      reasoningEffort: reasoningEffort,
      onToolCall: onToolCall,
    );
  }
}

void main() {
  test('focus result reaches the planner before the requested keyboard steps', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([_select('select-1'), _type('type-1')]),
      const DelegationModelTurn(text: 'Entered KEYBOARD-714.', calls: []),
    ]);
    final report = await _executor(model, target).execute(_request);
    expect(target.fields['first'], 'KEYBOARD-714');
    expect(target.calls.map((run) => run.$2), ['control_pointer', 'send_keys', 'type_text']);
    expect(target.calls.map((run) => run.$1).toSet(), hasLength(3));
    expect(model.requests, hasLength(3));
    expect(
      model.requests[1].input.where((item) => item['type'] == 'function_call_output').single['output'],
      contains('dispatched'),
    );
    expect(report.answerText, 'Entered KEYBOARD-714.');
    expect(report.error, isNull);
  });

  test('a failed focus stops the keyboard calls already queued in the same reply', () async {
    final target = _Target()..failFocus = true;
    final model = FakeDelegationModel([
      _turn([_focus('focus-1'), _select('select-1'), _type('type-1')]),
    ]);
    final report = await _executor(model, target).execute(_request);
    expect(target.calls.map((run) => run.$2), ['control_pointer']);
    expect(target.fields['first'], 'alpha beta gamma');
    expect(report.error, isNotNull);
    expect(report.resultText, contains('failed input'));
    expect(model.requests, hasLength(1));
  });

  test('a failed focus never opens another planner turn or retries the input', () async {
    final target = _Target()..failFocus = true;
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([_select('select-1'), _type('type-1')]),
    ]);
    final report = await _executor(model, target).execute(_request);
    expect(target.calls, hasLength(1));
    expect(model.requests, hasLength(1));
    expect(report.error, isNotNull);
    expect(report.resultText, contains('Known results'));
  });

  test('a previously dispatched input call ID cannot run again in a later turn', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([_focus('focus-1')]),
      _turn([_select('select-1'), _type('type-1')]),
    ]);
    final report = await _executor(model, target).execute(_request);
    expect(target.calls, hasLength(1));
    expect(model.requests, hasLength(2));
    expect(report.error, isNotNull);
    expect(report.resultText, contains('repeated input call'));
    expect(report.resultText, contains('Do not repeat dispatched calls'));
  });

  test('fresh call IDs can intentionally repeat the same key across planner turns', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([
        call('send_keys', {'keys': 'ArrowDown'}, id: 'down-1'),
      ]),
      _turn([
        call('send_keys', {'keys': 'ArrowDown'}, id: 'down-2'),
      ]),
      const DelegationModelTurn(text: 'Moved down twice.', calls: []),
    ]);
    final report = await _executor(model, target).execute('In the list, move down twice.');
    expect(target.downCount, 2);
    expect(target.calls.map((run) => run.$1), ['down-1', 'down-2']);
    expect(report.error, isNull);
  });

  test('fresh IDs can type the same text after focusing different fields', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1'), _select('select-1'), _type('type-1', 'SAME')]),
      _turn([_focus('focus-2', 'second'), _select('select-2'), _type('type-2', 'SAME')]),
      const DelegationModelTurn(text: 'Entered SAME in both fields.', calls: []),
    ]);
    final report = await _executor(model, target).execute('In the form, replace both fields with SAME.');
    expect(target.fields, {'first': 'SAME', 'second': 'SAME'});
    expect(report.error, isNull);
    expect(target.calls, hasLength(6));
  });

  test('the step bound stops remaining input with an explicitly incomplete outcome', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([_select('select-1')]),
      _turn([_type('type-1')]),
    ]);
    final report = await _executor(model, target, maxSteps: 2).execute(_request);
    expect(model.requests, hasLength(2));
    expect(target.calls.map((run) => run.$2), ['control_pointer', 'send_keys']);
    expect(target.fields['first'], 'alpha beta gamma');
    expect(report.error, isNotNull);
    expect(report.resultText, contains('step limit'));
    expect(report.resultText, contains('incomplete'));
    expect(report.resultText, startsWith('Failed:'));
  });

  test('input followed by observation at the step limit remains explicitly incomplete', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([
        call('read_file', {'path': 'synthetic-status.txt'}, id: 'verify-1'),
      ]),
      const DelegationModelTurn(text: 'Verified.', calls: []),
    ]);
    final report = await _executor(model, target, maxSteps: 2).execute(_request);
    expect(model.requests, hasLength(2));
    expect(target.calls.map((run) => run.$2), ['control_pointer', 'read_file']);
    expect(report.error, isNotNull);
    expect(report.resultText, contains('step limit'));
    expect(report.resultText, contains('incomplete'));
  });

  test('an observation-only step limit preserves its existing result contract', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([
        call('read_file', {'path': 'synthetic-status.txt'}, id: 'read-1'),
      ]),
    ]);
    final report = await _executor(model, target, maxSteps: 1).execute('What is in the synthetic status file?');
    expect(model.requests, hasLength(1));
    expect(target.calls.map((run) => run.$2), ['read_file']);
    expect(report.error, isNull);
  });

  test('Stop after a dispatched focus prevents every later input step', () async {
    final target = _Target()
      ..focusStarted = Completer<void>()
      ..releaseFocus = Completer<void>();
    final model = FakeDelegationModel([
      _turn([_focus('focus-1')]),
      _turn([_select('select-1'), _type('type-1')]),
    ]);
    final executor = _executor(model, target);
    final pending = executor.execute(_request);
    await target.focusStarted!.future;
    executor.cancelPending();
    target.releaseFocus!.complete();
    final report = await pending;
    expect(target.calls, hasLength(1));
    expect(model.requests, hasLength(1));
    expect(target.fields['first'], 'alpha beta gamma');
    expect(report.error, isNotNull);
    expect(report.resultText, contains('Do not repeat dispatched calls'));
  });

  test('Stop while the next planner reply waits prevents its queued keyboard calls', () async {
    final target = _Target();
    final model = _GateModel([
      _turn([_focus('focus-1')]),
      _turn([_select('select-1'), _type('type-1')]),
    ]);
    final executor = _executor(model, target);
    addTearDown(() {
      if (!model.release.isCompleted) model.release.complete();
    });
    final pending = executor.execute(_request);
    await Future.any([model.entered.future, pending.then((_) {})]);
    expect(model.entered.isCompleted, isTrue, reason: 'the focus result must allow the next bounded step');
    executor.cancelPending();
    model.release.complete();
    final report = await pending;
    expect(target.calls, hasLength(1));
    expect(target.fields['first'], 'alpha beta gamma');
    expect(report.error, isNotNull);
  });

  test('a plain pointer request keeps the direct one-action fast path', () async {
    final target = _Target();
    final model = FakeDelegationModel([]);
    final report = await _executor(model, target).execute('Click the first field.');
    expect(model.requests, isEmpty);
    expect(target.calls.map((run) => run.$2), ['control_pointer']);
    expect(report.steps, 1);
  });

  test('a mixed non-input mutation keeps the existing one-reply completion contract', () async {
    final target = _Target();
    final model = FakeDelegationModel([
      _turn([
        _focus('focus-1'),
        call('run_bash', {'command': 'echo synthetic'}, id: 'bash-1'),
      ]),
      _turn([_type('unexpected')]),
    ]);
    final report = await _executor(model, target).execute('In the editor, focus its field and run echo synthetic.');
    expect(target.calls.map((run) => run.$2), ['control_pointer', 'run_bash']);
    expect(model.requests, hasLength(1));
    expect(report.steps, 1);
  });
}
