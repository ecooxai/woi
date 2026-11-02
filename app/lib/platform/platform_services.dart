import 'dart:io';

import 'app_paths.dart';
import 'audio_io.dart';
import 'files.dart';
import 'input_control.dart';
import 'linux/linux_platform.dart';
import 'media_viewer.dart';
import 'screen_capture.dart';
import 'shell.dart';

/// Every OS-specific capability the app uses. Ports (Android, macOS, iOS)
/// provide their own implementation of each interface.
class PlatformServices {
  const PlatformServices({
    required this.paths,
    required this.audio,
    required this.screen,
    required this.input,
    required this.shell,
    required this.files,
    required this.viewer,
  });

  final AppPaths paths;
  final AudioIO audio;
  final ScreenCapture screen;
  final InputControl input;
  final Shell shell;
  final Files files;
  final MediaViewer viewer;

  static PlatformServices forCurrentPlatform() {
    if (Platform.isLinux) return createLinuxPlatform();
    throw UnsupportedError(
        'Woi currently supports Linux only (${Platform.operatingSystem} port pending).');
  }
}
