import 'dart:math';
import 'dart:typed_data';

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

  /// PNG bytes at [width]x[height] (what the model sees).
  final Uint8List png;
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

abstract class ScreenCapture {
  /// Full-screen capture, downscaled so width <= [maxWidth].
  Future<Screenshot> capture({int maxWidth = 1280});
}

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
