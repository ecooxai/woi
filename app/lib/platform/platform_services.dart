import 'dart:io';

import '../core/auth/pkce_login.dart';
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

bool _always() => true;

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
    this.urlOpener,
    this.authPath,
    this.autoScreenshot = _always,
    this.deviceNote = '',
    this.isMobile = false,
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

  /// Opens the sign-in page (null: [defaultUrlOpener], xdg-open).
  final PlatformUrlOpener? urlOpener;

  /// Where the ChatGPT login lives (null: `$CODEX_HOME` or `~/.codex/auth.json`).
  final String? authPath;

  /// Whether a screenshot is attached to each spoken turn right now (Android:
  /// only while screen share runs).
  final bool Function() autoScreenshot;

  /// Extra facts for the model about the device (empty on the desktop).
  final String deviceNote;

  /// Phone/tablet: no sub-windows, touch targets, single-pane layout.
  final bool isMobile;

  /// Camera ("open camera"); a no-camera stub where none is wired.
  CameraService get camera => _camera ?? (_noCamera ??= NoCameraService());
  final CameraService? _camera;
  static NoCameraService? _noCamera;

  /// Video frame / audio clip extraction for media context.
  final MediaGrabber mediaGrab;

  /// Desktop platforms. Android needs async setup:
  /// `createAndroidPlatform()` (platform/android/android_platform.dart).
  static PlatformServices forCurrentPlatform() {
    if (Platform.isLinux) return createLinuxPlatform();
    throw UnsupportedError('Woi currently supports Linux only (${Platform.operatingSystem} port pending).');
  }
}
