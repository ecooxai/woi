import 'dart:io';
import 'dart:typed_data';

import '../screen_capture.dart';
import '../screenshot_encode.dart';
import 'exec_util.dart';

/// X11 full-screen capture via `ffmpeg -f x11grab` (~0.2 s for 1080p),
/// falling back to ImageMagick `import` (~0.6 s).
class LinuxScreenCapture implements ScreenCapture {
  (int, int)? _cachedGeometry;
  DateTime _geometryAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<(int, int)> _displayGeometry() async {
    final now = DateTime.now();
    if (_cachedGeometry != null && now.difference(_geometryAt) < const Duration(seconds: 10)) {
      return _cachedGeometry!;
    }
    final xdo = which('xdotool');
    if (xdo != null) {
      final r = await runChecked(xdo, ['getdisplaygeometry'], environment: x11Env());
      final parts = '${r.stdout}'.trim().split(RegExp(r'\s+'));
      if (parts.length == 2) {
        _cachedGeometry = (int.parse(parts[0]), int.parse(parts[1]));
        _geometryAt = now;
        return _cachedGeometry!;
      }
    }
    final xr = which('xrandr');
    if (xr != null) {
      final r = await runChecked(xr, ['--current'], environment: x11Env());
      final m = RegExp(r'current (\d+) x (\d+)').firstMatch('${r.stdout}');
      if (m != null) {
        _cachedGeometry = (int.parse(m[1]!), int.parse(m[2]!));
        _geometryAt = now;
        return _cachedGeometry!;
      }
    }
    throw MissingTool(['xdotool', 'xrandr']);
  }

  @override
  Future<Screenshot> capture({
    double scale = kDefaultScreenshotScale,
    int? jpegQuality = kDefaultScreenshotJpegQuality,
    int? maxWidth,
  }) async {
    final (ow, oh) = await _displayGeometry();
    final (w, h) = screenshotSize(ow, oh, scale, maxWidth: maxWidth);
    final jpeg = jpegQuality != null;
    Uint8List bytes;
    final ffmpeg = which('ffmpeg');
    if (ffmpeg != null) {
      // JPEG: ffmpeg scales and hands over raw RGB; the JPEG is encoded at
      // the exact quality in an isolate (ffmpeg's mjpeg -q:v has no 1-100).
      final r = await runChecked(
        ffmpeg,
        [
          '-loglevel',
          'error',
          '-f',
          'x11grab',
          '-video_size',
          '${ow}x$oh',
          '-i',
          '${x11Display()}+0,0',
          '-frames:v',
          '1',
          if (w != ow || h != oh) ...['-vf', 'scale=$w:$h:flags=area'],
          if (jpeg) ...[
            '-pix_fmt',
            'rgb24',
            '-f',
            'rawvideo',
            '-',
          ] else ...[
            '-compression_level',
            '1',
            '-f',
            'image2pipe',
            '-c:v',
            'png',
            '-',
          ],
        ],
        environment: x11Env(),
        binary: true,
      );
      final out = Uint8List.fromList(r.stdout as List<int>);
      bytes = jpeg ? await jpegFromRgb(out, w, h, jpegQuality) : out;
    } else if (which('import') != null) {
      final r = await runChecked(
        'import',
        ['-window', 'root', '-resize', '${w}x$h!', '-depth', '8', 'png:-'],
        environment: x11Env(),
        binary: true,
      );
      final png = Uint8List.fromList(r.stdout as List<int>);
      bytes = jpeg ? await reencodeJpeg(png, w, h, jpegQuality) : png;
    } else {
      throw MissingTool(['ffmpeg', 'import']);
    }
    final size = imageSize(bytes);
    if (size == null) {
      throw const FileSystemException('Screenshot tool returned an invalid image');
    }
    return Screenshot(png: bytes, width: size.$1, height: size.$2, originalWidth: ow, originalHeight: oh);
  }
}
