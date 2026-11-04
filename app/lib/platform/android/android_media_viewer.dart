import '../media_viewer.dart';

/// Media opens as an in-app full-screen route (no sub-windows on Android).
/// The UI installs [overlayPresenter] (ui/app.dart) and [closer].
class AndroidMediaViewer extends MediaViewer {
  /// Pops the viewer route if it is open; returns whether one was open.
  bool Function()? closer;

  /// Forwards play/pause/seek to the open video (ui/viewer/viewer_commands.dart).
  bool Function(ViewerCommand command, double seconds)? commander;

  /// The item in the open viewer route (null once it closes).
  MediaItem? _open;

  @override
  Future<ViewerSurface> show(MediaItem item) async {
    final present = overlayPresenter ?? (throw StateError('No viewer surface available'));
    _open = item;
    // The route's future completes when it closes; don't block the tool.
    present(item).whenComplete(() {
      if (identical(_open, item)) _open = null;
    }).ignore();
    return ViewerSurface.overlay;
  }

  @override
  Future<ViewerState?> state() async {
    final item = _open;
    if (item == null) return null;
    final p = activePlayback;
    return ViewerState(item: item, position: p?.position, duration: p?.duration, playing: p?.playing ?? false);
  }

  @override
  Future<bool> control(ViewerCommand command, {double seconds = 0}) async {
    if (command == ViewerCommand.close) {
      final closed = closer?.call() ?? false;
      if (closed) _open = null;
      return closed;
    }
    return commander?.call(command, seconds) ?? false;
  }
}
