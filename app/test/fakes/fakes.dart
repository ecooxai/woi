import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/app_paths.dart';
import 'package:woi/platform/audio_io.dart';
import 'package:woi/platform/camera.dart';
import 'package:woi/platform/files.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/platform/linux/linux_files.dart';
import 'package:woi/platform/media_viewer.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/platform/screenshot_encode.dart';
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

class FakeAudioIO implements AudioIO, EchoCancellable {
  FakeMic? mic;

  /// When set, [openMic] waits for it (a slow device / AEC module load).
  Completer<void>? openMicGate;

  /// When set, [openMic] throws it.
  Object? openMicError;

  @override
  bool echoCancellation = true;

  /// [echoCancellation] at each [openMic].
  final micOpens = <bool>[];
  bool echoCancellationDisposed = false;

  @override
  String get echoCancellationStatus => echoCancellation ? 'fake canceller' : 'off';

  @override
  Future<void> disposeEchoCancellation() async => echoCancellationDisposed = true;

  final player = FakePcmPlayer();

  /// Players opened after [player] (e.g. the thinking earcon's).
  final extraPlayers = <FakePcmPlayer>[];
  bool _playerOpened = false;
  final playedFiles = <String>[];

  @override
  Future<MicStream> openMic() async {
    micOpens.add(echoCancellation);
    final g = openMicGate;
    if (g != null) await g.future;
    final e = openMicError;
    if (e != null) throw e;
    return mic = FakeMic();
  }

  @override
  Future<PcmPlayer> openPlayer() async {
    if (!_playerOpened) {
      _playerOpened = true;
      return player;
    }
    final p = FakePcmPlayer();
    extraPlayers.add(p);
    return p;
  }

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

/// Voice-like test signal: a [f0] Hz harmonic series up to ~3.5 kHz with
/// a 1/k roll-off (spans several of [EchoGuard]'s bands, unlike [pcm]'s
/// Nyquist square wave). [phase0] continues a previous chunk.
Uint8List voice(int ms, {int amplitude = 6000, double f0 = 220, int phase0 = 0}) {
  final samples = kVoiceSampleRate * ms ~/ 1000;
  final bd = ByteData(samples * 2);
  final harmonics = (3500 / f0).floor();
  var norm = 0.0;
  for (var k = 1; k <= harmonics; k++) {
    norm += 1 / k;
  }
  for (var i = 0; i < samples; i++) {
    final t = (phase0 + i) / kVoiceSampleRate;
    var v = 0.0;
    for (var k = 1; k <= harmonics; k++) {
      v += sin(2 * pi * f0 * k * t) / k;
    }
    bd.setInt16(i * 2, (amplitude * v / norm).round().clamp(-32768, 32767), Endian.little);
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
  int width, height, originalWidth, originalHeight;
  final captureTimes = <DateTime>[];

  /// When set, the image size follows the requested scale (like the real
  /// captures) instead of the fixed [width]x[height].
  bool scaling = false;

  /// Real JPEG bytes (at the requested quality) instead of a stub PNG.
  bool jpeg = false;

  /// (scale, jpegQuality, maxWidth) of each capture.
  final requests = <(double, int?, int?)>[];

  @override
  Future<Screenshot> capture({
    double scale = kDefaultScreenshotScale,
    int? jpegQuality = kDefaultScreenshotJpegQuality,
    int? maxWidth,
  }) async {
    captureTimes.add(DateTime.now());
    requests.add((scale, jpegQuality, maxWidth));
    if (scaling) {
      final (w, h) = screenshotSize(originalWidth, originalHeight, scale, maxWidth: maxWidth);
      width = w;
      height = h;
    }
    if (jpeg && jpegQuality != null) {
      return Screenshot(
        png: encodeRgbJpegSync(Uint8List(width * height * 3), width, height, jpegQuality),
        width: width,
        height: height,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
      );
    }
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

  /// Target window class reported by [sendKeys] (e.g. "xterm XTerm").
  String windowClass = 'gedit Gedit';
  int remembered = 0;
  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    final chords = keys != null ? parseKeySequence(keys) : chordsForAction(action!, windowClass: windowClass);
    log.add('keys ${chords.join(' ')}${target.isDefault ? '' : ' @${target.window}'}');
    return SendKeysResult(chords: chords, windowTitle: target.window ?? 'Untitled - gedit', windowClass: windowClass);
  }

  @override
  Future<void> rememberTargetWindow() async => remembered++;
}

// ------------------------------------------------------------------ shell

class FakeShell implements Shell {
  final commands = <String>[];
  final cwds = <String?>[];

  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) async {
    commands.add(command);
    cwds.add(workingDirectory);
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

  /// What [busy] reports (work in flight).
  bool busyFlag = false;

  /// What [uplinkLagMs] reports.
  int? uplinkLag;
  @override
  int? get uplinkLagMs => uplinkLag;
  @override
  bool get busy => busyFlag;

  /// When set, [connect] throws it (reconnect tests).
  Object? connectError;

  @override
  bool get hasServerVad => serverVad;
  @override
  Stream<BackendEvent> get events => _events.stream;
  @override
  Future<void> connect(SessionConfig config) async {
    connectStarted = true;
    final g = connectGate;
    if (g != null) await g.future;
    final e = connectError;
    if (e != null) throw e;
    this.config = config;
  }

  /// When set, [connect] waits for it (a slow handshake).
  Completer<void>? connectGate;

  /// [connect] was called (before its gate opened).
  bool connectStarted = false;

  @override
  void sendAudio(Uint8List pcm16) {
    sendLog.add('audio');
    audioBytes += pcm16.length;
    sentAudio.add(pcm16);
    audioSent.add(Int16List.sublistView(Uint8List.fromList(pcm16)));
  }

  final List<Uint8List> sentAudio = [];

  /// Order of what went to the model: 'audio' per chunk, 'image' per image.
  final sendLog = <String>[];

  /// Every chunk sent, as samples.
  final audioSent = <Int16List>[];
  @override
  void sendText(String text) => texts.add(text);
  @override
  String? sendImage(Uint8List png, {String? note}) {
    sendLog.add('image');
    images.add((png, note));
    return 'img_${images.length}';
  }

  /// replaceImage calls: (itemId, png?, text?).
  final replaced = <(String, Uint8List?, String?)>[];
  bool supportsReplace = true;

  @override
  Future<String?> replaceImage(String itemId, {Uint8List? png, String? text}) async {
    if (!supportsReplace) return null;
    replaced.add((itemId, png, text));
    return '${itemId}_v${replaced.length}';
  }

  String screenMemory = '';

  @override
  void updateScreenMemory(String text) => screenMemory = text;
  @override
  void sendToolResult(String callId, String jsonOutput) => toolResults.add((callId, jsonOutput));
  @override
  void cancelResponse() => cancels++;
  int stopDrops = 0;
  final holds = <bool>[];
  @override
  void stopAndDrop() {
    stopDrops++;
    cancels++;
  }

  /// dropEchoTurn calls: (user item id, tool call ids).
  final echoDrops = <(String?, List<String>)>[];
  @override
  void dropEchoTurn({String? itemId, List<String> callIds = const []}) {
    echoDrops.add((itemId, callIds));
    stopAndDrop();
  }

  int accepts = 0;
  @override
  void acceptTurn() => accepts++;

  /// beginPreConnectFlush calls: (bufferedMs, firstVoicedMs).
  final flushes = <(int, int?)>[];
  @override
  void beginPreConnectFlush(int bufferedMs, {int? firstVoicedMs}) => flushes.add((bufferedMs, firstVoicedMs));

  /// [audioBytes] when endPreConnectFirstTurn was called.
  final firstTurnEnds = <int>[];
  @override
  void endPreConnectFirstTurn() => firstTurnEnds.add(audioBytes);

  /// setIdle calls.
  final idles = <bool>[];
  @override
  void setIdle(bool idle) => idles.add(idle);

  @override
  void setReplyHold(bool hold) => holds.add(hold);
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

// ----------------------------------------------------------------- camera

/// Minimal JPEG (SOI, SOF0 with [w]x[h], SOS, [payload] entropy bytes, EOI);
/// enough for [jpegSize] and the stream splitter, not for decoding.
Uint8List fakeJpeg(int w, int h, {List<int> payload = const [1, 2, 3, 0xFF, 0x00, 4]}) => Uint8List.fromList([
  0xFF, 0xD8, //
  0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0 "JFIF"
  0xFF,
  0xC0,
  0x00,
  0x0B,
  0x08,
  h >> 8,
  h & 0xFF,
  w >> 8,
  w & 0xFF,
  0x01,
  0x01,
  0x11,
  0x00,
  0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  ...payload,
  0xFF, 0xD9,
]);

/// Camera driven by the test: [open] starts "streaming" [frame].
class FakeCamera extends CameraService {
  final _active = ValueNotifier(false);
  final _frames = ValueNotifier<CameraFrame?>(null);
  int opens = 0, closes = 0;
  bool fail = false;

  @override
  ValueListenable<bool> get active => _active;
  @override
  ValueListenable<CameraFrame?> get frames => _frames;
  @override
  String? get lastError => fail ? 'no camera' : null;

  void push({int w = 1280, int h = 720, DateTime? at}) =>
      _frames.value = CameraFrame(jpeg: fakeJpeg(w, h), width: w, height: h, capturedAt: at ?? DateTime.now());

  @override
  Future<void> open() async {
    opens++;
    if (fail) throw CameraException('No camera at /dev/video0');
    _active.value = true;
    push();
  }

  @override
  Future<void> close() async {
    closes++;
    _active.value = false;
    _frames.value = null;
  }
}

extension FakeCameraJpeg on FakeCamera {
  void pushJpeg(Uint8List jpeg) {
    final s = jpegSize(jpeg)!;
    (frames as ValueNotifier<CameraFrame?>).value = CameraFrame(
      jpeg: jpeg,
      width: s.$1,
      height: s.$2,
      capturedAt: DateTime.now(),
    );
  }
}
