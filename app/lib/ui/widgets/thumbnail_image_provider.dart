import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Bounds both decoded dimensions without enlarging the source image.
///
/// Flutter's fit policy can round an extreme portrait/panorama dimension to
/// zero. Clamp to one physical pixel after fitting, preserving the aspect
/// ratio to the precision available in a bitmap thumbnail.
class ThumbnailImage extends ResizeImage {
  const ThumbnailImage(super.imageProvider, {required int width, required int height})
    : assert(width > 0),
      assert(height > 0),
      super(width: width, height: height, policy: ResizeImagePolicy.fit);

  @override
  ImageStreamCompleter loadImage(ResizeImageKey key, ImageDecoderCallback decode) => super.loadImage(
    key,
    (ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) => decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        // Decoder metadata supplies positive integer dimensions. All fitting
        // arithmetic stays at or below the finite requested thumbnail bounds.
        final scale = math.min(1.0, math.min(width! / intrinsicWidth, height! / intrinsicHeight));
        return ui.TargetImageSize(
          width: math.max(1, (intrinsicWidth * scale).floor()),
          height: math.max(1, (intrinsicHeight * scale).floor()),
        );
      },
    ),
  );
}
