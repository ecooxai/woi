import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'core/voice/live_register.dart';
import 'platform/linux/linux_media_viewer.dart';
import 'platform/media_viewer.dart';
import 'ui/app.dart';
import 'ui/perf.dart';
import 'ui/viewer/viewer_window.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // In-app video (show_file) through libmdk; registered in every engine,
  // the viewer sub-window included (its plugins are registered by the runner).
  // Video textures are capped at the display size (scaled by libmdk while
  // decoding) so a 4K file does not upload 4K frames for a smaller window.
  final (tw, th) = videoTextureLimit();
  fvp.registerWith(options: {'maxWidth': tw, 'maxHeight': th});

  // desktop_multi_window starts sub-windows with ['multi_window', id, argument].
  if (args.length >= 3 && args[0] == 'multi_window' && args[2].startsWith(LinuxMediaViewer.windowTag)) {
    configureImageCache(maxBytes: kViewerImageCacheBytes, maxCount: kViewerImageCacheCount);
    maybeLogFrameStats('viewer');
    runViewer(MediaItem.fromJson((jsonDecode(args[2].substring(LinuxMediaViewer.windowTag.length)) as Map).cast()));
    return;
  }
  configureImageCache();
  maybeLogFrameStats('main');
  registerGptLive();
  runApp(const WoiApp());
}
