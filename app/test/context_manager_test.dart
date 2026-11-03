import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';

class _GatedCompressor implements Compressor {
  final calls = <List<Message>>[];
  String? lastModel;
  int summaryChars = 40;
  Completer<void> gate = Completer<void>()..complete();

  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    calls.add(List.of(messages));
    lastModel = model;
    await gate.future;
    return CompressionResult(summary: 'S' * summaryChars, tokensAfter: summaryChars ~/ 4);
  }
}

Message _text(MessageKind k, int chars) => Message(kind: k, text: 'a' * chars);

const _img = ImageAttachment(path: 'x', width: 1, height: 1, originalWidth: 1, originalHeight: 1);

/// user + assistant turn, each 254 tokens (1000 chars + 4).
void _turn(Conversation c, {bool screenshot = false}) {
  c.add(Message(kind: MessageKind.user, text: 'a' * 1000, image: screenshot ? _img : null));
  c.add(_text(MessageKind.assistant, 1000));
}

void main() {
  late _GatedCompressor compressor;
  late ContextManager cm;
  late Conversation conv;

  setUp(() {
    compressor = _GatedCompressor();
    cm = ContextManager(compressor: compressor, threshold: 1000, keepRecentTurns: 2, minInterval: Duration.zero);
    conv = Conversation();
    cm.attach(conv);
  });

  tearDown(() => cm.dispose());

  test('per message: chars/4 + 4, images, audio (assistant audio at twice the rate)', () {
    final m = _text(MessageKind.user, 400);
    expect(cm.estimateMessage(m), 104);
    m.image = _img;
    expect(cm.estimateMessage(m), 104 + 765);
    m.audio = const AudioClip(path: 'a', durationMs: 3000);
    expect(cm.estimateMessage(m), 104 + 765 + 30);
    final a = Message(
      kind: MessageKind.assistant,
      text: '',
      audio: const AudioClip(path: 'b', durationMs: 3000),
    );
    expect(cm.estimateMessage(a), 4 + 60);
    m.compacted = true;
    expect(cm.estimateMessage(m), 0);
  });

  test('error and status notes are UI only; screenshot notes count', () {
    expect(cm.estimateMessage(Message(kind: MessageKind.system, text: 'x' * 400, meta: {'type': 'error'})), 0);
    expect(cm.estimateMessage(Message(kind: MessageKind.system, text: 'x' * 400, meta: {'type': 'compaction'})), 0);
    expect(
      cm.estimateMessage(Message(kind: MessageKind.system, text: 'x' * 40, image: _img, meta: {'type': 'screenshot'})),
      14 + 765,
    );
  });

  test('overhead (instructions + tools) is part of the total', () {
    conv.add(_text(MessageKind.user, 40));
    cm.configure(accounting: ContextAccounting.usage, overheadTokens: 300);
    expect(cm.estimatedTokens, 300 + 14);
    expect(cm.parts().overhead, 300);
    expect(cm.parts().estimated, cm.estimatedTokens);
  });

  group('usage accounting (direct)', () {
    test('report + estimate of messages added since', () {
      conv.add(_text(MessageKind.user, 1000)); // 254
      cm.threshold = 100000;
      cm.onUsage(254);
      expect(cm.estimatedTokens, 254);
      expect(cm.measured, isTrue);
      conv.add(_text(MessageKind.assistant, 80)); // 24
      expect(cm.estimatedTokens, 278);
    });

    test('calibrates later estimates with report / estimate', () {
      cm
        ..threshold = 100000
        ..configure(accounting: ContextAccounting.usage, overheadTokens: 100);
      conv.add(_text(MessageKind.user, 1000)); // 254
      conv.add(_text(MessageKind.assistant, 1000)); // 254
      cm.onUsage(100 + 2 * 508); // messages cost twice the heuristic
      expect(cm.estimatedTokens, 1116);
      conv.add(_text(MessageKind.user, 80)); // 24 → 48
      expect(cm.estimatedTokens, 1116 + 48);
      final p = cm.parts();
      expect(p.text, 2 * (508 + 24), reason: 'breakdown uses the same calibration');
    });

    test('compaction before/after are the meter values and the after matches the formula', () async {
      cm.threshold = 100000;
      for (var i = 0; i < 4; i++) {
        _turn(conv, screenshot: true); // 254 + 765 + 254
      }
      cm.onUsage(4 * 1273);
      final events = <ContextCompacted>[];
      cm.compactions.listen(events.add);
      final before = cm.estimatedTokens;
      await cm.maybeCompress(force: true);
      await Future<void>.delayed(Duration.zero);
      final e = events.single;
      expect(e.tokensBefore, before);
      expect(e.tokensBefore, 4 * 1273);
      expect(e.tokensAfter, 2 * 1273 + 10);
      expect(cm.estimatedTokens, e.tokensAfter);
      expect(e.describedImages, 2);
      expect(e.substantial, isTrue);
      // Next report (old items deleted server-side) replaces the estimate.
      cm.onUsage(2600);
      expect(cm.estimatedTokens, 2600);
    });
  });

  group('text estimate (gpt-live)', () {
    setUp(() => cm.configure(accounting: ContextAccounting.textEstimate, overheadTokens: 500));

    test('no audio; only the latest screenshot (delegation input) counts', () {
      cm.threshold = 100000;
      conv.add(
        Message(
          kind: MessageKind.user,
          text: 'a' * 400,
          image: _img,
          audio: const AudioClip(path: 'a', durationMs: 5000),
        ),
      );
      conv.add(_text(MessageKind.assistant, 400));
      conv.add(Message(kind: MessageKind.system, text: '', image: _img, meta: {'type': 'screenshot'}));
      expect(cm.estimatedTokens, 500 + 104 + 104 + 4 + 765);
      cm.onUsage(99999);
      expect(cm.measured, isFalse, reason: 'gpt-live has no usage; reports are ignored');
      expect(cm.estimatedTokens, 500 + 104 + 104 + 4 + 765);
      final p = cm.parts();
      expect(p.imageCount, 1);
      expect(p.audio, 0);
      expect(p.estimated, p.total);
    });

    test('tool and delegation output count', () {
      conv.add(
        Message(
          kind: MessageKind.tool,
          tool: ToolCallInfo(callId: 'c', name: 'read_file', argsJson: 'a' * 40, resultJson: 'b' * 400),
        ),
      );
      expect(cm.estimatedTokens, 500 + 4 + 10 + 100 + 8);
    });
  });

  test('stays quiet under the threshold', () {
    for (var i = 0; i < 2; i++) {
      conv.add(_text(MessageKind.user, 100));
    }
    expect(cm.maybeCompress(), isNull);
    expect(compressor.calls, isEmpty);
  });

  test('keeps the last 2 user turns, compacts the rest in the background', () async {
    for (var i = 0; i < 3; i++) {
      _turn(conv);
    }
    final events = <ContextCompacted>[];
    cm.compactions.listen(events.add);
    compressor.gate = Completer<void>();
    final before = cm.estimatedTokens;
    expect(before, 6 * 254);

    final run = cm.maybeCompress();
    expect(run, isNotNull);
    expect(cm.compressing, isTrue, reason: 'runs in background');
    expect(cm.maybeCompress(), isNull, reason: 'one compaction at a time');
    compressor.gate.complete();
    await run;
    await Future<void>.delayed(Duration.zero);

    expect(compressor.calls.single, hasLength(2), reason: 'first turn only');
    expect(compressor.lastModel, 'gpt-6-luna');
    expect(conv.summary, 'S' * 40);
    final e = events.single;
    expect(e.tokensBefore, before);
    expect(e.tokensAfter, 4 * 254 + 10);
    expect(e.compactedMessages, 2);
    expect(cm.estimatedTokens, e.tokensAfter);
    expect(cm.compressing, isFalse);
  });

  test('screenshots (system messages) are compacted too, so the size drops substantially', () async {
    cm.threshold = 3000;
    for (var i = 0; i < 6; i++) {
      conv.add(_text(MessageKind.user, 200));
      conv.add(Message(kind: MessageKind.system, text: 'screen', image: _img, meta: {'type': 'screenshot'}));
      conv.add(_text(MessageKind.assistant, 200));
    }
    conv.add(Message(kind: MessageKind.system, text: 'Some error', meta: {'type': 'error'}));
    final events = <ContextCompacted>[];
    cm.compactions.listen(events.add);
    await cm.maybeCompress();
    await Future<void>.delayed(Duration.zero);
    final e = events.single;
    expect(compressor.calls.single.where((m) => m.image != null), hasLength(4));
    expect(compressor.calls.single.any((m) => m.meta['type'] == 'error'), isFalse);
    expect(e.describedImages, 4);
    expect(e.tokensAfter, lessThan(e.tokensBefore * 0.45));
    expect(e.tokensAfter, cm.estimatedTokens);
  });

  test('skips compactions that would free less than minGain', () {
    cm.threshold = 500;
    conv.add(_text(MessageKind.user, 40));
    conv.add(_text(MessageKind.user, 4000));
    conv.add(_text(MessageKind.user, 4000));
    expect(cm.maybeCompress(), isNull, reason: 'only 14 of ~2000 tokens are compactable');
    expect(cm.maybeCompress(force: true), isNotNull);
  });

  test('a summary that is not smaller than what it replaces is rejected', () async {
    compressor.summaryChars = 40000;
    for (var i = 0; i < 3; i++) {
      _turn(conv);
    }
    final events = <ContextCompacted>[];
    cm.compactions.listen(events.add);
    await cm.maybeCompress(force: true);
    expect(events, isEmpty);
    expect(conv.messages.any((m) => m.compacted), isFalse);
    expect(conv.summary, isNull);
    expect(cm.lastError, isA<StateError>());
  });

  test('onConversationChanged triggers compaction automatically', () async {
    final events = <ContextCompacted>[];
    cm.compactions.listen(events.add);
    for (var i = 0; i < 4; i++) {
      _turn(conv);
      cm.onConversationChanged();
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, isNotEmpty);
  });

  test('never compacts streaming messages or tools in flight', () async {
    _turn(conv);
    conv.add(
      Message(
        kind: MessageKind.tool,
        tool: ToolCallInfo(callId: 'c', name: 'run_bash', argsJson: '{}', status: ToolStatus.running),
      ),
    );
    _turn(conv);
    _turn(conv);
    conv.messages[1].streaming = true;
    await cm.maybeCompress(force: true);
    final batch = compressor.calls.single;
    expect(batch.any((m) => m.streaming), isFalse);
    expect(batch.any((m) => m.tool != null), isFalse);
    expect(batch, hasLength(1));
  });

  test('rule: by default the last 3 user turns (text + screenshots) are never compacted', () async {
    final def = ContextManager(compressor: compressor, threshold: 1000, minInterval: Duration.zero);
    final c = Conversation();
    def.attach(c);
    expect(def.keepRecentTurns, 3);
    for (var i = 0; i < 3; i++) {
      _turn(c, screenshot: true);
    }
    expect(def.maybeCompress(force: true), isNull, reason: 'only 3 turns: everything is raw');
    _turn(c, screenshot: true);
    c.add(Message(kind: MessageKind.system, text: 'screen', image: _img, meta: {'type': 'screenshot'}));
    await def.maybeCompress(force: true);
    final batch = compressor.calls.single;
    expect(batch, [c.messages[0], c.messages[1]], reason: 'only the oldest turn');
    expect(c.messages.skip(2).where((m) => m.compacted), isEmpty);
    expect(c.messages.skip(2).where((m) => m.image != null), hasLength(4), reason: 'raw images kept');
    def.dispose();
  });

  test('recentTurns renders the kept turns as text', () async {
    for (var i = 0; i < 3; i++) {
      conv.add(Message(kind: MessageKind.user, text: 'question $i'));
      conv.add(Message(kind: MessageKind.assistant, text: 'answer $i'));
    }
    await cm.maybeCompress(force: true);
    expect(cm.recentTurns(), 'User: question 1\nAssistant: answer 1\nUser: question 2\nAssistant: answer 2');
  });

  test('switching conversations mid-compaction discards the result', () async {
    for (var i = 0; i < 3; i++) {
      _turn(conv);
    }
    compressor.gate = Completer<void>();
    final run = cm.maybeCompress()!;
    final other = Conversation();
    cm.attach(other);
    compressor.gate.complete();
    await run;
    expect(conv.messages.any((m) => m.compacted), isFalse);
    expect(conv.summary, isNull);
  });
}
