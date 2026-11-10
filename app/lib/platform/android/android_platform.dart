import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_paths.dart';
import '../control_feedback.dart';
import '../file_picker.dart';
import '../linux/linux_files.dart';
import '../platform_services.dart';
import 'android_audio_io.dart';
import 'android_bridge.dart';
import 'android_camera.dart';
import 'android_clipboard_access.dart';
import 'android_elements.dart';
import 'android_input_control.dart';
import 'android_media_viewer.dart';
import 'android_screen_capture.dart';
import 'android_shell.dart';
import 'android_python_runner.dart';
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
  final input = AndroidInputControl(
    bridge: b,
    control: ControlGuard(
      ControlFeedback(
        (method, arguments) => b.call<Object?>('control${method[0].toUpperCase()}${method.substring(1)}', arguments),
      ),
    ),
  );
  return PlatformServices(
    paths: paths,
    audio: AndroidAudioIO(bridge: b),
    screen: screen,
    clipboard: AndroidClipboardAccess(bridge: b),
    filePicker: NativeFilePicker(androidBridge: b),
    input: input,
    showKeyboard: input.showKeyboard,
    pythonRunner: const AndroidPythonRunner(),
    shell: AndroidShell(defaultWorkingDirectory: workspace, environment: androidShellEnvironment(info)),
    files: LocalFiles(homeDir: info.filesDir, workspaceDir: workspace),
    viewer: AndroidMediaViewer(),
    urlOpener: AndroidUrlOpener(bridge: b),
    authPath: androidAuthPath(info),
    camera: AndroidCameraService(bridge: b),
    autoScreenshot: () => screen.autoCapture,
    elements: AndroidElementSource(bridge: b),
    deviceNote:
        'Woi runs on an Android phone (${info.model}, Android SDK ${info.sdk}, screen '
        '${info.screenWidth}x${info.screenHeight}; click_screen x/y are still pixels of the latest screenshot image), not a desktop. '
        'click_screen taps and type_text types into the app '
        'the user is using (Woi steps aside first; when opened by the assistant gesture Woi is a bottom panel floating over that '
        'app, which stays open); send_keys supports back/esc, home (keys "home" = launcher home screen, not back), recents, enter, '
        'copy, paste, cut, select all and exact Ctrl/Alt/Shift/Meta chords (Android 13+ with an external input connection). '
        'type_text can insert in a focused editable field even when the keyboard is hidden; do not require the user to open it first. '
        'clipboard reads/writes text and pastes; Android may require a brief visible Woi focus for a clipboard read. '
        'scroll_screen scrolls the current app viewport up/down/left/right with optional screenshot pane coordinates. '
        'show_keyboard displays Woi’s touch keyboard without focusing a field; visibility and receiving input capabilities are separate. '
        'Its page/phone keys work without an editor; exact chords still require an input connection. hide_keyboard dismisses it. '
        'The camera tool opens the back camera. Screenshots come from screen share (when on) or the assistant gesture. '
        'run_bash runs /system/bin/sh (toybox) in the app sandbox; home is ${info.filesDir}. '
        'The python tool runs bundled Python 3 with its standard library in a separate app-private process.',
    isMobile: true,
  );
}
