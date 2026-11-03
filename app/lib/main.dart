import 'dart:convert';

import 'package:flutter/material.dart';

import 'core/voice/live_register.dart';
import 'platform/linux/linux_media_viewer.dart';
import 'platform/media_viewer.dart';
import 'ui/app.dart';
import 'ui/viewer/viewer_window.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();

  // desktop_multi_window starts sub-windows with ['multi_window', id, argument].
  if (args.length >= 3 && args[0] == 'multi_window' && args[2].startsWith(LinuxMediaViewer.windowTag)) {
    runViewer(MediaItem.fromJson((jsonDecode(args[2].substring(LinuxMediaViewer.windowTag.length)) as Map).cast()));
    return;
  }
  registerGptLive();
  runApp(const WoiApp());
}
