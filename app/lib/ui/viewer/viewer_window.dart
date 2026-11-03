import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/linux/linux_audio_io.dart';
import '../../platform/linux/linux_media_viewer.dart';
import '../../platform/media_viewer.dart';
import 'viewer_app.dart';

/// Runs the viewer engine of a secondary window. The runner hides the window
/// on close instead of destroying it (destroying a secondary view crashes the
/// main window's GL on X11), so the window is reused: "open" swaps the item,
/// "hidden" (from the runner) drops it so playback stops. Esc closes.
void runViewer(MediaItem first, {MethodChannel window = const MethodChannel('woi/window')}) {
  final current = ValueNotifier<MediaItem?>(first);
  void setTitle(MediaItem item) =>
      window.invokeMethod<void>('setTitle', 'Woi - ${item.title}').catchError((Object _) {});
  setTitle(first);

  window.setMethodCallHandler((call) async {
    if (call.method == 'hidden') current.value = null;
  });
  WindowController.fromCurrentEngine()
      .then(
        (c) => c.setWindowMethodHandler((call) async {
          if (call.method != LinuxMediaViewer.openMethod) return null;
          final item = MediaItem.fromJson((call.arguments as Map).cast());
          current.value = item;
          setTitle(item);
          await window.invokeMethod<Object?>('present');
          return true;
        }),
      )
      .catchError((Object e) => debugPrint('viewer: no window controller: $e'));

  HardwareKeyboard.instance.addHandler((e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return false;
    window.invokeMethod<void>('close').catchError((Object _) {});
    return true;
  });

  final audio = LinuxAudioIO();
  runApp(
    ValueListenableBuilder<MediaItem?>(
      valueListenable: current,
      builder: (_, item, _) => item == null
          ? const ColoredBox(color: Color(0xFF05070D))
          : ViewerApp(key: ObjectKey(item), item: item, audio: audio),
    ),
  );
}
