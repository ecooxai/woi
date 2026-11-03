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

  /// Window method that shows another file in an existing (hidden) viewer.
  static const openMethod = 'open';

  /// The viewer window. Closing it only hides it (see ui/viewer/viewer_window.dart),
  /// so later files reuse it.
  WindowController? _window;

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
      final reused = _window;
      if (reused != null) {
        try {
          if (await reused.invokeMethod<bool>(openMethod, item.toJson()) == true) {
            await reused.show();
            return ViewerSurface.window;
          }
        } catch (e) {
          debugPrint('Viewer window not reusable, opening a new one: $e');
        }
        _window = null;
      }
      try {
        // Shown at once (a hidden window is realized at 1x1 and the first
        // draw then blocks waiting for a full-size frame). The runner paints
        // the Woi background until Flutter's first frame and the viewer sets
        // the title over "woi/window" (linux/runner/my_application.cc).
        final c = await WindowController.create(
          WindowConfiguration(arguments: '$windowTag${jsonEncode(item.toJson())}', hiddenAtLaunch: false),
        );
        await c.show();
        _window = c;
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
