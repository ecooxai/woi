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
}
