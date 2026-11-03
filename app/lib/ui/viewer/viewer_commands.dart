import 'dart:async';

import '../../platform/media_viewer.dart';

/// Playback commands from the main window (voice "pause the video"),
/// delivered to the open player in the viewer engine.
final viewerCommands = StreamController<(ViewerCommand, double)>.broadcast();
