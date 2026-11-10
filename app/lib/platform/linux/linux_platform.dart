import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_paths.dart';
import '../control_feedback.dart';
import '../files.dart';
import '../platform_services.dart';
import 'atspi_elements.dart';
import 'linux_audio_io.dart';
import 'linux_camera.dart';
import 'linux_clipboard_access.dart';
import 'linux_files.dart';
import 'linux_input_control.dart';
import 'linux_media_grab.dart';
import 'linux_media_viewer.dart';
import 'linux_screen_capture.dart';
import 'linux_shell.dart';

AppPaths linuxAppPaths() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final base = (xdg != null && xdg.isNotEmpty)
      ? xdg
      : p.join(home, '.local', 'share');
  return AppPaths(dataDir: p.join(base, 'woi'), homeDir: home);
}

PlatformServices createLinuxPlatform({bool secondaryWindows = true}) {
  final paths = linuxAppPaths();
  return PlatformServices(
    paths: paths,
    audio: LinuxAudioIO(),
    clipboard: const LinuxClipboardAccess(),
    screen: LinuxScreenCapture(),
    input: LinuxInputControl(control: ControlGuard(ControlFeedback.linux())),
    shell: LinuxShell(defaultWorkingDirectory: paths.homeDir),
    files: LocalFiles(
      homeDir: paths.homeDir,
      workspaceDir: defaultWorkspaceDir(paths.homeDir, Directory.current.path),
    ),
    viewer: LinuxMediaViewer(useSecondaryWindow: secondaryWindows),
    camera: LinuxCameraService(
      device: Platform.environment['WOI_CAMERA'] ?? '/dev/video0',
    ),
    mediaGrab: const FfmpegMediaGrabber(),
    elements: AtspiElementSource(),
  );
}
