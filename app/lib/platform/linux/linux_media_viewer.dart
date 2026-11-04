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

  /// Window method that shows another file in an existing (hidden) viewer.
  static const openMethod = 'open';

  /// Window method that forwards a [ViewerCommand] to the viewer engine.
  static const controlMethod = 'control';

  /// Window method returning the viewer's [ViewerState] JSON (null when hidden).
  static const stateMethod = 'state';

  /// Item shown in the in-app overlay (no window).
  MediaItem? _overlayItem;

  @override
  Future<ViewerState?> state() async {
    final w = _window;
    if (w != null) {
      try {
        return ViewerState.fromJson(await w.invokeMethod<Object?>(stateMethod));
      } catch (e) {
        debugPrint('viewer state unavailable: $e');
        return null;
      }
    }
    final item = _overlayItem;
    if (item == null) return null;
    final p = activePlayback;
    return ViewerState(item: item, position: p?.position, duration: p?.duration, playing: p?.playing ?? false);
  }

  /// The viewer window. Closing it only hides it (see ui/viewer/viewer_window.dart),
  /// so later files reuse it.
  WindowController? _window;

  @override
  Future<bool> control(ViewerCommand command, {double seconds = 0}) async {
    final w = _window;
    if (w == null) return false;
    try {
      return await w.invokeMethod<bool>(controlMethod, {'command': command.name, 'seconds': seconds}) ?? false;
    } catch (e) {
      debugPrint('viewer control failed: $e');
      return false;
    }
  }

  @override
  Future<ViewerSurface> show(MediaItem item) async {
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
    _overlayItem = item;
    await overlay(item);
    return ViewerSurface.overlay;
  }
}
