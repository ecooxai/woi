import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../media_viewer.dart';

/// Opens media in a secondary Flutter window (desktop_multi_window), video
/// included (embedded fvp/libmdk player). Nothing is ever handed to an
/// external app; if the window cannot be created the in-app overlay is used.
class LinuxMediaViewer extends MediaViewer {
  LinuxMediaViewer({this.useSecondaryWindow = true});

  final bool useSecondaryWindow;

  /// Prefix of the window argument identifying a viewer window.
  static const windowTag = 'woi-viewer:';

  @override
  Future<ViewerSurface> show(MediaItem item) async {
    if (useSecondaryWindow) {
      try {
        // Shown at once (a hidden window is realized at 1x1 and the first
        // draw then blocks waiting for a full-size frame). The runner paints
        // the Woi background until Flutter's first frame and the viewer sets
        // the title over "woi/window" (linux/runner/my_application.cc).
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
