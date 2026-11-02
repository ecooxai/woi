import 'dart:io';
import 'dart:typed_data';

import '../screen_capture.dart';
import 'exec_util.dart';

/// X11 full-screen capture via `ffmpeg -f x11grab` (~0.2 s for 1080p),
/// falling back to ImageMagick `import` (~0.6 s).
class LinuxScreenCapture implements ScreenCapture {
  (int, int)? _cachedGeometry;
  DateTime _geometryAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<(int, int)> _displayGeometry() async {
    final now = DateTime.now();
    if (_cachedGeometry != null &&
        now.difference(_geometryAt) < const Duration(seconds: 10)) {
      return _cachedGeometry!;
    }
    final xdo = which('xdotool');
    if (xdo != null) {
      final r = await runChecked(xdo, ['getdisplaygeometry'],
          environment: x11Env());
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
  Future<Screenshot> capture({int maxWidth = 1280}) async {
    final (ow, oh) = await _displayGeometry();
    Uint8List png;
    final ffmpeg = which('ffmpeg');
    if (ffmpeg != null) {
      final r = await runChecked(
        ffmpeg,
        [
          '-loglevel', 'error',
          '-f', 'x11grab',
          '-video_size', '${ow}x$oh',
          '-i', '${x11Display()}+0,0',
          '-frames:v', '1',
          '-vf', "scale='min($maxWidth,iw)':-2:flags=bicubic",
          '-compression_level', '1',
          '-f', 'image2pipe',
          '-c:v', 'png',
          '-',
        ],
        environment: x11Env(),
        binary: true,
      );
      png = Uint8List.fromList(r.stdout as List<int>);
    } else if (which('import') != null) {
      final r = await runChecked(
        'import',
        ['-window', 'root', '-resize', '${maxWidth}x>', '-depth', '8', 'png:-'],
        environment: x11Env(),
        binary: true,
      );
      png = Uint8List.fromList(r.stdout as List<int>);
    } else {
      throw MissingTool(['ffmpeg', 'import']);
    }
    final size = pngSize(png);
    if (size == null) {
      throw const FileSystemException('Screenshot tool returned invalid PNG');
    }
    return Screenshot(
      png: png,
      width: size.$1,
      height: size.$2,
      originalWidth: ow,
      originalHeight: oh,
    );
  }
}
