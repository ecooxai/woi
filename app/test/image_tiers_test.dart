import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/responses/responses_client.dart' show inputImage;
import 'package:woi/core/util/image_mime.dart';

const _img = ImageAttachment(path: 'x', width: 1280, height: 720, originalWidth: 2560, originalHeight: 1440);

Message _shot([String text = '']) =>
    Message(kind: MessageKind.system, text: text, image: _img, meta: {'type': 'screenshot'});

void main() {
  _reducedTierEncodingTests();

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

/// A 1280x720 "screenshot": flat panels, rows of text-like strokes and a
/// noisy photo area, JPEG-encoded at q80 like a capture.
Uint8List _screenshotJpeg({int w = 1280, int h = 720}) {
  final r = math.Random(7);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int c;
      if (y < 40) {
        c = 0x30; // title bar
      } else if (x < 260) {
        c = 0xEE; // side panel
      } else if (x > 800 && y > 300) {
        c = (128 + 60 * math.sin(x / 37) * math.cos(y / 23) + r.nextInt(30)).round(); // photo
      } else {
        c = 0xFF;
      }
      // Text rows.
      if (y > 60 && y % 22 < 12 && x % 9 < 5 && r.nextInt(3) > 0 && !(x > 800 && y > 300)) c = 0x20;
      im.setPixelRgb(x, y, c, (c * 0.9).round(), (c * 0.8 + (x % 3)).round());
    }
  }
  return img.encodeJpg(im, quality: 80);
}

void _reducedTierEncodingTests() {
  group('reduced tier encoding', () {
    test('jpegDownscale: half size, JPEG at the configured quality, smaller than PNG', () async {
      final original = _screenshotJpeg();
      final q80 = await jpegDownscale(quality: () => 80)(original, 640, 360);
      expect(imageMimeOf(q80), 'image/jpeg');
      final decoded = img.decodeJpg(q80)!;
      expect((decoded.width, decoded.height), (640, 360));
      final png = img.encodePng(decoded);
      // ignore: avoid_print
      print('reduced 640x360: jpeg q80 ${q80.length} B, png ${png.length} B, original 1280x720 jpeg ${original.length} B');
      expect(q80.length, lessThan(png.length));
      expect(q80.length, lessThan(original.length));
      final q50 = await jpegDownscale(quality: () => 50)(original, 640, 360);
      expect(q50.length, lessThan(q80.length), reason: 'quality comes from the setting');
    });

    test('compactor saves the reduced copy as .jpg and sends image/jpeg', () async {
      final dir = Directory.systemTemp.createTempSync('woi_tiers');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/shot.jpg')..writeAsBytesSync(_screenshotJpeg());
      final m = Message(
        kind: MessageKind.system,
        text: 'shot',
        image: ImageAttachment(path: src.path, width: 1280, height: 720, originalWidth: 1280, originalHeight: 720),
        meta: {'type': 'screenshot'},
      );
      final saved = <String>[];
      Uint8List? sent;
      final c = ImageCompactor(
        policy: const ImageTierPolicy(fullCount: 0, reducedCount: 1, rawRecentTurns: 0),
        downscale: jpegDownscale(quality: () => 80),
        describe: (_, _) async => 'unused',
        save: (id, bytes, {String ext = 'png'}) async {
          final f = File('${dir.path}/$id.$ext')..writeAsBytesSync(bytes);
          saved.add(f.path);
          return f.path;
        },
      );
      await c.run(
        [m],
        apply: (m, {png, text}) async {
          sent = png;
          return true;
        },
      );
      expect(c.lastError, isNull);
      expect(imageTierOf(m), ImageTier.reduced);
      expect(saved.single, endsWith('_r2.jpg'));
      expect(m.meta[ImageMeta.sentPath], saved.single);
      expect(imageMimeOf(File(saved.single).readAsBytesSync()), 'image/jpeg');
      expect(imageMimeOf(sent!), 'image/jpeg');
      expect(inputImage(sent!)['image_url'], startsWith('data:image/jpeg;base64,'));
    });

    test('a PNG downscale result keeps a .png name', () async {
      final dir = Directory.systemTemp.createTempSync('woi_tiers');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/shot.png')..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
      final m = Message(
        kind: MessageKind.system,
        text: '',
        image: ImageAttachment(path: src.path, width: 8, height: 8, originalWidth: 8, originalHeight: 8),
        meta: {'type': 'screenshot'},
      );
      await ImageCompactor(
        policy: const ImageTierPolicy(fullCount: 0, reducedCount: 1, rawRecentTurns: 0),
        downscale: (b, w, h) async => img.encodePng(img.Image(width: w, height: h)),
        describe: (_, _) async => 'unused',
        save: (id, bytes, {String ext = 'png'}) async => '${dir.path}/$id.$ext',
      ).run([m], apply: (m, {png, text}) async => false);
      expect(m.meta[ImageMeta.sentPath], endsWith('_r2.png'));
    });

    test('imageMimeOf / imageExtOf sniff JPEG, PNG, WebP', () {
      final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      final png = img.encodePng(img.Image(width: 1, height: 1));
      final webp = Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBPVP8 '.codeUnits]);
      expect([imageMimeOf(jpg), imageExtOf(jpg)], ['image/jpeg', 'jpg']);
      expect([imageMimeOf(png), imageExtOf(png)], ['image/png', 'png']);
      expect([imageMimeOf(webp), imageExtOf(webp)], ['image/webp', 'webp']);
    });
  });
}
