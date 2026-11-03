import 'dart:io';

import 'app_paths.dart';
import 'audio_io.dart';
import 'camera.dart';
import 'files.dart';
import 'input_control.dart';
import 'linux/linux_platform.dart';
import 'media_grab.dart';
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
    CameraService? camera,
    this.mediaGrab = const NoMediaGrabber(),
  }) : _camera = camera; // ignore: prefer_initializing_formals

  final AppPaths paths;
  final AudioIO audio;
  final ScreenCapture screen;
  final InputControl input;
  final Shell shell;
  final Files files;
  final MediaViewer viewer;

  /// Camera ("open camera"); a no-camera stub where none is wired.
  CameraService get camera => _camera ?? (_noCamera ??= NoCameraService());
  final CameraService? _camera;
  static NoCameraService? _noCamera;

  /// Video frame / audio clip extraction for media context.
  final MediaGrabber mediaGrab;

  static PlatformServices forCurrentPlatform() {
    if (Platform.isLinux) return createLinuxPlatform();
    throw UnsupportedError('Woi currently supports Linux only (${Platform.operatingSystem} port pending).');
  }
}
