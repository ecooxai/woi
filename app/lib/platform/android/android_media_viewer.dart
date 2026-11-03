import '../media_viewer.dart';

/// Media opens as an in-app full-screen route (no sub-windows on Android).
/// The UI installs [overlayPresenter] (ui/app.dart) and [closer].
class AndroidMediaViewer extends MediaViewer {
  /// Pops the viewer route if it is open; returns whether one was open.
  bool Function()? closer;

  /// Forwards play/pause/seek to the open video (ui/viewer/viewer_commands.dart).
  bool Function(ViewerCommand command, double seconds)? commander;

  @override
  Future<ViewerSurface> show(MediaItem item) async {
    final present = overlayPresenter ?? (throw StateError('No viewer surface available'));
    // The route's future completes when it closes; don't block the tool.
    present(item).ignore();
    return ViewerSurface.overlay;
  }

  @override
  Future<bool> control(ViewerCommand command, {double seconds = 0}) async {
    if (command == ViewerCommand.close) return closer?.call() ?? false;
    return commander?.call(command, seconds) ?? false;
  }
}
