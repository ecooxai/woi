import 'dart:math';
import 'dart:typed_data';

import 'camera.dart' show jpegSize;

class Screenshot {
  const Screenshot({
    required this.png,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
    this.originX = 0,
    this.originY = 0,
  });

  /// Encoded image at [width]x[height] (what the model sees): JPEG for
  /// conversation screenshots, PNG for lossless captures (see [isJpeg]).
  final Uint8List png;

  bool get isJpeg => isJpegBytes(png);

  /// File extension for [png].
  String get ext => isJpeg ? 'jpg' : 'png';
  final int width;
  final int height;

  /// Real screen size in pixels.
  final int originalWidth;
  final int originalHeight;

  /// Top-left of the captured area in screen coordinates.
  final int originX;
  final int originY;

  double get scaleX => width == 0 ? 1 : originalWidth / width;
  double get scaleY => height == 0 ? 1 : originalHeight / height;

  /// Maps a point in screenshot space back to real screen coordinates.
  Point<int> toScreen(num x, num y) => Point(
    (originX + x * scaleX).round().clamp(originX, originX + originalWidth - 1),
    (originY + y * scaleY).round().clamp(originY, originY + originalHeight - 1),
  );

  /// Maps a real screen point into this image's pixels (inverse of
  /// [toScreen]); null when it lies outside the captured area.
  Point<int>? fromScreen(num x, num y) {
    final ix = ((x - originX) / scaleX).round(), iy = ((y - originY) / scaleY).round();
    if (ix < 0 || iy < 0 || ix >= width || iy >= height) return null;
    return Point(ix, iy);
  }
}

/// Defaults for screenshots sent to the model (Settings > Screen & camera).
const kDefaultScreenshotScale = 0.5;
const kDefaultScreenshotJpegQuality = 80;

/// Scale choices offered in Settings.
const kScreenshotScales = [0.25, 1 / 3, 0.5, 0.75, 1.0];

abstract class ScreenCapture {
  /// Full-screen capture at [scale] x the screen's physical pixels (never
  /// upscaled, aspect kept), also capped at [maxWidth] when given.
  /// JPEG at [jpegQuality] (1-100); null: lossless PNG.
  Future<Screenshot> capture({
    double scale = kDefaultScreenshotScale,
    int? jpegQuality = kDefaultScreenshotJpegQuality,
    int? maxWidth,
  });
}

/// Size of a screenshot of a [ow]x[oh] screen at [scale] (and at most
/// [maxWidth] wide): aspect ratio kept, never larger than the screen, at
/// least 1x1. The Android side (WoiScreen.scaledSize) uses the same math.
(int, int) screenshotSize(int ow, int oh, double scale, {int? maxWidth}) {
  if (ow <= 0 || oh <= 0) return (ow.clamp(1, 1 << 30), oh.clamp(1, 1 << 30));
  final s = scale.isFinite && scale > 0 ? scale.clamp(0.01, 1.0) : 1.0;
  var w = (ow * s).round().clamp(1, ow);
  if (maxWidth != null && maxWidth > 0 && w > maxWidth) w = maxWidth;
  final h = w == ow ? oh : (oh * w / ow).round().clamp(1, oh);
  return (w, h);
}

bool isJpegBytes(Uint8List b) => b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;

/// Width/height of a PNG or JPEG; null if neither (or truncated).
(int, int)? imageSize(Uint8List b) => pngSize(b) ?? jpegSize(b);

/// Reads width/height from a PNG IHDR chunk; null if not a PNG.
(int, int)? pngSize(Uint8List png) {
  if (png.length < 24) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    if (png[i] != sig[i]) return null;
  }
  final bd = ByteData.sublistView(png);
  return (bd.getUint32(16), bd.getUint32(20));
}
