import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';

class _GatedCompressor implements Compressor {
  final calls = <List<Message>>[];
  String? lastModel;
  Completer<void> gate = Completer<void>()..complete();

  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    calls.add(List.of(messages));
    lastModel = model;
    await gate.future;
    return CompressionResult(summary: 'S' * 40, tokensAfter: 10);
  }
}

Message _text(MessageKind k, int chars) => Message(kind: k, text: 'a' * chars);

void main() {
  late _GatedCompressor compressor;
  late ContextManager cm;
  late Conversation conv;

  setUp(() {
    compressor = _GatedCompressor();
    cm = ContextManager(compressor: compressor, threshold: 1000, keepRecent: 2, minInterval: Duration.zero);
    conv = Conversation();
    cm.attach(conv);
  });

  tearDown(() => cm.dispose());

  test('heuristic: chars/4 + overhead, images and audio add cost', () {
    final m = _text(MessageKind.user, 400);
    expect(cm.estimateMessage(m), 104);
    m.image = const ImageAttachment(path: 'x', width: 1, height: 1, originalWidth: 1, originalHeight: 1);
    expect(cm.estimateMessage(m), 104 + 765);
    m.audio = const AudioClip(path: 'a', durationMs: 3000);
    expect(cm.estimateMessage(m), 104 + 765 + 30);
    m.compacted = true;
    expect(cm.estimateMessage(m), 0);
  });

  test('uses usage totals plus heuristic for later messages', () {
    conv.add(_text(MessageKind.user, 40));
    cm.onUsage(500);
    expect(cm.estimatedTokens, 500);
    conv.add(_text(MessageKind.assistant, 80)); // 20 + 4
    expect(cm.estimatedTokens, 524);
  });

  test('stays quiet under the threshold', () {
    for (var i = 0; i < 4; i++) {
      conv.add(_text(MessageKind.user, 100));
    }
    expect(cm.maybeCompress(), isNull);
    expect(compressor.calls, isEmpty);
  });

  test('compacts in the background over threshold and reports before/after', () async {
    for (var i = 0; i < 6; i++) {
      conv.add(_text(i.isEven ? MessageKind.user : MessageKind.assistant, 1000)); // 254 each
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

    expect(compressor.calls.single, hasLength(4), reason: 'keeps the 2 most recent');
    expect(compressor.lastModel, 'gpt-6-luna');
    expect(conv.messages.where((m) => m.compacted), hasLength(4));
    expect(conv.summary, 'S' * 40);
    final e = events.single;
    expect(e.tokensBefore, before);
    expect(e.tokensAfter, 2 * 254 + 10);
    expect(e.compactedMessages, 4);
    expect(cm.estimatedTokens, e.tokensAfter);
    expect(cm.compressing, isFalse);
  });

  test('with usage reports, subtracts compacted messages via offset', () async {
    for (var i = 0; i < 6; i++) {
      conv.add(_text(MessageKind.user, 1000));
    }
    cm.threshold = 100000; // no auto-compaction on usage
    cm.onUsage(3000);
    conv.add(_text(MessageKind.user, 40)); // after usage: 14
    expect(cm.estimatedTokens, 3014);
    cm.keepRecent = 3;
    await cm.maybeCompress(force: true);
    // 4 compacted (all counted in usage) → -4*254 + summary 10.
    expect(cm.estimatedTokens, 3014 - 4 * 254 + 10);
  });

  test('onConversationChanged triggers compaction automatically', () async {
    final events = <ContextCompacted>[];
    cm.compactions.listen(events.add);
    for (var i = 0; i < 6; i++) {
      conv.add(_text(MessageKind.user, 1000));
      cm.onConversationChanged();
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(events, isNotEmpty);
  });

  test('never compacts streaming messages or system notes', () async {
    conv.add(Message(kind: MessageKind.system, text: 'x' * 4000));
    for (var i = 0; i < 4; i++) {
      conv.add(_text(MessageKind.user, 1000));
    }
    conv.messages[1].streaming = true;
    await cm.maybeCompress(force: true);
    final batch = compressor.calls.single;
    expect(batch.any((m) => m.kind == MessageKind.system), isFalse);
    expect(batch.any((m) => m.streaming), isFalse);
    expect(batch, hasLength(1));
  });

  test('switching conversations mid-compaction discards the result', () async {
    for (var i = 0; i < 6; i++) {
      conv.add(_text(MessageKind.user, 1000));
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
