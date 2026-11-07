import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/images/image_encoding.dart';
import 'package:woi/core/util/image_mime.dart';

void main() {
  test('PNG alpha becomes real JPEG pixels with a white background', () async {
    final pixels = img.Image(width: 7, height: 5, numChannels: 4);
    final source = img.encodePng(pixels);
    final jpeg = await normalizeImageToJpeg(source);
    expect(imageMimeOf(source), 'image/png');
    expect(imageMimeOf(jpeg), 'image/jpeg');
    expect(imageExtOf(jpeg), 'jpg');
    final decoded = img.decodeJpg(jpeg)!;
    expect(decoded.width, 7);
    expect(decoded.height, 5);
    expect(decoded.hasAlpha, isFalse);
    expect(decoded.getPixel(3, 2).r, greaterThanOrEqualTo(250));
    expect(decoded.getPixel(3, 2).g, greaterThanOrEqualTo(250));
    expect(decoded.getPixel(3, 2).b, greaterThanOrEqualTo(250));
  });

  test(
    'JPEG context replay preserves encoded bytes instead of losing quality',
    () async {
      final pixels = img.Image(width: 8, height: 6);
      img.fill(pixels, color: img.ColorRgb8(20, 100, 230));
      final jpeg = img.encodeJpg(pixels, quality: 93);
      expect(await normalizeImageToJpeg(jpeg), orderedEquals(jpeg));
      expect(
        await normalizeImageEncoding(
          jpeg,
          outputFormat: 'jpeg',
          targetWidth: 8,
          targetHeight: 6,
        ),
        orderedEquals(jpeg),
      );
    },
  );

  test(
    'normalization bakes EXIF rotation into pixels and dimensions',
    () async {
      final pixels = img.Image(width: 8, height: 6);
      pixels.exif.imageIfd.orientation = 6;
      final rotated = await normalizeImageToJpeg(img.encodeJpg(pixels));
      final decoded = img.decodeJpg(rotated)!;
      expect(decoded.width, 6);
      expect(decoded.height, 8);
      final encodedHeader = img.JpegDecoder().startDecode(rotated)!;
      expect(encodedHeader.width, 6);
      expect(encodedHeader.height, 8);
      expect(
        img.decodeJpgExif(rotated)?.imageIfd.orientation,
        anyOf(isNull, 1),
      );
      expect(decoded.exif.imageIfd.orientation, anyOf(isNull, 1));
      expect(await normalizeImageToJpeg(rotated), orderedEquals(rotated));
    },
  );

  test('landscape content fits the square JPEG without stretching or cropping', () async {
    final pixels = img.Image(width: 80, height: 40);
    for (final pixel in pixels) {
      pixel.setRgb(pixel.x < 40 ? 255 : 0, 0, pixel.x < 40 ? 0 : 255);
    }
    final result = await normalizeImageEncoding(
      img.encodePng(pixels),
      outputFormat: 'jpeg',
      targetWidth: 64,
      targetHeight: 64,
    );
    final decoded = img.decodeJpg(result)!;
    expect((decoded.width, decoded.height), (64, 64));
    final red = colorBounds(decoded, (p) => p.r > 180 && p.g < 80 && p.b < 80);
    final blue = colorBounds(decoded, (p) => p.b > 180 && p.g < 80 && p.r < 80);
    // The two original 40x40 squares remain square, complete, and side-by-side.
    expect(red.$1, closeTo(0, 1));
    expect(red.$2, closeTo(16, 1));
    expect(red.$3 - red.$1 + 1, closeTo(32, 2));
    expect(red.$4 - red.$2 + 1, closeTo(32, 2));
    expect(blue.$1, closeTo(32, 1));
    expect(blue.$2, closeTo(16, 1));
    expect(blue.$3 - blue.$1 + 1, closeTo(32, 2));
    expect(blue.$4 - blue.$2 + 1, closeTo(32, 2));
    for (final point in [(16, 8), (48, 8), (16, 55), (48, 55)]) {
      final pixel = decoded.getPixel(point.$1, point.$2);
      expect(pixel.r, greaterThan(245));
      expect(pixel.g, greaterThan(245));
      expect(pixel.b, greaterThan(245));
    }
  });

  test(
    'square content gains centered transparent padding for PNG and WebP',
    () async {
      final pixels = img.Image(width: 32, height: 32);
      img.fill(pixels, color: img.ColorRgb8(0, 200, 0));
      final source = img.encodePng(pixels);
      for (final format in ['png', 'webp']) {
        final bytes = await normalizeImageEncoding(
          source,
          outputFormat: format,
          targetWidth: 64,
          targetHeight: 32,
        );
        final decoded = img.decodeImage(bytes)!;
        expect((decoded.width, decoded.height), (64, 32));
        expect(decoded.hasAlpha, isTrue);
        expect(decoded.getPixel(8, 16).a, 0);
        expect(decoded.getPixel(55, 16).a, 0);
        final green = colorBounds(
          decoded,
          (p) => p.g > 150 && p.r < 80 && p.b < 80 && p.a > 200,
        );
        expect(green, (16, 0, 47, 31));
      }
    },
  );

  test('PNG and WebP selections also produce matching encoded bytes', () async {
    final jpeg = img.encodeJpg(img.Image(width: 8, height: 6));
    for (final format in ['png', 'webp']) {
      final bytes = await normalizeImageEncoding(jpeg, outputFormat: format);
      expect(imageMimeOf(bytes), 'image/$format');
      expect(imageExtOf(bytes), format);
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.width, 8);
      expect(decoded.height, 6);
    }
  });

  test(
    'invalid image data and unsupported encodings do not produce images',
    () async {
      await expectLater(
        normalizeImageToJpeg(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        normalizeImageEncoding(
          img.encodePng(img.Image(width: 1, height: 1)),
          outputFormat: 'svg',
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

(int, int, int, int) colorBounds(
  img.Image image,
  bool Function(img.Pixel) matches,
) {
  var left = image.width, top = image.height, right = -1, bottom = -1;
  for (final pixel in image) {
    if (!matches(pixel)) continue;
    if (pixel.x < left) left = pixel.x;
    if (pixel.y < top) top = pixel.y;
    if (pixel.x > right) right = pixel.x;
    if (pixel.y > bottom) bottom = pixel.y;
  }
  expect(right, greaterThanOrEqualTo(left));
  return (left, top, right, bottom);
}
