import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'core/voice/live_register.dart';
import 'platform/android/android_platform.dart';
import 'platform/linux/linux_media_viewer.dart';
import 'platform/media_viewer.dart';
import 'ui/app.dart';
import 'ui/viewer/viewer_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // In-app video (show_file) through libmdk; registered in every engine,
  // the viewer sub-window included (its plugins are registered by the runner).
  fvp.registerWith();

  // desktop_multi_window starts sub-windows with ['multi_window', id, argument].
  if (args.length >= 3 && args[0] == 'multi_window' && args[2].startsWith(LinuxMediaViewer.windowTag)) {
    runViewer(MediaItem.fromJson((jsonDecode(args[2].substring(LinuxMediaViewer.windowTag.length)) as Map).cast()));
    return;
  }
  registerGptLive();
  if (Platform.isAndroid) {
    runApp(WoiApp(platform: await createAndroidPlatform()));
    return;
  }
  runApp(const WoiApp());
}
