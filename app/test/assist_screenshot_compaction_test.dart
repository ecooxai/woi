import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/models/message.dart';

/// Regression for the Android "context at 112% and never compacts" bug: every
/// assist activation adds a standalone "Assist screenshot" system message, but
/// the raw window only counted user messages, so with few spoken turns all
/// screenshots stayed "recent" and nothing was ever compactable.

const _img = ImageAttachment(path: 'x', width: 1, height: 1, originalWidth: 1, originalHeight: 1);

Message _assist() => Message(kind: MessageKind.system, text: 'Assist screenshot', image: _img, meta: {'type': 'screenshot', kActivationMeta: true});

class _Compressor implements Compressor {
  final calls = <List<Message>>[];
  Object? failWith;

  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    calls.add(List.of(messages));
    final e = failWith;
    if (e != null) throw e;
    return const CompressionResult(summary: 'Screen: settings app, launcher.', tokensAfter: 8);
  }
}

/// The phone's pattern: a few spoken turns, then many activations without
/// speech (each just an assist screenshot, sometimes a short reply).
Conversation _phoneConversation() {
  final c = Conversation();
  for (var i = 0; i < 3; i++) {
    c.add(_assist());
    c.add(Message(kind: MessageKind.user, text: 'What is the capital of France?'));
    c.add(Message(kind: MessageKind.assistant, text: 'Paris.'));
  }
  for (var i = 0; i < 14; i++) {
    c.add(_assist());
  }
  return c;
}

void main() {
  group('rawTurnsStart', () {
    test('standalone screenshots start their own turn', () {
      final c = _phoneConversation();
      final cut = rawTurnsStart(c.messages, 3);
      // Only the last 3 activations stay raw.
      expect(cut, c.messages.length - 3);
    });

    test('an activation followed by speech belongs to that user turn', () {
      final c = Conversation()
        ..add(Message(kind: MessageKind.user, text: 'old'))
        ..add(Message(kind: MessageKind.assistant, text: 'reply'))
        ..add(_assist())
        ..add(Message(kind: MessageKind.user, text: 'what is this?'))
        ..add(Message(kind: MessageKind.assistant, text: 'A settings page.'));
      // One turn kept: it starts at its screenshot, not at the user message.
      expect(rawTurnsStart(c.messages, 1), 2);
    });

    test('user-only conversations are unchanged', () {
      final c = Conversation();
      for (var i = 0; i < 5; i++) {
        c
          ..add(Message(kind: MessageKind.user, text: 'q$i'))
          ..add(Message(kind: MessageKind.assistant, text: 'a$i'));
      }
      expect(rawTurnsStart(c.messages, 3), 4);
      expect(rawTurnsStart(c.messages.take(6).toList(), 3), 0);
    });
  });

  test('assist screenshots over the threshold get compacted into a description', () async {
    final compressor = _Compressor();
    final cm = ContextManager(compressor: compressor, threshold: 10000, minInterval: Duration.zero);
    final conv = _phoneConversation();
    cm.attach(conv);
    // 17 screenshots × 765 ≈ 13k tokens: over 100%, like the phone's 112%.
    expect(cm.fill, greaterThan(1.0));
    final run = cm.maybeCompress();
    expect(run, isNotNull, reason: 'compaction must start once over the threshold');
    await run;
    expect(compressor.calls, hasLength(1));
    final described = compressor.calls.single.where((m) => m.image != null).length;
    expect(described, 14);
    expect(conv.summary, contains('Screen:'));
    expect(cm.fill, lessThan(0.5));
    expect(cm.lastError, isNull);
    cm.dispose();
  });

  test('a failed compaction reports, backs off and retries on its own', () async {
    final compressor = _Compressor()..failWith = Exception('network down');
    final cm = ContextManager(compressor: compressor, minInterval: const Duration(milliseconds: 20));
    final conv = _phoneConversation();
    cm.attach(conv);
    final failures = <ContextCompactionFailed>[];
    final sub = cm.compactionFailures.listen(failures.add);

    await cm.maybeCompress();
    await Future<void>.delayed(Duration.zero);
    expect(failures.single.attempt, 1);
    expect(failures.single.retryIn, const Duration(milliseconds: 20));
    expect(cm.status, contains('Compaction failed'));
    expect(cm.retryDelay, const Duration(milliseconds: 20));

    // Retried by the timer without any new message.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(compressor.calls.length, greaterThanOrEqualTo(2));
    expect(cm.failures, greaterThanOrEqualTo(2));
    expect(cm.retryDelay, greaterThanOrEqualTo(const Duration(milliseconds: 40)));

    // Recovers: the next retry succeeds and clears the error.
    compressor.failWith = null;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(cm.lastError, isNull);
    expect(cm.failures, 0);
    expect(cm.status, isNull);
    expect(cm.fill, lessThan(1.0));
    await sub.cancel();
    cm.dispose();
  });

  test('backoff is capped', () {
    final cm = ContextManager(
      compressor: _Compressor(),
      minInterval: const Duration(seconds: 10),
      maxBackoff: const Duration(minutes: 5),
    );
    cm.failures = 1;
    expect(cm.retryDelay, const Duration(seconds: 10));
    cm.failures = 3;
    expect(cm.retryDelay, const Duration(seconds: 40));
    cm.failures = 30;
    expect(cm.retryDelay, const Duration(minutes: 5));
    cm.dispose();
  });
}
