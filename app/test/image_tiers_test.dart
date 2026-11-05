import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/models/message.dart';

const _img = ImageAttachment(path: 'x', width: 1280, height: 720, originalWidth: 2560, originalHeight: 1440);

Message _shot([String text = '']) =>
    Message(kind: MessageKind.system, text: text, image: _img, meta: {'type': 'screenshot'});

void main() {
  test('policy: newest 3 full, next 5 at 1/2, older described; never back up', () {
    const p = ImageTierPolicy(rawRecentTurns: 0);
    final msgs = [for (var i = 0; i < 10; i++) _shot('$i')];
    final plan = p.plan(msgs);
    expect(
      {for (final (m, t) in plan) m.text: t},
      {for (var i = 2; i <= 6; i++) '$i': ImageTier.reduced, '1': ImageTier.described, '0': ImageTier.described},
    );
    // Already reduced: only the ones that must go further are planned.
    for (final (m, t) in plan) {
      m.meta[ImageMeta.tier] = t.name;
    }
    expect(p.plan(msgs), isEmpty);
    msgs.add(_shot('10'));
    expect([for (final (m, t) in p.plan(msgs)) (m.text, t)], [('7', ImageTier.reduced), ('2', ImageTier.described)]);
    // Compacted messages are the summary's business.
    msgs.first.meta.remove(ImageMeta.tier);
    msgs.first.compacted = true;
    expect(p.plan(msgs).map((e) => e.$1.text), isNot(contains('0')));
  });

  test('rule: screenshots in the last 3 user turns stay raw; tiers apply to older turns only', () {
    const p = ImageTierPolicy();
    final msgs = <Message>[];
    // 4 turns, each: user (with screenshot) + 2 tool screenshots + assistant.
    for (var t = 0; t < 4; t++) {
      msgs.add(Message(kind: MessageKind.user, text: 'u$t', image: _img));
      msgs.add(_shot('t$t-a'));
      msgs.add(_shot('t$t-b'));
      msgs.add(Message(kind: MessageKind.assistant, text: 'a$t'));
    }
    expect(rawTurnsStart(msgs), 4, reason: 'turn 1 starts the raw part');
    final plan = {for (final (m, t) in p.plan(msgs)) m.text: t};
    // 9 newer screenshots (ages 0-8) are raw; turn 0's are ages 9-11 -> described.
    expect(plan, {'u0': ImageTier.described, 't0-a': ImageTier.described, 't0-b': ImageTier.described});
    // Three turns or fewer: nothing is old yet.
    expect(p.plan(msgs.sublist(4)), isEmpty);
    expect(rawTurnsStart(msgs.sublist(4)), 0);
  });

  group('context costs', () {
    late ContextManager cm;
    late Conversation conv;
    setUp(() {
      cm = ContextManager(
        compressor: StubCompressor(latency: Duration.zero),
        threshold: 1 << 30,
      );
      conv = Conversation();
      cm.attach(conv);
    });

    test('usage mode: reduced and described screenshots cost less; the meter shows the saving', () {
      for (var i = 0; i < 10; i++) {
        conv.add(_shot());
      }
      final before = cm.estimatedTokens;
      expect(before, 10 * (4 + 765));
      for (var i = 0; i < 2; i++) {
        conv.messages[i].meta
          ..[ImageMeta.tier] = 'described'
          ..[ImageMeta.description] = 'd' * 80;
      }
      for (var i = 2; i < 7; i++) {
        conv.messages[i].meta
          ..[ImageMeta.tier] = 'reduced'
          ..[ImageMeta.sentWidth] = 256
          ..[ImageMeta.sentHeight] = 144;
      }
      final after = cm.estimatedTokens;
      expect(after, 10 * 4 + 3 * 765 + 5 * 612 + 2 * (20 + 12));
      final p = cm.parts();
      expect(p.imageCount, 8);
      expect(p.imagesReduced, 5);
      expect(p.imagesDescribed, 2);
      expect(p.imagesSaved, before - after);
    });

    test('usage mode: a tier change after a usage report lowers the total right away', () {
      for (var i = 0; i < 4; i++) {
        conv.add(_shot());
      }
      cm.onUsage(8000); // calibrated scale = 8000 / (4 * 769)
      expect(cm.estimatedTokens, 8000);
      conv.messages.first.meta
        ..[ImageMeta.tier] = 'reduced'
        ..[ImageMeta.sentWidth] = 256
        ..[ImageMeta.sentHeight] = 144;
      final scale = 8000 / (4 * 769);
      expect(cm.estimatedTokens, 8000 - ((765 - 612) * scale).round());
    });

    test('text-only accounting: descriptions count, only the latest image does', () {
      cm.configure(accounting: ContextAccounting.textEstimate);
      for (var i = 0; i < 3; i++) {
        conv.add(_shot());
      }
      conv.messages.first.meta
        ..[ImageMeta.tier] = 'described'
        ..[ImageMeta.description] = 'd' * 40;
      expect(cm.estimatedTokens, 3 * 4 + 765 + 10 + 12);
    });

    test('reconnect / delegation context carries the descriptions', () {
      final u = Message(kind: MessageKind.user, text: 'what is this?', image: _img)
        ..meta[ImageMeta.tier] = 'described'
        ..meta[ImageMeta.description] = 'VS Code with main.dart open';
      expect(ContextManager.renderForContext(u), 'User: what is this? [screen: VS Code with main.dart open]');
      final s = _shot('Screen when the user spoke.')
        ..meta[ImageMeta.tier] = 'described'
        ..meta[ImageMeta.description] = 'A browser on example.com';
      expect(ContextManager.renderForContext(s), 'Earlier screen: A browser on example.com');
      expect(ContextManager.renderForContext(_shot('x')), isNull);
    });
  });
}
