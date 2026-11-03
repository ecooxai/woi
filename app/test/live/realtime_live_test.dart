// REAL end-to-end tests against OpenAI (ChatGPT login from ~/.codex/auth.json).
//
//   WOI_LIVE=1 flutter test --tags live test/live
//
// Each research/fixtures/*.wav is streamed at real-time pace through the real
// TurnPipeline + RealtimeWsBackend + ToolRegistry; platform effects (clicks,
// typing, shell, viewer, confirmations) are fakes that record what happened.
@Tags(['live'])
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart' show kAssistantInstructions;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/context/responses_compressor.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/context_sync.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/app_paths.dart';
import 'package:woi/platform/linux/linux_files.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import '../fakes/fakes.dart';

final _live = Platform.environment['WOI_LIVE'] == '1';
final _fixtures = Directory('../research/fixtures');
final _model = Platform.environment['WOI_REALTIME_MODEL'] ?? 'gpt-realtime-2';
const _screenW = 1920, _screenH = 1080;

/// Screen fake returning the real fixture PNG (256x256) for a 1920x1080 screen.
class _FixtureScreen implements ScreenCapture {
  final png = File('${_fixtures.path}/test_screen.png').readAsBytesSync();
  int captures = 0;
  @override
  Future<Screenshot> capture({int maxWidth = 1280}) async {
    captures++;
    return Screenshot(png: png, width: 256, height: 256, originalWidth: _screenW, originalHeight: _screenH);
  }
}

class _FakeDelegate implements DelegateBackend {
  final tasks = <String>[];
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    tasks.add(task);
    return DelegateResult(output: 'Wrote dupes.py: it hashes files and prints duplicate groups.', model: model);
  }
}

class _ToolCallRec {
  _ToolCallRec(this.name, this.args, this.at);
  final String name;
  final Map<String, Object?> args;
  final Duration at;
  @override
  String toString() => '$name ${jsonEncode(args)}';
}

class _RunResult {
  String fixture = '';
  bool pass = false;
  final reasons = <String>[];
  String userTranscript = '';
  String assistantTranscript = '';
  final tools = <_ToolCallRec>[];
  int audioBytes = 0;
  Duration? speechStoppedLatency, firstAudioLatency, firstToolLatency, toolToAudio;
  final errors = <String>[];

  String ms(Duration? d) => d == null ? '-' : '${d.inMilliseconds}';
  @override
  String toString() =>
      '${pass ? 'PASS' : 'FAIL'} $fixture | user="$userTranscript" | tools=$tools | '
      'audio=${(audioBytes / kVoiceBytesPerSecond).toStringAsFixed(1)}s | '
      'eos→stopped=${ms(speechStoppedLatency)}ms eos→audio=${ms(firstAudioLatency)}ms '
      'eos→tool=${ms(firstToolLatency)}ms tool→audio=${ms(toolToAudio)}ms | '
      'assistant="${assistantTranscript.length > 90 ? '${assistantTranscript.substring(0, 90)}…' : assistantTranscript}"'
      '${reasons.isEmpty ? '' : ' | ${reasons.join('; ')}'}${errors.isEmpty ? '' : ' | errors=$errors'}';
}

/// A live session: TurnPipeline + RealtimeWsBackend + real ToolRegistry over fakes.
class _LiveRig {
  _LiveRig._(this.root);
  final Directory root;
  final audio = FakeAudioIO();
  final screen = _FixtureScreen();
  final input = FakeInput();
  final shell = FakeShell();
  final viewer = FakeViewer();
  final confirm = FakeConfirmations();
  final delegate = _FakeDelegate();
  late final PlatformServices services;
  late final ToolRegistry tools;
  late final TurnPipeline pipeline;
  late final ContextManager context;
  RealtimeWsBackend? backend;
  final events = <(Duration, BackendEvent)>[];
  final clock = Stopwatch()..start();
  StreamSubscription<BackendEvent>? _sub;

  static Future<_LiveRig> create(
    CodexAuthManager auth, {
    Compressor? compressor,
    int threshold = 1 << 30,
    ImageCompactor? Function(HistoryStore store)? images,
  }) async {
    final r = _LiveRig._(await Directory.systemTemp.createTemp('woi_live_'));
    File('${r.root.path}/README.md').writeAsStringSync('# Demo project\n\nThis README is a test fixture.\n');
    File('${r.root.path}/notes.txt').writeAsStringSync('eggs\n');
    File('${r.root.path}/demo.mp4').writeAsBytesSync(Uint8List(64));
    r.services = PlatformServices(
      paths: AppPaths(dataDir: '${r.root.path}/.woi', homeDir: r.root.path),
      audio: r.audio,
      screen: r.screen,
      input: r.input,
      shell: r.shell,
      files: LocalFiles(homeDir: r.root.path),
      viewer: r.viewer,
    );
    final store = HistoryStore(r.services.paths);
    await store.init();
    r.context = ContextManager(
      compressor: compressor ?? StubCompressor(latency: Duration.zero),
      threshold: threshold,
      keepRecentTurns: 2,
      minInterval: Duration.zero,
    );
    final env = ToolEnvironment(
      platform: r.services,
      confirmations: r.confirm,
      delegate: r.delegate,
      settings: () => const AppSettings(confirmBeforeBash: true),
      onScreenshot: (s, note) => r.pipeline.attachScreenshot(s, note: note),
    );
    r.tools = ToolRegistry()..registerAll(builtinTools(env));
    r.pipeline = TurnPipeline(
      backendFactory: () {
        final b = r.backend = RealtimeWsBackend(credentialsProvider: auth.credentials, log: (_) {})..recordSent = true;
        r._sub = b.events.listen((e) => r.events.add((r.clock.elapsed, e)));
        return b;
      },
      audio: r.audio,
      screen: r.screen,
      tools: r.tools,
      context: r.context,
      store: store,
      conversation: Conversation(),
      sessionConfig: (c) async =>
          SessionConfig(model: _model, voice: 'marin', instructions: kAssistantInstructions, tools: r.tools.specs),
      options: () => const PipelineOptions(screenshotDelay: Duration(milliseconds: 600)),
      onScreenshotCaptured: (s) => env.lastScreenshot = s,
      imageCompactor: images?.call(store),
    );
    await r.pipeline.start();
    await waitFor(() => r.backend?.isReady ?? false, timeout: const Duration(seconds: 20));
    return r;
  }

  FakeMic get mic => audio.mic!;

  /// Streams [pcm] in 20 ms chunks at real-time pace. Returns the clock time
  /// right after the last voiced frame (RMS > 400): the end of speech.
  Future<Duration> stream(Uint8List pcm) async {
    const chunk = 960; // 20 ms
    final start = clock.elapsed;
    Duration? eos;
    for (var off = 0, i = 0; off < pcm.length; off += chunk, i++) {
      final end = min(off + chunk, pcm.length);
      final c = Uint8List.sublistView(pcm, off, end);
      final due = start + Duration(milliseconds: 20 * i);
      final wait = due - clock.elapsed;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      mic.push(Uint8List.fromList(c));
      if (_rms(c) > 400) eos = clock.elapsed + const Duration(milliseconds: 20);
    }
    return eos ?? clock.elapsed;
  }

  /// Keeps the mic open with silence (like a real microphone) until [done] or timeout.
  Future<bool> silenceUntil(bool Function() done, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = clock.elapsed + timeout;
    final silence = Uint8List(960);
    var next = clock.elapsed;
    while (!done()) {
      if (clock.elapsed > end) return false;
      next += const Duration(milliseconds: 20);
      final wait = next - clock.elapsed;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      mic.push(silence);
    }
    return true;
  }

  Iterable<(Duration, T)> after<T>(Duration t) sync* {
    for (final e in events) {
      if (e.$1 >= t && e.$2 is T) yield (e.$1, e.$2 as T);
    }
  }

  Future<void> dispose() async {
    await pipeline.shutdown();
    await _sub?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (await root.exists()) await root.delete(recursive: true);
  }
}

double _rms(Uint8List pcm) {
  final bd = ByteData.sublistView(pcm);
  var sum = 0.0;
  final n = pcm.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final s = bd.getInt16(i * 2, Endian.little);
    sum += s * s;
  }
  return n == 0 ? 0 : sqrt(sum / n);
}

Uint8List _wavPcm(String file) {
  final b = File('${_fixtures.path}/$file').readAsBytesSync();
  // Find the "data" chunk.
  var off = 12;
  final bd = ByteData.sublistView(b);
  while (off + 8 <= b.length) {
    final id = ascii.decode(b.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    if (id == 'data') return Uint8List.sublistView(b, off + 8, min(b.length, off + 8 + size));
    off += 8 + size + (size & 1);
  }
  throw StateError('no data chunk in $file');
}

String _s(Object? v) => (v ?? '').toString().toLowerCase();

/// Checks the expected tool from manifest.json against what happened.
void _check(Map<String, Object?> fx, _RunResult r, _LiveRig rig) {
  final names = r.tools.map((t) => t.name).toList();
  _ToolCallRec? find(Set<String> n) => r.tools.where((t) => n.contains(t.name)).firstOrNull;
  void need(bool ok, String why) {
    if (!ok) r.reasons.add(why);
  }

  final file = fx['file'] as String;
  final home = rig.root.path;
  switch (fx['expected_tool']) {
    case null:
      need(names.every((n) => n == 'take_screenshot'), 'expected no action tool, got $names');
    case 'click_screen':
      final c = find({'click_screen'});
      need(c != null, 'click_screen not called ($names)');
      final click = rig.input.log.where((l) => l.startsWith('click')).firstOrNull;
      need(click != null, 'no click performed');
      if (click != null) {
        final p = click.split(' ');
        final x = int.parse(p[1]), y = int.parse(p[2]);
        // Screenshot center (128,128) → screen (960,540); allow ±15% of the screen.
        need((x - 960).abs() < _screenW * 0.15 && (y - 540).abs() < _screenH * 0.15, 'click ($x,$y) not near center');
      }
    case 'type_text':
      final c = find({'type_text'});
      need(c != null, 'type_text not called ($names)');
      need(_s(c?.args['text']).replaceAll(RegExp(r'[^a-z ]'), '').contains('hello world'), 'text not "hello world"');
      need(rig.input.log.any((l) => l.startsWith('type ')), 'nothing typed');
    case 'run_command':
      final c = find({'run_bash'});
      need(c != null, 'run_bash not called ($names)');
      need(RegExp(r'\bls\b').hasMatch(_s(c?.args['command'])), 'command lacks ls: ${c?.args}');
      need(rig.shell.commands.isNotEmpty, 'shell not run');
    case 'read_file':
      final c = find({'read_file', 'show_file'});
      need(c != null, 'read_file/show_file not called ($names)');
      need(_s(c?.args['path']).contains('readme'), 'path lacks README: ${c?.args}');
    case 'edit_file':
      final c = find({'edit_file', 'write_file'});
      need(c != null, 'edit_file/write_file not called ($names)');
      need(_s(c?.args['path']).contains('notes.txt'), 'path lacks notes.txt');
      final content = File('$home/notes.txt').readAsStringSync().toLowerCase();
      need(content.contains('buy milk'), 'notes.txt lacks "buy milk": ${jsonEncode(content)}');
      need(content.contains('eggs'), 'existing line lost');
      need(rig.confirm.writeRequests.isNotEmpty, 'write not confirmed via the app');
    case 'take_screenshot':
      // The pipeline already attaches a screenshot while the user speaks, so
      // describing the screen without calling the tool is also correct.
      final described = RegExp(r'red|blue|circle|rectangle|bar|shape').hasMatch(_s(r.assistantTranscript));
      need(names.contains('take_screenshot') || described, 'neither take_screenshot nor a screen description');
      need(described, 'assistant did not describe the screen');
    case 'delegate_task':
      final c = find({'delegate_task'});
      need(c != null, 'delegate_task not called ($names)');
      need(_s(c?.args['task']).contains('duplicate'), 'task lacks "duplicate": ${c?.args}');
      need(rig.delegate.tasks.isNotEmpty, 'delegate not run');
    case 'play_media':
      final c = find({'show_file'});
      need(c != null, 'show_file not called ($names)');
      need(_s(c?.args['path']).contains('demo.mp4'), 'path lacks demo.mp4');
      need(rig.viewer.shown.isNotEmpty, 'viewer not shown');
    default:
      r.reasons.add('unhandled expected tool for $file');
  }
  need(r.userTranscript.isNotEmpty, 'no user transcript');
  need(r.audioBytes > 0, 'no assistant audio');
  need(r.errors.isEmpty, 'backend errors');
  r.pass = r.reasons.isEmpty;
}

Future<_RunResult> _runFixture(CodexAuthManager auth, Map<String, Object?> fx) async {
  final rig = await _LiveRig.create(auth);
  final r = _RunResult()..fixture = fx['file'] as String;
  try {
    final t0 = rig.clock.elapsed;
    final eos = await rig.stream(_wavPcm(r.fixture));
    // Done = the turn was answered by a response without tool calls.
    bool finished() {
      var stopped = false, toolSinceDone = false, done = false;
      for (final (_, e) in rig.after<BackendEvent>(t0)) {
        switch (e) {
          case SpeechStopped():
            stopped = true;
          case ToolCall():
            toolSinceDone = true;
            done = false;
          case ResponseDone(:final cancelled) when stopped && !cancelled:
            done = !toolSinceDone;
            toolSinceDone = false;
          default:
        }
      }
      return done && !(rig.backend?.responseActive ?? true);
    }

    final ok = await rig.silenceUntil(finished, timeout: const Duration(seconds: 40));
    if (!ok) r.reasons.add('timed out waiting for the final response');
    // Let transcription.completed (asynchronous) land.
    await rig.silenceUntil(
      () => rig.after<UserTranscriptDone>(t0).isNotEmpty,
      timeout: const Duration(seconds: 5),
    );
    for (final (t, e) in rig.after<BackendEvent>(t0)) {
      switch (e) {
        // A mid-sentence pause can stop the turn early (§2 gotcha); measure the final one.
        case SpeechStopped() when r.speechStoppedLatency == null && t >= eos:
          r.speechStoppedLatency = t - eos;
        case AssistantAudioDelta(:final pcm16):
          if (r.firstAudioLatency == null && t > eos) r.firstAudioLatency = t - eos;
          r.audioBytes += pcm16.length;
        case ToolCall(:final name, :final argsJson):
          final args = (jsonDecode(argsJson.isEmpty ? '{}' : argsJson) as Map).cast<String, Object?>();
          r.tools.add(_ToolCallRec(name, args, t));
          if (r.firstToolLatency == null && t > eos) r.firstToolLatency = t - eos;
        case UserTranscriptDone(:final text) when text.isNotEmpty:
          r.userTranscript = text;
        case AssistantTranscriptDone(:final text):
          r.assistantTranscript = [r.assistantTranscript, text].where((s) => s.isNotEmpty).join(' / ');
        case BackendError(:final message, :final code):
          r.errors.add('$code: $message');
        default:
      }
    }
    if (r.tools.isNotEmpty) {
      final lastTool = r.tools.last.at;
      final a = rig.after<AssistantAudioDelta>(lastTool).firstOrNull;
      if (a != null) r.toolToAudio = a.$1 - lastTool;
    }
    _check(fx, r, rig);
  } catch (e, st) {
    r.reasons.add('exception: $e\n$st');
  } finally {
    await rig.dispose();
  }
  return r;
}

Duration? _pct(List<Duration?> xs, double p) {
  final v = xs.whereType<Duration>().toList()..sort();
  if (v.isEmpty) return null;
  return v[min(v.length - 1, (p * (v.length - 1)).round())];
}

void main() {
  final skip = _live ? null : 'set WOI_LIVE=1 to run live OpenAI tests';
  late CodexAuthManager auth;
  final results = <_RunResult>[];

  setUpAll(() async {
    if (!_live) return;
    auth = CodexAuthManager();
    final c = await auth.credentials();
    if (c == null) fail('no Codex login at ~/.codex/auth.json');
  });

  group('fixtures through RealtimeWsBackend', skip: skip, () {
    final manifest = _live
        ? (jsonDecode(File('${_fixtures.path}/manifest.json').readAsStringSync()) as Map)['fixtures'] as List
        : const [];
    for (final f in manifest.cast<Map>()) {
      final fx = f.cast<String, Object?>();
      if (fx['expected_tool'] == 'stop') continue; // barge-in test below
      test(fx['file'] as String, timeout: const Timeout(Duration(minutes: 2)), () async {
        var r = await _runFixture(auth, fx);
        if (!r.pass && Platform.environment['WOI_LIVE_RETRY'] == '1') {
          print('RETRY ${r.fixture}: $r');
          r = await _runFixture(auth, fx);
        }
        results.add(r);
        print(r);
        expect(r.pass, isTrue, reason: r.reasons.join('; '));
      });
    }

    tearDownAll(() {
      if (results.isEmpty) return;
      final pass = results.where((r) => r.pass).length;
      String p(List<Duration?> xs) =>
          'median ${_pct(xs, .5)?.inMilliseconds ?? '-'} ms, p90 ${_pct(xs, .9)?.inMilliseconds ?? '-'} ms, '
          'n=${xs.whereType<Duration>().length}';
      print('\n=== LIVE FIXTURES: $pass/${results.length} passed (model $_model) ===');
      print('end of speech → speech_stopped: ${p([for (final r in results) r.speechStoppedLatency])}');
      print('end of speech → first audio:    ${p([for (final r in results) r.firstAudioLatency])}');
      print('  (no-tool turns only):         ${p([for (final r in results) if (r.tools.isEmpty) r.firstAudioLatency])}');
      print('end of speech → tool call:      ${p([for (final r in results) r.firstToolLatency])}');
      print('tool call → first audio:        ${p([for (final r in results) r.toolToAudio])}');
    });
  });

  test(
    'barge-in: "Stop" during a long answer truncates at the played position',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final rig = await _LiveRig.create(auth);
      try {
        rig.pipeline.sendText('Tell me a long, detailed story about a lighthouse keeper. Take at least a minute.');
        final ok = await rig.silenceUntil(
          () => rig.events.any((e) => e.$2 is AssistantAudioDelta),
          timeout: const Duration(seconds: 20),
        );
        expect(ok, isTrue, reason: 'no audio for the story');
        final firstAudio = rig.events.firstWhere((e) => e.$2 is AssistantAudioDelta).$1;
        await rig.silenceUntil(() => rig.clock.elapsed - firstAudio > const Duration(milliseconds: 2500));
        final receivedBefore = rig.events.where((e) => e.$2 is AssistantAudioDelta).fold<int>(
          0,
          (s, e) => s + (e.$2 as AssistantAudioDelta).pcm16.length,
        );
        final tStop = rig.clock.elapsed;
        final stopsBefore = rig.audio.player.stops;
        await rig.stream(_wavPcm('10_stop.wav'));
        await rig.silenceUntil(
          () => rig.backend!.truncationsSent > 0 && !rig.backend!.responseActive,
          timeout: const Duration(seconds: 15),
        );
        await rig.silenceUntil(() => false, timeout: const Duration(seconds: 4)); // let the follow-up land
        final started = rig.after<SpeechStarted>(tStop).firstOrNull;
        final truncate = rig.backend!.sentLog.firstWhere(
          (e) => e['type'] == 'conversation.item.truncate',
          orElse: () => const {},
        );
        final errors = [for (final (_, e) in rig.after<BackendError>(Duration.zero)) '${e.code}: ${e.message}'];
        final playedMs = (tStop - firstAudio).inMilliseconds;
        final followUp = [for (final (_, e) in rig.after<AssistantTranscriptDone>(tStop)) e.text];
        print(
          'BARGE-IN: speech_started ${started == null ? '-' : (started.$1 - tStop).inMilliseconds} ms after "Stop" began; '
          'player stops ${rig.audio.player.stops - stopsBefore}; truncate audio_end_ms=${truncate['audio_end_ms']} '
          '(heard ≈$playedMs ms of ${receivedBefore * 1000 ~/ kVoiceBytesPerSecond} ms received); '
          'cancels=${rig.backend!.cancelsSent}; follow-up=$followUp; errors=$errors',
        );
        expect(started, isNotNull, reason: 'no speech_started for "Stop"');
        expect(rig.audio.player.stops, greaterThan(stopsBefore), reason: 'playback not stopped');
        expect(truncate['audio_end_ms'], isA<int>());
        final end = truncate['audio_end_ms'] as int;
        expect(end, greaterThan(1500));
        expect(end, lessThan(receivedBefore * 1000 ~/ kVoiceBytesPerSecond + 3000));
        expect(errors, isEmpty);
        expect(rig.pipeline.bargeIns, greaterThan(0));
      } finally {
        await rig.dispose();
      }
    },
  );

  test(
    'screenshot tiers: 12 screenshots, older ones swapped for 1/5 copies and descriptions in the live session',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      const words = [
        'ALPHA', 'BRAVO', 'CHARLIE', 'DELTA', 'ECHO', 'FOXTROT', //
        'GOLF', 'HOTEL', 'INDIA', 'JULIET', 'KILO', 'LIMA',
      ];
      final dir = await Directory.systemTemp.createTemp('woi_live_tiers_');
      final shots = <Screenshot>[];
      for (var i = 0; i < words.length; i++) {
        final f = '${dir.path}/s$i.png';
        final hue = (i * 30) % 360;
        final res = await Process.run('magick', [
          '-size', '1280x720', 'xc:hsl($hue,60%,25%)', //
          '-fill', 'white', '-pointsize', '150', '-gravity', 'center', '-annotate', '+0+0', words[i],
          '-pointsize', '40', '-annotate', '+0+170', 'Screen ${i + 1} of ${words.length}', f,
        ]);
        expect(res.exitCode, 0, reason: '${res.stderr}');
        shots.add(
          Screenshot(png: File(f).readAsBytesSync(), width: 1280, height: 720, originalWidth: 2560, originalHeight: 1440),
        );
      }
      final client = ResponsesClient(credentials: auth.credentials);
      final gate = Completer<void>();
      final describeMs = <int>[];
      final rig = await _LiveRig.create(
        auth,
        images: (store) => ImageCompactor(
          downscale: (png, w, h) async {
            await gate.future;
            return uiDownscaleOr(png, w, h, dir.path);
          },
          describe: (png, note) async {
            final sw = Stopwatch()..start();
            final d = await responsesDescriber(client)(png, note);
            describeMs.add(sw.elapsedMilliseconds);
            return d;
          },
          save: store.saveImage,
        ),
      );
      try {
        Future<int> turn(String text) async {
          final n = rig.events.where((e) => e.$2 is Usage).length;
          rig.pipeline.sendText(text);
          await rig.silenceUntil(
            () => rig.events.where((e) => e.$2 is Usage).length > n && !rig.backend!.responseActive,
            timeout: const Duration(seconds: 40),
          );
          return (rig.events.where((e) => e.$2 is Usage).last.$2 as Usage).inputTokens;
        }

        final base = await turn('Reply only: OK.');
        for (var i = 0; i < shots.length; i++) {
          await rig.pipeline.attachScreenshot(shots[i], note: 'Screenshot ${i + 1}.');
        }
        final full = await turn('I just sent you twelve screenshots. Reply only: OK.');
        final perFull = (full - base - 30) / shots.length;
        final metered = rig.context.estimatedTokens;
        final sw = Stopwatch()..start();
        gate.complete();
        await rig.pipeline.compactImages();
        final tierMs = sw.elapsedMilliseconds;
        expect(rig.backend!.imagesReplaced, greaterThanOrEqualTo(9));
        final meterAfter = rig.context.estimatedTokens;
        final tiered = await turn(
          'Reply in one line: the big word on screenshot 1, the big word on screenshot 6, and on screenshot 12.',
        );
        final answer = [for (final (_, e) in rig.after<AssistantTranscriptDone>(Duration.zero)) e.text].last;
        final msgs = rig.pipeline.conversation.messages.where((m) => m.image != null).toList();
        final tiers = msgs.map(imageTierOf).toList();
        final ids = rig.backend!.serverItemIds;
        final errors = [for (final (_, e) in rig.after<BackendError>(Duration.zero)) '${e.code}: ${e.message}'];
        final p = rig.context.parts();
        final descTokens = [for (final m in msgs.take(4)) ContextManager.textTokens(imageDescriptionOf(m) ?? '') + 20];
        final perReduced = (tiered - base - 60 - 3 * perFull - descTokens.fold(0, (a, b) => a + b)) / 5;
        print(
          'IMAGE COST: base $base, full ≈${perFull.round()}/image, 1/5 ≈${perReduced.round()}/image, '
          'descriptions $descTokens',
        );
        print(
          'IMAGE TIERS: input tokens $full → $tiered (meter $metered → $meterAfter, saved ${p.imagesSaved}); '
          'tiers ${tiers.map((t) => t.name[0]).join()}; replaced ${rig.backend!.imagesReplaced} items in $tierMs ms; '
          'describe ms $describeMs; server items: ${ids.where((i) => i.startsWith('woi_img')).length} images, '
          '${ids.where((i) => i.startsWith('woi_ctx')).length} notes; answer="$answer"; errors=$errors; '
          'description[0]="${imageDescriptionOf(msgs.first)}"',
        );
        expect(tiers, [
          ...List.filled(4, ImageTier.described),
          ...List.filled(5, ImageTier.reduced),
          ...List.filled(3, ImageTier.full),
        ]);
        expect(errors, isEmpty);
        expect(ids.where((i) => i.startsWith('woi_img')), hasLength(8));
        expect(ids.where((i) => i.startsWith('woi_ctx')), hasLength(4));
        expect(tiered, lessThan(full * 0.8), reason: 'the live context must shrink');
        expect(meterAfter, lessThan(metered * 0.8), reason: 'the meter reflects the savings');
        expect(File(msgs.first.image!.path).readAsBytesSync(), shots.first.png, reason: 'original kept');
        final a = answer.toUpperCase();
        expect(a, contains('ALPHA'), reason: 'described image content lost');
        expect(a, contains('FOXTROT'), reason: '1/5 image unreadable');
        expect(a, contains('LIMA'));
      } finally {
        await rig.dispose();
      }
    },
  );

  group('compaction on the live session', skip: skip, () {
    test('summary injected as a system item, old items deleted, facts recalled', () async {
      final b = RealtimeWsBackend(credentialsProvider: auth.credentials, keepRecentTurns: 1, log: (_) {})
        ..recordSent = true;
      final events = <BackendEvent>[];
      final sub = b.events.listen(events.add);
      try {
        await b.connect(
          SessionConfig(model: _model, voice: 'marin', instructions: 'Be very brief. Reply in text-like short sentences.'),
        );
        Future<void> turn(String text) async {
          final n = events.whereType<ResponseDone>().length;
          b.sendText(text);
          await waitFor(() => events.whereType<ResponseDone>().length > n, timeout: const Duration(seconds: 30));
        }

        await turn('My name is Alice. Just say OK.');
        await turn('My cat is called Whiskers. Just say OK.');
        await turn('My favourite colour is green. Just say OK.');
        final before = b.serverItemIds.length;
        final sw = Stopwatch()..start();
        final res = await b.applySummary('Facts: the user is named Alice and has a dog named Rex.');
        final applyMs = sw.elapsedMilliseconds;
        final after = b.serverItemIds.length;
        final n = events.whereType<AssistantTranscriptDone>().length;
        await turn("What's my name, my pet's name, and my favourite colour? One short sentence.");
        final answer = events.whereType<AssistantTranscriptDone>().skip(n).map((e) => e.text).join(' ');
        final errors = events.whereType<BackendError>().map((e) => '${e.code}: ${e.message}').toList();
        print(
          'COMPACTION: ${res.method.name} removed=${res.removedItems} items $before→$after in $applyMs ms; '
          'answer="$answer"; errors=$errors',
        );
        expect(res.method, ContextApplyMethod.deletedItems);
        expect(errors, isEmpty);
        expect(answer.toLowerCase(), contains('alice'));
        expect(answer.toLowerCase(), contains('rex'), reason: 'summary fact not used');
        expect(answer.toLowerCase(), contains('green'), reason: 'kept recent turn lost');
        expect(answer.toLowerCase(), isNot(contains('whiskers')), reason: 'deleted turn still visible');
      } finally {
        await sub.cancel();
        await b.close();
      }
    });

    test('pipeline: real compressor triggers the banner with before→after tokens and applies it', () async {
      final client = ResponsesClient(credentials: auth.credentials);
      // Threshold just above the base context (instructions + 11 tool schemas
      // ≈ 900 tokens), so the two long early turns push it over.
      final rig = await _LiveRig.create(auth, compressor: ResponsesCompressor(client), threshold: 1500);
      try {
        final compactions = <ContextCompacted>[];
        final sub = rig.pipeline.compactionEvents.listen(compactions.add);
        Future<void> say(String text) async {
          final n = rig.events.where((e) => e.$2 is ResponseDone).length;
          rig.pipeline.sendText(text);
          await rig.silenceUntil(
            () => rig.events.where((e) => e.$2 is ResponseDone).length > n && !rig.backend!.responseActive,
            timeout: const Duration(seconds: 30),
          );
        }

        final filler = List.filled(
          12,
          'We talked at length about the weather, the traffic on the way in, and what to have for lunch.',
        ).join(' ');
        await say('Remember: my project lives in ~/code/woi and the deadline is Friday. $filler Just say OK.');
        await say('We decided to use Flutter for the UI. $filler Just say OK.');
        await say('Also note my notes file is ~/notes.txt. Just say OK.');
        await say('One more: the staging server is called kestrel. Just say OK.');
        await rig.silenceUntil(
          () => compactions.isNotEmpty && rig.pipeline.lastContextApply != null,
          timeout: const Duration(seconds: 60),
        );
        await sub.cancel();
        final c = compactions.firstOrNull;
        final sys = rig.pipeline.conversation.messages
            .where((m) => m.meta['type'] == 'compaction')
            .map((m) => m.text)
            .toList();
        print(
          'PIPELINE COMPACTION: ${c?.tokensBefore}→${c?.tokensAfter} tokens, '
          'apply=${rig.pipeline.lastContextApply}; banner=$sys; summary="${c?.summary}"',
        );
        expect(c, isNotNull, reason: 'no compaction');
        expect(c!.tokensAfter, lessThan(c.tokensBefore));
        expect(sys.single, contains('→'));
        expect(rig.pipeline.lastContextApply!.method, ContextApplyMethod.deletedItems);
        expect(rig.pipeline.lastContextApply!.removedItems, greaterThan(0));
        expect(c.summary.toLowerCase(), contains('woi'));
        // The live session still knows the compacted facts (summary) and recent turns.
        final n = rig.events.where((e) => e.$2 is AssistantTranscriptDone).length;
        await say('Where does my project live, and what is the staging server called? One short sentence.');
        final answer = [
          for (final e in rig.events.skip(0).where((e) => e.$2 is AssistantTranscriptDone).skip(n))
            (e.$2 as AssistantTranscriptDone).text,
        ].join(' ');
        print('PIPELINE COMPACTION recall: "$answer"');
        expect(answer.toLowerCase(), contains('woi'));
        expect(answer.toLowerCase(), contains('kestrel'));
      } finally {
        await rig.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('Responses API (chatgpt.com/backend-api/codex)', skip: skip, () {
    test('compressor (gpt-6-luna) keeps facts/paths/decisions and describes screenshots', () async {
      final client = ResponsesClient(credentials: auth.credentials);
      final dir = await Directory.systemTemp.createTemp('woi_live_comp_');
      addTearDown(() => dir.delete(recursive: true));
      final png = File('${dir.path}/shot.png')..writeAsBytesSync(File('${_fixtures.path}/test_screen.png').readAsBytesSync());
      final sw = Stopwatch()..start();
      final res = await ResponsesCompressor(client).compress([
        Message(kind: MessageKind.user, text: 'I am Bob. My project is in ~/code/woi.'),
        Message(kind: MessageKind.assistant, text: 'Got it, Bob.'),
        Message(
          kind: MessageKind.user,
          text: 'What do you see?',
          image: ImageAttachment(path: png.path, width: 256, height: 256, originalWidth: 1920, originalHeight: 1080),
        ),
        Message(kind: MessageKind.assistant, text: 'A blue bar above a red circle.'),
        Message(kind: MessageKind.user, text: "Let's use PostgreSQL, not SQLite. TODO: write the migration script."),
        Message(kind: MessageKind.assistant, text: 'Decided: PostgreSQL. I will remember the migration TODO.'),
      ], model: const AppSettings().compressionModel);
      final s = res.summary.toLowerCase();
      print('COMPRESSOR: ${sw.elapsedMilliseconds} ms, ~${res.tokensAfter} tokens: ${res.summary.replaceAll('\n', ' | ')}');
      expect(s, contains('bob'));
      expect(s, contains('~/code/woi'));
      expect(s, contains('postgres'));
      expect(s, contains('migration'));
      expect(s, contains('red'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('delegate (gpt-6.1-sol) runs the tool loop with confirmations and returns a concise result', () async {
      final client = ResponsesClient(credentials: auth.credentials);
      final root = await Directory.systemTemp.createTemp('woi_live_del_');
      addTearDown(() => root.delete(recursive: true));
      final shell = FakeShell();
      final confirm = FakeConfirmations();
      final services = PlatformServices(
        paths: AppPaths(dataDir: '${root.path}/.woi', homeDir: root.path),
        audio: FakeAudioIO(),
        screen: _FixtureScreen(),
        input: FakeInput(),
        shell: shell,
        files: LocalFiles(homeDir: root.path),
        viewer: FakeViewer(),
      );
      late ToolRegistry registry;
      final steps = <String>[];
      final env = ToolEnvironment(
        platform: services,
        confirmations: confirm,
        delegate: StubDelegateBackend(),
        settings: () => const AppSettings(),
        onScreenshot: (s, n) async {},
      );
      final delegate = ResponsesDelegate(
        client,
        tools: () => registry,
        latestScreenshot: () => env.lastScreenshot?.png,
        onStep: (t, a) => steps.add(t),
      );
      registry = ToolRegistry()..registerAll(builtinTools(env));
      final sw = Stopwatch()..start();
      final r = await delegate.runTask(
        'Write a Python script ~/dupes.py that finds duplicate files in a folder (by content hash), '
        'then run it on ~ with python3 to check it works.',
        model: const AppSettings().delegateModel,
      );
      final script = File('${root.path}/dupes.py');
      print(
        'DELEGATE: ${sw.elapsedMilliseconds} ms, steps=$steps, tokens=${r.tokensUsed}, '
        'confirmed writes=${confirm.writeRequests.length}, shell=${shell.commands}; output="${r.output}"',
      );
      expect(r.success, isTrue);
      expect(steps, contains('write_file'));
      expect(confirm.writeRequests, isNotEmpty);
      expect(script.existsSync(), isTrue);
      expect(script.readAsStringSync(), contains('hashlib'));
      expect(r.output.split(RegExp(r'\s+')).length, lessThan(120));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

/// Engine downscale, or ImageMagick when the test runner has no codec.
Future<Uint8List> uiDownscaleOr(Uint8List png, int w, int h, String tmp) async {
  try {
    return await uiDownscale(png, w, h).timeout(const Duration(seconds: 5));
  } catch (_) {
    final src = '$tmp/in_${png.hashCode}.png', dst = '$tmp/out_${png.hashCode}.png';
    File(src).writeAsBytesSync(png);
    final r = await Process.run('magick', [src, '-resize', '${w}x$h!', dst]);
    if (r.exitCode != 0) throw StateError('${r.stderr}');
    return File(dst).readAsBytesSync();
  }
}
