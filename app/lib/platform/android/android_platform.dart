import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_paths.dart';
import '../linux/linux_files.dart';
import '../platform_services.dart';
import 'android_audio_io.dart';
import 'android_bridge.dart';
import 'android_camera.dart';
import 'android_input_control.dart';
import 'android_media_viewer.dart';
import 'android_screen_capture.dart';
import 'android_shell.dart';
import 'android_url_opener.dart';

/// App-private storage: `<filesDir>/woi` for data, `<filesDir>/codex/auth.json`
/// for the login, `<filesDir>/workspace` as the default workspace.
AppPaths androidAppPaths(AndroidInfo info) => AppPaths(dataDir: p.join(info.filesDir, 'woi'), homeDir: info.filesDir);

String androidAuthPath(AndroidInfo info) => p.join(info.filesDir, 'codex', 'auth.json');

/// Environment for shell commands: the app's, with HOME/TMPDIR in the sandbox.
Map<String, String> androidShellEnvironment(AndroidInfo info) => {
  ...Platform.environment,
  'HOME': info.filesDir,
  'TMPDIR': info.cacheDir,
  'USER': 'woi',
};

Future<PlatformServices> createAndroidPlatform({AndroidBridge? bridge}) async {
  final b = bridge ?? AndroidBridge.instance;
  final info = await b.init();
  final paths = androidAppPaths(info);
  final workspace = p.join(info.filesDir, 'workspace');
  await Directory(workspace).create(recursive: true);
  await Directory(paths.dataDir).create(recursive: true);
  final screen = AndroidScreenCapture(bridge: b);
  return PlatformServices(
    paths: paths,
    audio: AndroidAudioIO(bridge: b),
    screen: screen,
    input: AndroidInputControl(bridge: b),
    shell: AndroidShell(defaultWorkingDirectory: workspace, environment: androidShellEnvironment(info)),
    files: LocalFiles(homeDir: info.filesDir, workspaceDir: workspace),
    viewer: AndroidMediaViewer(),
    urlOpener: AndroidUrlOpener(bridge: b),
    authPath: androidAuthPath(info),
    camera: AndroidCameraService(bridge: b),
    autoScreenshot: () => screen.autoCapture,
    deviceNote:
        'Woi runs on an Android phone (${info.model}, Android SDK ${info.sdk}, screen '
        '${info.screenWidth}x${info.screenHeight}), not a desktop. click_screen taps and type_text types into the app '
        'the user is using (Woi steps aside first); send_keys supports back/esc, home, recents, enter, copy, paste, '
        'cut and select all only. The camera tool opens the back camera. Screenshots come from screen share (when on) or the assistant gesture. '
        'run_bash runs /system/bin/sh (toybox) in the app sandbox; home is ${info.filesDir}.',
    isMobile: true,
  );
}
