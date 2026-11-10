import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/android/android_bridge.dart';
import '../../platform/android/android_screen_capture.dart';
import '../../platform/media_capture.dart';
import 'glass.dart';

/// Android: starts/stops screen share (MediaProjection). While on, every
/// spoken turn carries the newest screen frame.
class ScreenShareButton extends StatelessWidget {
  const ScreenShareButton({super.key, this.size = 48, this.bridge});
  final double size;
  final AndroidBridge? bridge;

  Future<void> _toggle(BuildContext context, AndroidBridge b) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final state = b.screenCapture.value;
      final result = await AndroidScreenCapture(bridge: b).setSharing(!(state.active || state.pending));
      if (!result.ok || result.pending) {
        messenger?.showSnackBar(
          SnackBar(content: Text(result.error ?? result.message ?? 'Waiting for Android screen sharing consent.')),
        );
      }
    } on PlatformException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Screen share failed: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = bridge ?? AndroidBridge.instance;
    return ValueListenableBuilder<MediaCaptureState>(
      valueListenable: b.screenCapture,
      builder: (context, state, _) => GlassIconButton(
        key: const ValueKey('screen-share'),
        icon: state.pending
            ? Icons.hourglass_top
            : state.active
            ? Icons.screen_share
            : Icons.screen_share_outlined,
        tooltip: state.pending
            ? 'Cancel screen sharing request'
            : state.active
            ? 'Stop sharing the screen'
            : 'Share the screen with Woi',
        active: state.active,
        size: size,
        onPressed: () => _toggle(context, b),
      ),
    );
  }
}
