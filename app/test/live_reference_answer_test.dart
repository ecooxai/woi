import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';

class _ReferenceGateModel extends DelegationModel {
  final pending = <Completer<DelegationModelTurn>>[];
  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) {
    final next = Completer<DelegationModelTurn>();
    pending.add(next);
    return next.future;
  }
}

void main() {
  final reference =
      'Original request: describe this image.\n'
      'Complete saved answer: ORCHID HARBOR ${'full observation with Unicode 🙂 ' * 220} batch739.';

  test('reference answer carries full data and exact question with no tools or context acquisition', () async {
    final model = FakeDelegationModel([const DelegationModelTurn(text: '  ORCHID HARBOR  ', calls: [])]);
    var hooks = 0;
    final executor = DelegationExecutor(
      model: model,
      tools: [const ToolSpec(name: 'run_bash', description: 'action', parameters: {})],
      runTool: (_, _, _) async {
        hooks++;
        return '{"ok":true}';
      },
      latestScreenshot: () {
        hooks++;
        return null;
      },
      contextImages: () {
        hooks++;
        return [];
      },
      contextNote: () {
        hooks++;
        return 'unrelated live context';
      },
      pinnedNote: () {
        hooks++;
        return 'unrelated pinned note';
      },
    );
    const question = 'What exact inspection label did the completed analysis contain? Answer with the label only.';
    final result = await executor.answerFromReference(question, referenceText: reference);
    expect(result.error, isNull);
    expect(result.answerText, 'ORCHID HARBOR');
    expect(result.tools, isEmpty);
    expect(hooks, 0);
    expect(model.requests, hasLength(1));
    expect(model.requests.single.tools, isEmpty);
    final content = model.requests.single.input.single['content']! as List;
    expect(content, hasLength(2));
    expect((content.first as Map)['text'], contains(reference));
    expect((content.last as Map)['text'], 'Current user question:\n$question');
    expect(reference.length, greaterThan(4000));
    expect(model.receivedInstructions.single, contains('rather than guessing'));
  });

  test('long terminal reference text is complete and never replaced with capped result text', () async {
    final answer = '${'Substantive full reference answer. ' * 200}Final code617.';
    final executor = DelegationExecutor(
      model: FakeDelegationModel([DelegationModelTurn(text: answer, calls: [])]),
      tools: [],
      runTool: (_, _, _) async => throw StateError('No tools allowed'),
      maxResultChars: 20,
    );
    final result = await executor.answerFromReference('Explain the analysis.', referenceText: reference);
    expect(result.answerText, answer);
    expect(result.resultText.length, 20);
    expect(result.resultText, endsWith('…'));
  });

  for (final toolAttempt in [false, true]) {
    test('empty final text or an unexpected tool request fails closed: $toolAttempt', () async {
      var ran = false;
      final executor = DelegationExecutor(
        model: FakeDelegationModel([
          DelegationModelTurn(
            text: toolAttempt ? 'I will do it.' : ' ',
            calls: toolAttempt
                ? [
                    call('run_bash', {'command': 'unexpected'}),
                  ]
                : [],
          ),
        ]),
        tools: [],
        runTool: (_, _, _) async {
          ran = true;
          return '{"ok":true}';
        },
      );
      final result = await executor.answerFromReference('What label?', referenceText: reference);
      expect(result.error, isNotNull);
      expect(result.answerText, isEmpty);
      expect(ran, isFalse);
      expect(result.tools, isEmpty);
    });
  }

  test('read-only timeout is bounded and a later model error is consumed', () async {
    final model = _ReferenceGateModel();
    final executor = DelegationExecutor(model: model, tools: [], runTool: (_, _, _) async => '{}');
    final result = await executor.answerFromReference(
      'What label?',
      referenceText: reference,
      timeout: const Duration(milliseconds: 5),
    );
    expect(result.error, isA<TimeoutException>());
    expect(result.answerText, isEmpty);
    model.pending.single.completeError(StateError('late provider failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test('Stop promptly releases the read-only wait; a later request uses a new cancellation epoch', () async {
    final model = _ReferenceGateModel();
    final executor = DelegationExecutor(model: model, tools: [], runTool: (_, _, _) async => '{}');
    final first = executor.answerFromReference('Old question.', referenceText: reference);
    expect(model.pending, hasLength(1));
    executor.cancelPending();
    final cancelled = await first.timeout(const Duration(seconds: 1));
    expect(cancelled.error, isNotNull);
    expect(cancelled.answerText, isEmpty);
    final next = executor.answerFromReference('Current question.', referenceText: reference);
    model.pending[1].complete(const DelegationModelTurn(text: 'Current answer.', calls: []));
    expect((await next).answerText, 'Current answer.');
    model.pending.first.completeError(StateError('retired late failure'));
    await Future<void>.delayed(Duration.zero);
  });
}
