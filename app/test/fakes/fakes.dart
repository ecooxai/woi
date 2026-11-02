import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/app_paths.dart';
import 'package:woi/platform/audio_io.dart';
import 'package:woi/platform/files.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/platform/linux/linux_files.dart';
import 'package:woi/platform/media_viewer.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/platform/shell.dart';
import 'package:woi/tools/confirmation.dart';

// ------------------------------------------------------------------ audio

class FakeMic implements MicStream {
  final _chunks = StreamController<Uint8List>.broadcast(sync: true);
  final _level = ValueNotifier<double>(0);
  bool closed = false;

  void push(Uint8List chunk) => _chunks.add(chunk);

  @override
  Stream<Uint8List> get chunks => _chunks.stream;
  @override
  ValueListenable<double> get level => _level;
  @override
  Future<void> close() async {
    closed = true;
    await _chunks.close();
  }
}

class FakePcmPlayer implements PcmPlayer {
  final written = BytesBuilder();
  int stops = 0;
  bool playing = false;
  bool closed = false;
  final _level = ValueNotifier<double>(0);

  @override
  void write(Uint8List pcm16) {
    written.add(pcm16);
    playing = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  bool get isPlaying => playing;
  @override
  ValueListenable<double> get level => _level;
  @override
  Future<void> close() async => closed = true;
}

class FakeAudioIO implements AudioIO {
  FakeMic? mic;
  final player = FakePcmPlayer();
  final playedFiles = <String>[];

  @override
  Future<MicStream> openMic() async => mic = FakeMic();
  @override
  Future<PcmPlayer> openPlayer() async => player;
  @override
  Future<ClipPlayback> playFile(String path) async {
    playedFiles.add(path);
    return _DoneClip();
  }

  @override
  String get description => 'fake';
}

class _DoneClip implements ClipPlayback {
  @override
  Future<void> get done => Future.value();
  @override
  Future<void> stop() async {}
}

/// [ms] of PCM16 24 kHz at a constant amplitude (0 = silence).
Uint8List pcm(int ms, {int amplitude = 0}) {
  final samples = kVoiceSampleRate * ms ~/ 1000;
  final bd = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    bd.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
  }
  return bd.buffer.asUint8List();
}

// ----------------------------------------------------------------- screen

/// Minimal PNG header (signature + IHDR) — enough for [pngSize].
Uint8List tinyPng(int w, int h) {
  final bd = ByteData(33);
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    bd.setUint8(i, sig[i]);
  }
  bd.setUint32(8, 13);
  for (var i = 0; i < 4; i++) {
    bd.setUint8(12 + i, 'IHDR'.codeUnitAt(i));
  }
  bd.setUint32(16, w);
  bd.setUint32(20, h);
  bd.setUint8(24, 8);
  bd.setUint8(25, 6);
  return bd.buffer.asUint8List();
}

class FakeScreen implements ScreenCapture {
  FakeScreen({this.width = 1280, this.height = 720, this.originalWidth = 2560, this.originalHeight = 1440});
  final int width, height, originalWidth, originalHeight;
  final captureTimes = <DateTime>[];

  @override
  Future<Screenshot> capture({int maxWidth = 1280}) async {
    captureTimes.add(DateTime.now());
    return Screenshot(
      png: tinyPng(width, height),
      width: width,
      height: height,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
    );
  }
}

// ------------------------------------------------------------------ input

class FakeInput implements InputControl {
  final log = <String>[];
  Point<int> location = const Point(10, 20);

  @override
  Future<void> moveMouse(int x, int y) async => log.add('move $x $y');
  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left}) async =>
      log.add('click $x $y ${button.name}');
  @override
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left}) async =>
      log.add('dblclick $x $y ${button.name}');
  @override
  Future<void> typeText(String text) async => log.add('type $text');
  @override
  Future<void> keyCombo(String combo) async => log.add('key $combo');
  @override
  Future<Point<int>> mouseLocation() async => location;
}

// ------------------------------------------------------------------ shell

class FakeShell implements Shell {
  final commands = <String>[];

  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) async {
    commands.add(command);
    final echo = RegExp(r'^echo (.*)$').firstMatch(command.trim());
    return ShellResult(
      exitCode: echo != null ? 0 : 127,
      stdout: echo != null ? '${echo.group(1)}\n' : '',
      stderr: echo != null ? '' : 'fake: command not found',
      elapsed: const Duration(milliseconds: 3),
    );
  }
}

// ----------------------------------------------------------------- viewer

class FakeViewer extends MediaViewer {
  final shown = <MediaItem>[];
  @override
  Future<ViewerSurface> show(MediaItem item) async {
    shown.add(item);
    return ViewerSurface.overlay;
  }
}

// ---------------------------------------------------------- confirmations

class FakeConfirmations implements ConfirmationService {
  FakeConfirmations({this.approveWrites = true, this.approveCommands = true});
  bool approveWrites;
  bool approveCommands;
  final writeRequests = <FileWriteRequest>[];
  final commandRequests = <String>[];

  @override
  Future<bool> confirmFileWrite(FileWriteRequest request) async {
    writeRequests.add(request);
    return approveWrites;
  }

  @override
  Future<bool> confirmCommand(String command) async {
    commandRequests.add(command);
    return approveCommands;
  }
}

// --------------------------------------------------------------- platform

class FakePlatform {
  FakePlatform(this.root)
    : audio = FakeAudioIO(),
      screen = FakeScreen(),
      input = FakeInput(),
      shell = FakeShell(),
      viewer = FakeViewer();

  /// Temp directory used as both $HOME and the data dir parent.
  final Directory root;
  final FakeAudioIO audio;
  final FakeScreen screen;
  final FakeInput input;
  final FakeShell shell;
  final FakeViewer viewer;

  late final services = PlatformServices(
    paths: AppPaths(dataDir: '${root.path}/data', homeDir: root.path),
    audio: audio,
    screen: screen,
    input: input,
    shell: shell,
    files: LocalFiles(homeDir: root.path),
    viewer: viewer,
  );

  static Future<FakePlatform> create() async => FakePlatform(await Directory.systemTemp.createTemp('woi_test_'));

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

// ---------------------------------------------------------------- backend

/// Backend whose events are driven by the test.
class ScriptedBackend extends VoiceBackend {
  ScriptedBackend({this.serverVad = true});
  final bool serverVad;
  final _events = StreamController<BackendEvent>.broadcast(sync: true);

  SessionConfig? config;
  int audioBytes = 0;
  final texts = <String>[];
  final images = <(Uint8List, String?)>[];
  final toolResults = <(String, String)>[];
  int cancels = 0;
  bool closed = false;

  void emit(BackendEvent e) => _events.add(e);

  @override
  bool get hasServerVad => serverVad;
  @override
  Stream<BackendEvent> get events => _events.stream;
  @override
  Future<void> connect(SessionConfig config) async => this.config = config;
  @override
  void sendAudio(Uint8List pcm16) => audioBytes += pcm16.length;
  @override
  void sendText(String text) => texts.add(text);
  @override
  void sendImage(Uint8List png, {String? note}) => images.add((png, note));
  @override
  void sendToolResult(String callId, String jsonOutput) => toolResults.add((callId, jsonOutput));
  @override
  void cancelResponse() => cancels++;
  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}

/// Polls [cond] until true or [timeout].
Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) throw TimeoutException('waitFor timed out${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
