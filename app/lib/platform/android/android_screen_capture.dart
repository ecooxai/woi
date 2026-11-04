
import 'package:flutter/services.dart';

import '../screen_capture.dart';
import 'android_bridge.dart';

/// Screenshots on Android, best source first:
///  1. the newest screen-share frame (MediaProjection, while sharing);
///  2. the accessibility service's takeScreenshot (Android 11+).
/// Turns get a screenshot automatically only while sharing is on (Woi is
/// usually the app in front otherwise); the assistant session attaches its
/// own assist screenshot.
class AndroidScreenCapture implements ScreenCapture {
  AndroidScreenCapture({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;

  final AndroidBridge _bridge;

  /// Per-turn auto screenshots: only while screen share runs.
  bool get autoCapture => _bridge.sharing.value;

  static Screenshot fromMap(Map<Object?, Object?> m) {
    final png = m['png']! as Uint8List;
    final w = (m['width'] as num).toInt();
    final h = (m['height'] as num).toInt();
    final ow = (m['originalWidth'] as num?)?.toInt() ?? w;
    final oh = (m['originalHeight'] as num?)?.toInt() ?? h;
    return Screenshot(png: png, width: w, height: h, originalWidth: ow, originalHeight: oh);
  }

  @override
  Future<Screenshot> capture({int maxWidth = 1280}) async {
    // Share frames would show the floating panel; the accessibility
    // screenshot hides it while capturing.
    if (_bridge.sharing.value && !_bridge.overlayVisible.value) {
      final m = await _bridge.call<Map<Object?, Object?>>('shareFrame', {'maxWidth': maxWidth});
      if (m != null) return fromMap(m);
    }
    try {
      final m = await _bridge.call<Map<Object?, Object?>>('a11yScreenshot', {'maxWidth': maxWidth});
      if (m != null) return fromMap(m);
    } on PlatformException catch (e) {
      throw StateError(
        'No screen source: screen share is off and the accessibility screenshot failed (${e.message}). '
        'Turn on screen share in Woi, or enable Woi under Settings > Accessibility.',
      );
    }
    throw StateError('No screenshot available');
  }
}
