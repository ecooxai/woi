import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_paths.dart';
import '../platform_services.dart';
import 'linux_audio_io.dart';
import 'linux_files.dart';
import 'linux_input_control.dart';
import 'linux_media_viewer.dart';
import 'linux_screen_capture.dart';
import 'linux_shell.dart';

AppPaths linuxAppPaths() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final base = (xdg != null && xdg.isNotEmpty) ? xdg : p.join(home, '.local', 'share');
  return AppPaths(dataDir: p.join(base, 'woi'), homeDir: home);
}

PlatformServices createLinuxPlatform({bool secondaryWindows = true}) {
  final paths = linuxAppPaths();
  return PlatformServices(
    paths: paths,
    audio: LinuxAudioIO(),
    screen: LinuxScreenCapture(),
    input: LinuxInputControl(),
    shell: LinuxShell(defaultWorkingDirectory: paths.homeDir),
    files: LocalFiles(homeDir: paths.homeDir),
    viewer: LinuxMediaViewer(useSecondaryWindow: secondaryWindows),
  );
}
