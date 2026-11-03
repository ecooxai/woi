import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/android/android_bridge.dart';
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
      if (b.sharing.value) {
        await b.call<bool>('shareStop');
        b.sharing.value = false;
      } else {
        final ok = await b.call<bool>('shareStart') ?? false;
        if (!ok) messenger?.showSnackBar(const SnackBar(content: Text('Screen share was not allowed.')));
      }
    } on PlatformException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Screen share failed: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = bridge ?? AndroidBridge.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: b.sharing,
      builder: (context, on, _) => GlassIconButton(
        key: const ValueKey('screen-share'),
        icon: on ? Icons.screen_share : Icons.screen_share_outlined,
        tooltip: on ? 'Stop sharing the screen' : 'Share the screen with Woi',
        active: on,
        size: size,
        onPressed: () => _toggle(context, b),
      ),
    );
  }
}
