import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Local processing bounds, checked before allocating the decoded pixel buffer.
const kMaximumEncodedImageBytes = 50 * 1024 * 1024;
const kMaximumImagePixels = 32 * 1024 * 1024;

/// Makes an actual JPEG for image context and edit uploads, without modifying
/// the original file. Existing valid, correctly oriented JPEGs remain lossless
/// across repeated turns. Alpha is composited on white when converting to JPEG.
Future<Uint8List> normalizeImageToJpeg(Uint8List bytes) =>
    normalizeImageEncoding(bytes, outputFormat: 'jpeg');

/// Validates and converts image pixels on a worker isolate. The format argument
/// names the encoded bytes, not merely an extension. Static image use takes the
/// first frame; EXIF orientation is baked before re-encoding when necessary.
/// Explicit target dimensions use contain-fit and centered padding, never crop
/// or stretch. Padding is white for JPEG and transparent for PNG/WebP.
Future<Uint8List> normalizeImageEncoding(
  Uint8List bytes, {
  required String outputFormat,
  int? targetWidth,
  int? targetHeight,
}) async {
  if (!const {'jpeg', 'png', 'webp'}.contains(outputFormat)) {
    throw const FormatException(
      'Image output format must be jpeg, png or webp.',
    );
  }
  if (bytes.isEmpty || bytes.length > kMaximumEncodedImageBytes) {
    throw const FormatException('Image data is empty or too large to process.');
  }
  if ((targetWidth == null) != (targetHeight == null) ||
      (targetWidth != null &&
          targetHeight != null &&
          (targetWidth <= 0 ||
              targetHeight <= 0 ||
              targetWidth * targetHeight > kMaximumImagePixels))) {
    throw const FormatException(
      'Both target image dimensions must be positive and within the pixel limit.',
    );
  }
  final transfer = TransferableTypedData.fromList([bytes]);
  return Isolate.run(
    () => _normalize(
      transfer.materialize().asUint8List(),
      outputFormat,
      targetWidth,
      targetHeight,
    ),
  );
}

Uint8List _normalize(
  Uint8List bytes,
  String outputFormat,
  int? targetWidth,
  int? targetHeight,
) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (decoder == null || info == null || info.width <= 0 || info.height <= 0) {
    throw const FormatException('The image data could not be decoded.');
  }
  if (info.width * info.height > kMaximumImagePixels) {
    throw const FormatException(
      'The image dimensions are too large to process.',
    );
  }
  final decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) {
    throw const FormatException('The image data could not be decoded.');
  }
  final orientation = decoded.exif.imageIfd.orientation;
  final needsOrientation = orientation != null && orientation != 1;
  // JPEG decoding already applies EXIF rotation and clears the decoded tag.
  // Inspect the source tag too, or a passthrough would retain stale dimensions
  // in the encoded header despite the correctly rotated decoded pixels.
  final encodedOrientation = decoder.format == img.ImageFormat.jpg
      ? img.decodeJpgExif(bytes)?.imageIfd.orientation
      : null;
  final decoderAppliedOrientation =
      encodedOrientation != null && encodedOrientation != 1;
  final wanted = switch (outputFormat) {
    'jpeg' => img.ImageFormat.jpg,
    'webp' => img.ImageFormat.webp,
    _ => img.ImageFormat.png,
  };
  var pixels = needsOrientation ? img.bakeOrientation(decoded) : decoded;
  final needsSize =
      targetWidth != null &&
      targetHeight != null &&
      (pixels.width != targetWidth || pixels.height != targetHeight);
  // Re-encoding a JPEG on every context replay would progressively lose detail.
  if (decoder.format == wanted &&
      !needsOrientation &&
      !decoderAppliedOrientation &&
      !needsSize &&
      info.numFrames <= 1) {
    return bytes;
  }
  if (outputFormat == 'jpeg' && pixels.hasAlpha) {
    final opaque = img.Image(
      width: pixels.width,
      height: pixels.height,
      numChannels: 3,
    );
    img.fill(opaque, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(opaque, pixels);
    pixels = opaque;
  }
  if (needsSize) {
    // An RGB source must gain an alpha channel before adding transparent padding.
    if (outputFormat != 'jpeg' && !pixels.hasAlpha) {
      pixels = pixels.convert(numChannels: 4);
    }
    pixels = img.copyResize(
      pixels,
      width: targetWidth,
      height: targetHeight,
      maintainAspect: true,
      backgroundColor: outputFormat == 'jpeg'
          ? img.ColorRgb8(255, 255, 255)
          : img.ColorRgba8(0, 0, 0, 0),
      interpolation: img.Interpolation.average,
    );
  }
  if (outputFormat == 'jpeg') {
    return img.encodeJpg(pixels, quality: 90);
  }
  if (outputFormat == 'webp') {
    return img.encodeWebP(
      pixels,
      singleFrame: true,
      lossless: false,
      quality: 90,
      method: 0,
    );
  }
  return img.encodePng(pixels, singleFrame: true);
}
