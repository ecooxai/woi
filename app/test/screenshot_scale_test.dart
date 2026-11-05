import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/android/android_screen_capture.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/platform/screenshot_encode.dart';

void main() {
  group('screenshot settings', () {
    test('defaults: 50 % and JPEG 80', () {
      const d = AppSettings();
      expect(d.screenshotScale, 0.5);
      expect(d.screenshotJpegQuality, 80);
      expect(kDefaultScreenshotScale, 0.5);
      expect(kDefaultScreenshotJpegQuality, 80);
    });

    test('older settings.json without the keys loads the defaults', () {
      final s = AppSettings.fromJson({'autoScreenshot': true, 'screenshotDelayMs': 900});
      expect(s.screenshotScale, 0.5);
      expect(s.screenshotJpegQuality, 80);
      expect(s.screenshotDelayMs, 900);
    });

    test('round-trips through JSON', () {
      final s = const AppSettings().copyWith(screenshotScale: 0.25, screenshotJpegQuality: 65);
      final back = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.screenshotScale, 0.25);
      expect(back.screenshotJpegQuality, 65);
      final third = AppSettings.fromJson(
        jsonDecode(jsonEncode(const AppSettings().copyWith(screenshotScale: 1 / 3).toJson())) as Map<String, Object?>,
      );
      expect(third.screenshotScale, closeTo(1 / 3, 1e-9));
    });

    test('out-of-range or bad values are clamped / ignored', () {
      final s = AppSettings.fromJson({'screenshotScale': 4, 'screenshotJpegQuality': 5});
      expect(s.screenshotScale, 1.0);
      expect(s.screenshotJpegQuality, 50);
      final t = AppSettings.fromJson({'screenshotScale': 'big', 'screenshotJpegQuality': 120});
      expect(t.screenshotScale, 0.5);
      expect(t.screenshotJpegQuality, 100);
      expect(AppSettings.fromJson({'screenshotScale': 0}).screenshotScale, 0.5);
    });
  });

  group('screenshotSize', () {
    test('scales the physical pixels, keeps the aspect ratio', () {
      expect(screenshotSize(1080, 2400, 0.5), (540, 1200));
      expect(screenshotSize(1920, 1080, 0.5), (960, 540));
      expect(screenshotSize(2560, 1440, 0.25), (640, 360));
      expect(screenshotSize(1080, 2400, 1 / 3), (360, 800));
      expect(screenshotSize(1080, 2400, 0.75), (810, 1800));
      expect(screenshotSize(1080, 2400, 1), (1080, 2400));
      // Odd sizes round, aspect within a pixel.
      final (w, h) = screenshotSize(1366, 768, 0.5);
      expect((w, h), (683, 384));
    });

    test('never upscales; maxWidth caps', () {
      expect(screenshotSize(1080, 2400, 2), (1080, 2400));
      expect(screenshotSize(3840, 2160, 1, maxWidth: 1920), (1920, 1080));
      expect(screenshotSize(1920, 1080, 0.5, maxWidth: 1920), (960, 540));
      expect(screenshotSize(10, 10, 0.01), (1, 1));
    });
  });

  group('coordinate mapping at scale 0.5', () {
    final shot = Screenshot(png: Uint8List(0), width: 540, height: 1200, originalWidth: 1080, originalHeight: 2400);

    test('image pixels map back to screen pixels', () {
      expect(shot.scaleX, 2);
      expect(shot.scaleY, 2);
      expect(shot.toScreen(0, 0), const Point(0, 0));
      expect(shot.toScreen(270, 600), const Point(540, 1200));
      expect(shot.toScreen(540, 1200), const Point(1079, 2399), reason: 'clamped to the screen');
    });

    test('fromScreen is the inverse', () {
      expect(shot.fromScreen(540, 1200), const Point(270, 600));
      expect(shot.fromScreen(1080, 10), isNull);
    });
  });

  group('JPEG encode', () {
    test('RGB -> JPEG of the expected size, sniffed as JPEG', () async {
      const w = 96, h = 54;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < rgb.length; i += 3) {
        rgb[i] = (i ~/ 3) % w * 2;
        rgb[i + 1] = 128;
        rgb[i + 2] = 40;
      }
      final jpg = await jpegFromRgb(rgb, w, h, 80);
      expect(isJpegBytes(jpg), isTrue);
      expect(imageSize(jpg), (w, h));
      final s = Screenshot(png: jpg, width: w, height: h, originalWidth: w * 2, originalHeight: h * 2);
      expect(s.isJpeg, isTrue);
      expect(s.ext, 'jpg');
    });

    test('PNG -> scaled JPEG; lower quality is smaller', () async {
      final src = img.Image(width: 400, height: 300);
      for (final p in src) {
        p
          ..r = (p.x * 7 + p.y * 3) % 256
          ..g = (p.x * p.y) % 256
          ..b = (p.y * 5) % 256;
      }
      final png = img.encodePng(src);
      expect(imageSize(png), (400, 300));
      final (w, h) = screenshotSize(400, 300, 0.5);
      final q80 = await reencodeJpeg(png, w, h, 80);
      final q50 = await reencodeJpeg(png, w, h, 50);
      expect(imageSize(q80), (200, 150));
      expect(isJpegBytes(q80), isTrue);
      expect(q50.length, lessThan(q80.length));
      expect(q80.length, lessThan(png.length));
    });

    test('Android result map: JPEG bytes under "bytes", old "png" key still read', () {
      final jpg = encodeRgbJpegSync(Uint8List(8 * 4 * 3), 8, 4, 80);
      final s = AndroidScreenCapture.fromMap({
        'bytes': jpg,
        'width': 8,
        'height': 4,
        'originalWidth': 16,
        'originalHeight': 8,
      });
      expect(s.isJpeg, isTrue);
      expect(s.toScreen(4, 2), const Point(8, 4));
      final old = AndroidScreenCapture.fromMap({'png': Uint8List(4), 'width': 2, 'height': 2});
      expect(old.originalWidth, 2);
    });
  });
}
