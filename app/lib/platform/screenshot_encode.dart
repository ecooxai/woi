import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// JPEG-encodes packed RGB24 pixels ([width]x[height]) off the UI thread.
Future<Uint8List> jpegFromRgb(Uint8List rgb, int width, int height, int quality) =>
    Isolate.run(() => encodeRgbJpegSync(rgb, width, height, quality));

Uint8List encodeRgbJpegSync(Uint8List rgb, int width, int height, int quality) {
  if (rgb.length < width * height * 3) {
    throw ArgumentError('rgb buffer ${rgb.length} B < ${width}x$height x 3');
  }
  final im = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    bytesOffset: rgb.offsetInBytes,
    numChannels: 3,
  );
  return img.encodeJpg(im, quality: quality.clamp(1, 100));
}

/// Decodes [encoded] (PNG/JPEG/...), resizes to [width]x[height] when it
/// differs, and JPEG-encodes at [quality] -- in an isolate.
Future<Uint8List> reencodeJpeg(Uint8List encoded, int width, int height, int quality) =>
    Isolate.run(() => reencodeJpegSync(encoded, width, height, quality));

Uint8List reencodeJpegSync(Uint8List encoded, int width, int height, int quality) {
  var im = img.decodeImage(encoded);
  if (im == null) throw const FormatException('screenshot: undecodable image');
  if (im.numChannels == 4 || im.hasAlpha) im = im.convert(numChannels: 3);
  if (im.width != width || im.height != height) {
    im = img.copyResize(im, width: width, height: height, interpolation: img.Interpolation.average);
  }
  return img.encodeJpg(im, quality: quality.clamp(1, 100));
}
