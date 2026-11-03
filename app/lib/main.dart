import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'core/voice/live_register.dart';
import 'platform/linux/linux_audio_io.dart';
import 'platform/linux/linux_media_viewer.dart';
import 'platform/media_viewer.dart';
import 'ui/app.dart';
import 'ui/viewer/viewer_app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // In-app video (show_file) through libmdk; registered in every engine,
  // the viewer sub-window included (its plugins are registered by the runner).
  fvp.registerWith();

  // desktop_multi_window starts sub-windows with ['multi_window', id, argument].
  if (args.length >= 3 && args[0] == 'multi_window' && args[2].startsWith(LinuxMediaViewer.windowTag)) {
    final json = jsonDecode(args[2].substring(LinuxMediaViewer.windowTag.length));
    final item = MediaItem.fromJson((json as Map).cast<String, Object?>());
    // GTK ignores MaterialApp.title; the runner exposes the window title.
    const MethodChannel('woi/window').invokeMethod<void>('setTitle', viewerWindowTitle(item)).catchError((Object _) {});
    runApp(ViewerApp(item: item, audio: LinuxAudioIO()));
    return;
  }
  registerGptLive();
  runApp(const WoiApp());
}
