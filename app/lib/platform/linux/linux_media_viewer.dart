import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../media_viewer.dart';
import 'exec_util.dart';

/// Opens media in a secondary Flutter window (desktop_multi_window).
/// Video goes to VLC (libmpv is not installed, so media_kit is unavailable);
/// anything that fails falls back to the in-app overlay.
class LinuxMediaViewer extends MediaViewer {
  LinuxMediaViewer({this.useSecondaryWindow = true});

  final bool useSecondaryWindow;

  /// Prefix of the window argument identifying a viewer window.
  static const windowTag = 'woi-viewer:';

  @override
  Future<ViewerSurface> show(MediaItem item) async {
    if (item.kind == MediaKind.video && item.path != null) {
      final player = which('vlc') ?? which('mpv') ?? which('xdg-open');
      if (player != null) {
        await Process.start(player, [item.path!], mode: ProcessStartMode.detached, environment: x11Env());
        return ViewerSurface.external;
      }
    }
    if (useSecondaryWindow) {
      try {
        final c = await WindowController.create(
          WindowConfiguration(arguments: '$windowTag${jsonEncode(item.toJson())}', hiddenAtLaunch: false),
        );
        await c.show();
        return ViewerSurface.window;
      } catch (e) {
        debugPrint('Secondary window unavailable, using overlay: $e');
      }
    }
    final overlay = overlayPresenter;
    if (overlay == null) {
      throw StateError('No viewer surface available');
    }
    await overlay(item);
    return ViewerSurface.overlay;
  }
}
