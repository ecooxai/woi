// REAL end-to-end test of the gpt-live WebRTC backend (uses the ChatGPT
// login in ~/.codex/auth.json, PipeWire and the network).
//
//   xvfb-run -a flutter test integration_test/live_gpt_live_test.dart -d linux
//
// Each fixture (research/fixtures/*.wav) is played into a PipeWire virtual
// microphone that libwebrtc captures; the assistant's WebRTC audio goes to a
// null sink whose monitor is recorded to measure when it is actually audible.
// Platform effects are fakes (clicks, typing and bash are recorded;
// confirmations are auto-approved); delegations run the real gpt-6-luna tool
// loop and delegate_task runs the real gpt-6.1-sol delegate.
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:woi/core/app_controller.dart' show kAssistantInstructions;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_rtc_flutter.dart';
import 'package:woi/core/voice/live_rtc_transport.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/app_paths.dart';
import 'package:woi/platform/linux/linux_files.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/platform/shell.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import '../test/fakes/fakes.dart';

const _micSink = 'woi_fixture_sink';
const _micSource = 'woi_virtual_mic';
const _micLabel = 'WoiVirtualMic';
const _outSink = 'woi_speaker';
const _outLabel = 'WoiSpeaker';

/// Registry tools that satisfy each manifest tool.
const _accept = {
  'click_screen': {'click_screen'},
  'type_text': {'type_text'},
  'run_command': {'run_bash'},
  'read_file': {'read_file', 'show_file'},
  'edit_file': {'edit_file', 'write_file'},
  'take_screenshot': {'take_screenshot'},
  'delegate_task': {'delegate_task'},
  'play_media': {'show_file'},
};

Future<String> _sh(String cmd, List<String> args) async {
  final r = await Process.run(cmd, args);
  if (r.exitCode != 0) throw StateError('$cmd ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

/// A believable 1280x720 "desktop" (the delegation model gets real pixels).
Future<Uint8List> _desktopPng(String dir) async {
  final path = '$dir/desktop.png';
  await _sh('magick', [
    '-size', '1280x720', 'xc:#20242b', //
    '-fill', '#2e3440', '-draw', 'rectangle 0,0 1280,32',
    '-fill', '#d8dee9', '-pointsize', '16', '-annotate', '+12+22', 'Activities    Files    Terminal',
    '-fill', '#3b4252', '-draw', 'rectangle 240,140 1040,580',
    '-fill', '#eceff4', '-pointsize', '18', '-annotate', '+260+170', 'notes.txt - Text Editor',
    '-fill', '#e5e9f0', '-pointsize', '16', '-annotate', '+260+210', 'groceries:\n- eggs\n- bread',
    'png:$path',
  ]);
  return File(path).readAsBytes();
}

class _Screen implements ScreenCapture {
  _Screen(this.png);
  final Uint8List png;
  int captures = 0;
  @override
  Future<Screenshot> capture({int maxWidth = 1280}) async {
    captures++;
    return Screenshot(png: png, width: 1280, height: 720, originalWidth: 1920, originalHeight: 1080);
  }
}

/// Records commands; answers `ls` like a small home folder.
class _Shell implements Shell {
  final commands = <String>[];
  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) async {
    commands.add(command);
    final ls = RegExp(r'^\s*ls\b').hasMatch(command);
    return ShellResult(
      exitCode: ls ? 0 : 0,
      stdout: ls ? 'Desktop\nDocuments\nREADME.md\ndemo.mp4\nnotes.txt\n' : '',
      stderr: '',
      elapsed: const Duration(milliseconds: 4),
    );
  }
}

class _Fixture {
  _Fixture(Map<String, Object?> j, this.dir)
    : file = j['file']! as String,
      text = j['text']! as String,
      tool = j['expected_tool'] as String?;
  final String file, text, dir;
  final String? tool;
  String get path => '$dir/$file';
}

/// Offset (ms) of the last voiced 20 ms window of a 24 kHz s16 WAV.
int _speechEndMs(Uint8List wav) {
  final pcm = Uint8List.sublistView(wav, 44);
  final bd = ByteData.sublistView(pcm);
  const win = 480 * 2;
  var last = 0;
  for (var o = 0; o + win <= pcm.length; o += win) {
    var sum = 0.0;
    for (var i = o; i < o + win; i += 2) {
      final v = bd.getInt16(i, Endian.little) / 32768.0;
      sum += v * v;
    }
    if (sqrt(sum / 480) > 0.02) last = (o + win) ~/ 48;
  }
  return last;
}

double _rms(Uint8List pcm) {
  final bd = ByteData.sublistView(pcm);
  var sum = 0.0;
  final n = pcm.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  return n == 0 ? 0 : sqrt(sum / n);
}

/// Records the WebRTC playback sink's monitor (24 kHz mono s16).
class _SpeakerRecorder {
  Process? _p;
  final _buf = BytesBuilder(copy: false);
  late DateTime startedAt;

  Future<void> start() async {
    _p = await Process.start('parec', [
      '-d', '$_outSink.monitor', '--format=s16le', '--rate=24000', '--channels=1', '--latency-msec=20', //
    ]);
    startedAt = DateTime.now();
    _p!.stdout.listen(_buf.add);
    unawaited(_p!.stderr.drain<void>());
  }

  /// First time after [from] at which the speaker output is voiced, or null.
  DateTime? firstVoicedAfter(DateTime from, {DateTime? until}) {
    final pcm = _buf.toBytes();
    final bd = ByteData.sublistView(pcm);
    var o = max(0, from.difference(startedAt).inMilliseconds * 48) & ~1;
    final end = until == null ? pcm.length : min(pcm.length, until.difference(startedAt).inMilliseconds * 48);
    const win = 480 * 2;
    for (; o + win <= end; o += win) {
      var sum = 0.0;
      for (var i = o; i < o + win; i += 2) {
        final v = bd.getInt16(i, Endian.little) / 32768.0;
        sum += v * v;
      }
      if (sqrt(sum / 480) > 0.01) return startedAt.add(Duration(milliseconds: o ~/ 48));
    }
    return null;
  }

  double voicedSeconds() {
    final pcm = _buf.toBytes();
    var voiced = 0;
    for (var o = 0; o + 960 <= pcm.length; o += 960) {
      if (_rms(Uint8List.sublistView(pcm, o, o + 960)) > 0.01) voiced++;
    }
    return voiced * 0.02;
  }

  void stop() => _p?.kill();
}

class _Result {
  _Result(this.f);
  final _Fixture f;
  bool pass = false;
  String why = '';
  final tools = <String>[];
  String assistant = '';
  int? speechToFirstAudioRtp;
  int? speechToFirstAudioSideband;
  int? speechToDelegation;
  DelegationReport? delegation;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final fixturesDir = Platform.environment['WOI_FIXTURES'] ?? '${Directory.current.path}/../research/fixtures';
  final skip = !File('$fixturesDir/manifest.json').existsSync()
      ? 'no fixtures at $fixturesDir'
      : !File(CodexAuthInfo.defaultPath()).existsSync()
      ? 'no Codex login'
      : null;

  final modules = <String>[];

  setUpAll(() async {
    if (skip != null) return;
    // Other tools on this machine `pkill -x woi` to close the app; give the
    // test process its own name (/proc/self/comm = thread-group leader).
    try {
      File('/proc/self/comm').writeAsStringSync('woi-livetest');
    } catch (_) {}
    // run_live.sh owns the devices (and restores the default source even on
    // a crash); standalone runs create them here and unload in tearDownAll.
    final sources = await _sh('pactl', ['list', 'short', 'sources']);
    if (sources.contains(_micSource) && (await _sh('pactl', ['list', 'short', 'sinks'])).contains(_outSink)) return;
    Future<void> load(List<String> args) async => modules.add(await _sh('pactl', ['load-module', ...args]));
    await load(['module-null-sink', 'sink_name=$_micSink', 'sink_properties=device.description=WoiFixtureSink']);
    await load([
      'module-remap-source',
      'master=$_micSink.monitor',
      'source_name=$_micSource',
      'source_properties=device.description=$_micLabel',
    ]);
    await load(['module-null-sink', 'sink_name=$_outSink', 'sink_properties=device.description=$_outLabel']);
  });

  tearDownAll(() async {
    for (final id in modules.reversed) {
      await Process.run('pactl', ['unload-module', id]);
    }
  });

  testWidgets('gpt-live: fixtures → delegation tools → spoken results', skip: skip != null, (tester) async {
    final manifest = jsonDecode(File('$fixturesDir/manifest.json').readAsStringSync()) as Map;
    var fixtures = [for (final f in manifest['fixtures'] as List) _Fixture((f as Map).cast(), fixturesDir)];
    final only = Platform.environment['WOI_ONLY'];
    if (only != null) fixtures = fixtures.where((f) => only.split(',').any(f.file.contains)).toList();

    final fp = await FakePlatform.create();
    final home = fp.root.path;
    File('$home/notes.txt').writeAsStringSync('groceries:\n- eggs\n- bread\n');
    File('$home/README.md').writeAsStringSync('# Demo project\n\nA tiny demo used by the Woi live test.\n');
    File('$home/demo.mp4').writeAsBytesSync(Uint8List(1024));
    final screen = _Screen(await _desktopPng(home));
    final shell = _Shell();
    final services = PlatformServices(
      paths: AppPaths(dataDir: '$home/data', homeDir: home),
      audio: fp.audio,
      screen: screen,
      input: fp.input,
      shell: shell,
      files: LocalFiles(homeDir: home),
      viewer: fp.viewer,
    );
    final store = HistoryStore(services.paths);
    await store.init();

    final auth = CodexAuthManager();
    Future<Credentials?> creds() => auth.credentials();
    final confirm = FakeConfirmations();
    late final TurnPipeline p;
    late final ToolRegistry tools;
    late final ToolEnvironment env;
    final solClient = ResponsesClient(credentials: creds);
    final delegate = ResponsesDelegate(
      solClient,
      tools: () => tools,
      latestScreenshot: () => env.lastScreenshot?.png,
      reasoningEffort: 'low',
      maxSteps: 4,
    );
    env = ToolEnvironment(
      platform: services,
      confirmations: confirm,
      delegate: delegate,
      settings: () => const AppSettings(),
      onScreenshot: (s, note) => p.attachScreenshot(s, note: note),
    );
    tools = ToolRegistry()..registerAll(builtinTools(env));

    final backend = LiveWebRtcBackend(
      transportFactory: () => FlutterLiveRtcTransport(
        options: const LiveRtcOptions(inputDeviceMatch: _micLabel, outputDeviceMatch: _outLabel),
      ),
      credentialsProvider: creds,
      delegationReasoningEffort: Platform.environment['WOI_EFFORT'] ?? 'low',
    );
    final events = <(DateTime, BackendEvent)>[];
    final evSub = backend.events.listen((e) => events.add((DateTime.now(), e)));
    final reports = <DelegationReport>[];
    final repSub = backend.delegations.listen(reports.add);

    final speaker = _SpeakerRecorder();
    await speaker.start();

    final connectSw = Stopwatch()..start();
    p = TurnPipeline(
      backendFactory: () => backend,
      audio: fp.audio,
      screen: screen,
      tools: tools,
      context: ContextManager(compressor: StubCompressor(latency: Duration.zero), threshold: 1000000),
      store: store,
      conversation: Conversation(),
      sessionConfig: (c) async => SessionConfig(
        model: 'gpt-live-1.1',
        voice: 'cove',
        instructions: kAssistantInstructions,
        tools: tools.specs,
        credentials: await creds(),
      ),
      options: () => const PipelineOptions(),
      onScreenshotCaptured: (s) => env.lastScreenshot = s,
    );
    await p.start();
    expect(p.status, SessionStatus.connected, reason: p.statusDetail ?? '');
    final connectMs = connectSw.elapsedMilliseconds;
    // ignore: avoid_print
    print('connected in ${connectMs}ms (${backend.timings}) via ${backend.transportDescription}');
    expect(fp.audio.mic, isNull, reason: 'WebRTC owns the mic');
    if (Platform.environment['WOI_DEBUG_AUDIO'] != null) {
      // ignore: avoid_print
      print((await Process.run('sh', ['-c', 'pactl list sink-inputs; pactl list source-outputs'])).stdout);
    }
    await Future<void>.delayed(const Duration(seconds: 2));

    DateTime lastActivity() {
      for (final (t, e) in events.reversed) {
        if (e is AssistantAudioDelta && _rms(e.pcm16) < 0.01) continue;
        return t;
      }
      return DateTime(2000);
    }

    final results = <_Result>[];
    for (final f in fixtures) {
      final r = _Result(f);
      results.add(r);
      final evFrom = events.length;
      final repFrom = reports.length;
      final toolFrom = p.conversation.messages.length;
      final wav = File(f.path).readAsBytesSync();
      final speechEnd = _speechEndMs(wav);

      final playStart = DateTime.now();
      await _sh('paplay', ['-d', _micSink, f.path]);
      final tEnd = playStart.add(Duration(milliseconds: speechEnd));

      // Wait for the turn (and any delegation) to settle.
      final deadline = DateTime.now().add(Duration(seconds: f.tool == 'delegate_task' ? 150 : 45));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final quiet = DateTime.now().difference(lastActivity()) > const Duration(milliseconds: 3500);
        final busy = backend.pendingDelegations > 0 || p.phase == AssistantPhase.speaking;
        final spoke = events.skip(evFrom).any((e) => e.$2 is AssistantTranscriptDelta);
        if (quiet && !busy && (spoke || DateTime.now().difference(tEnd) > const Duration(seconds: 12))) break;
      }

      final evs = events.skip(evFrom).toList();
      r.assistant = evs.map((e) => e.$2).whereType<AssistantTranscriptDelta>().map((e) => e.text).join().trim();
      r.tools.addAll([
        for (final m in p.conversation.messages.skip(toolFrom))
          if (m.kind == MessageKind.tool) m.tool!.name,
      ]);
      for (final (t, e) in evs) {
        if (e is AssistantAudioDelta && t.isAfter(tEnd) && _rms(e.pcm16) > 0.01) {
          r.speechToFirstAudioSideband = t.difference(tEnd).inMilliseconds;
          break;
        }
      }
      r.speechToFirstAudioRtp = speaker.firstVoicedAfter(tEnd)?.difference(tEnd).inMilliseconds;
      final reps = reports.skip(repFrom).toList();
      if (reps.isNotEmpty) {
        r.delegation = reps.first;
        r.speechToDelegation = reps.first.createdAt.difference(tEnd).inMilliseconds;
      }

      final spoke = r.assistant.isNotEmpty;
      final acted = r.tools.where((t) => t != 'take_screenshot').toList();
      if (f.tool == null) {
        r.pass = spoke && acted.isEmpty;
        r.why = spoke ? (acted.isEmpty ? 'chat' : 'unexpected tools $acted') : 'silent';
      } else if (f.tool == 'stop') {
        r.pass = acted.isEmpty;
        r.why = acted.isEmpty ? 'no action' : 'unexpected tools $acted';
      } else if (f.tool == 'take_screenshot') {
        final looked = reps.any((d) => d.usedScreenshot) || r.tools.contains('take_screenshot');
        r.pass = looked && spoke;
        r.why = looked ? (spoke ? 'looked + spoke' : 'looked, silent') : 'no screenshot';
      } else {
        final ok = r.tools.any(_accept[f.tool]!.contains);
        final done = [
          for (final m in p.conversation.messages.skip(toolFrom))
            if (m.kind == MessageKind.tool && m.tool!.finishedAt != null) m.tool!.finishedAt!,
        ];
        final lastDone = done.isEmpty ? null : done.reduce((a, b) => a.isAfter(b) ? a : b);
        final spokeAfter =
            lastDone != null && evs.any((e) => e.$2 is AssistantTranscriptDelta && e.$1.isAfter(lastDone));
        r.pass = ok && spokeAfter;
        r.why = ok ? (spokeAfter ? 'tool + spoken result' : 'tool, result not spoken') : 'missing ${f.tool}';
      }
      // ignore: avoid_print
      print(
        '[${r.pass ? 'PASS' : 'FAIL'}] ${f.file} (${r.why}) tools=${r.tools} '
        'eos→audio rtp=${r.speechToFirstAudioRtp}ms sideband=${r.speechToFirstAudioSideband}ms '
        'eos→delegation=${r.speechToDelegation}ms ${r.delegation?.timingSummary() ?? ''}\n'
        '    said: "${r.assistant.length > 160 ? '${r.assistant.substring(0, 160)}…' : r.assistant}"',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    // Clips: save the last assistant turn's audio for inspection.
    final passed = results.where((r) => r.pass).length;
    List<int> pick(int? Function(_Result r) f) => [for (final r in results) ?f(r)]..sort();
    String stats(List<int> v) =>
        v.isEmpty ? '-' : 'median ${v[v.length ~/ 2]}ms, min ${v.first}ms, max ${v.last}ms (n=${v.length})';
    final dlg = [for (final r in results) ?r.delegation];
    // ignore: avoid_print
    print('''
==== gpt-live live test: $passed/${results.length} passed
connect: ${connectMs}ms (${backend.timings})
end of speech → first audible audio (RTP): ${stats(pick((r) => r.speechToFirstAudioRtp))}
end of speech → first voiced sideband audio: ${stats(pick((r) => r.speechToFirstAudioSideband))}
end of speech → delegation.created: ${stats(pick((r) => r.speechToDelegation))}
delegation → first tool call: ${stats([for (final d in dlg) ?d.firstToolCall?.inMilliseconds]..sort())}
delegation → tools done: ${stats([for (final d in dlg) ?d.toolsDone?.inMilliseconds]..sort())}
delegation → result appended: ${stats([for (final d in dlg) ?d.total?.inMilliseconds]..sort())}
delegation → spoken: ${stats([for (final d in dlg) ?d.spoken?.inMilliseconds]..sort())}
speaker voiced total: ${speaker.voicedSeconds().toStringAsFixed(1)}s; clicks=${fp.input.log}; bash=${shell.commands}
confirmations: writes=${confirm.writeRequests.length} commands=${confirm.commandRequests}; viewer=${fp.viewer.shown.length}
''');

    await p.shutdown();
    await evSub.cancel();
    await repSub.cancel();
    speaker.stop();
    solClient.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await fp.dispose();

    expect(speaker.voicedSeconds(), greaterThan(0.5 * results.length), reason: 'assistant audio played over WebRTC');
    expect(
      passed,
      results.length,
      reason: results.where((r) => !r.pass).map((r) => '${r.f.file}: ${r.why}').join('; '),
    );
  });
}
