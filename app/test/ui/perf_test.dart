import 'package:flutter_test/flutter_test.dart';
import 'package:woi/ui/perf.dart';

void main() {
  group('videoDecoders', () {
    test('default (direct rendering): fvp picks, hardware first', () {
      expect(videoDecoders({}), isNull);
      expect(videoDecoders({'WOI_SOFTWARE_GL': '0'}), isNull);
    });

    test('no DRI3 (runner sets WOI_SOFTWARE_GL=1): CPU decoders only', () {
      expect(videoDecoders({'WOI_SOFTWARE_GL': '1'}), ['FFmpeg', 'dav1d']);
      expect(videoDecoders({'LIBGL_ALWAYS_SOFTWARE': '1'}), ['FFmpeg', 'dav1d']);
    });

    test('WOI_VIDEO_DECODERS overrides either way', () {
      expect(videoDecoders({'WOI_VIDEO_DECODERS': ' VAAPI , FFmpeg ,', 'WOI_SOFTWARE_GL': '1'}), ['VAAPI', 'FFmpeg']);
      expect(videoDecoders({'WOI_VIDEO_DECODERS': ' , '}), isNull);
    });
  });

  group('videoTextureCap', () {
    test('small video: its own size, never upscaled to the screen', () {
      // fvp fits into the cap: a 640x640 cap holds 640x360 at 640x360.
      expect(videoTextureCap((1600, 1000), (640, 360)), (640, 640));
      expect(videoTextureCap((1600, 1000), (360, 640)), (640, 640));
    });

    test('large video: the screen limit', () {
      expect(videoTextureCap((1600, 1000), (3840, 2160)), (1600, 1000));
      expect(videoTextureCap((1920, 1080), (1280, 720)), (1280, 1080));
    });

    test('unknown size: the screen limit', () {
      expect(videoTextureCap((1600, 1000), null), (1600, 1000));
      expect(videoTextureCap((1600, 1000), (0, 0)), (1600, 1000));
    });
  });
}
