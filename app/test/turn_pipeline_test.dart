import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/earcon.dart';
import 'package:woi/core/audio/stop_word_spotter.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/media/media_context.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/echo_guard.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/context_images.dart';
import 'package:woi/core/voice/mock_voice_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/camera.dart' show jpegSize;
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

class _ShortCompressor implements Compressor {
  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async =>
      const CompressionResult(summary: 'Earlier: small talk.', tokensAfter: 5);
}

/// Wires a [TurnPipeline] to fakes; [backend] is created by [factory].
class Harness {
  Harness._(this.fp, this.store, this.context, this.confirm, this.backendFactory);

  final FakePlatform fp;
  final HistoryStore store;
  final ContextManager context;
  final FakeConfirmations confirm;
  final VoiceBackend Function() backendFactory;
  late final ToolRegistry tools;
  late final TurnPipeline pipeline;
  PipelineOptions options = const PipelineOptions(screenshotDelay: Duration(milliseconds: 200));
  AppSettings settings = const AppSettings();
  VoiceBackend? lastBackend;

  ScriptedBackend get scripted => lastBackend! as ScriptedBackend;
  Conversation get conv => pipeline.conversation;

  static Future<Harness> create({
    VoiceBackend Function()? backend,
    PipelineOptions? options,
    Compressor? compressor,
    int threshold = 100000,
    ImageCompactor? Function(HistoryStore store)? images,
    void Function(TurnPipeline p)? setup,
    EchoGuard? echoGuard,
    StopWordSpotter Function()? stopWordSpotter,
  }) async {
    final fp = await FakePlatform.create();
    final store = HistoryStore(fp.services.paths);
    await store.init();
    final ctx = ContextManager(
      compressor: compressor ?? StubCompressor(latency: Duration.zero),
      threshold: threshold,
      keepRecentTurns: 2,
      minInterval: Duration.zero,
    );
    final h = Harness._(fp, store, ctx, FakeConfirmations(), backend ?? () => ScriptedBackend());
    if (options != null) h.options = options;
    final env = ToolEnvironment(
      platform: fp.services,
      confirmations: h.confirm,
      delegate: StubDelegateBackend(),
      settings: () => h.settings,
      onScreenshot: (s, note) => h.pipeline.attachScreenshot(s, note: note),
    );
    h.tools = ToolRegistry()..registerAll(builtinTools(env));
    h.pipeline = TurnPipeline(
      backendFactory: () => h.lastBackend = h.backendFactory(),
      audio: fp.audio,
      screen: fp.screen,
      tools: h.tools,
      context: ctx,
      store: store,
      conversation: Conversation(),
      sessionConfig: (c) async =>
          SessionConfig(model: 'gpt-live-1.1', voice: 'marin', instructions: 'test', tools: h.tools.specs),
      options: () => h.options,
      onScreenshotCaptured: (s) => env.lastScreenshot = s,
      imageCompactor: images?.call(store),
      echoGuard: echoGuard,
      stopWordSpotter: stopWordSpotter,
    );
    setup?.call(h.pipeline);
    await h.pipeline.start();
    return h;
  }

  FakeMic get mic => fp.audio.mic!;
  FakePcmPlayer get player => fp.audio.player;

  /// Feeds [ms] of audio in 20 ms chunks, yielding to timers in between.
  Future<void> speak(int ms, {int amplitude = 6000, bool realtime = false, bool voiced = false}) async {
    for (var t = 0; t < ms; t += 20) {
      mic.push(voiced ? voice(20, amplitude: amplitude, phase0: t * 24) : pcm(20, amplitude: amplitude));
      if (realtime) await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose() async {
    await pipeline.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await fp.dispose();
  }
}

/// Records what the pipeline feeds it; [hit] plays a spotter hit.
class FakeStopWordSpotter implements StopWordSpotter {
  final _hits = StreamController<KwsHit>.broadcast();
  final starts = <List<String>>[];
  int micChunks = 0;
  final refPlayAt = <DateTime>[];
  bool disposed = false;

  void hit([String keyword = 'STOP']) =>
      _hits.add(KwsHit(keyword: keyword, micTime: DateTime.now(), threshold: 0.4));

  @override
  Stream<KwsHit> get hits => _hits.stream;
  @override
  Future<void> start(List<String> keywords) async => starts.add(keywords);
  @override
  void addMic(Uint8List pcm16, DateTime at) => micChunks++;
  @override
  void addReference(Uint8List pcm16, DateTime playAt) => refPlayAt.add(playAt);
  @override
  Future<void> dispose() async {
    disposed = true;
    await _hits.close();
  }
}

Iterable<Message> ofKind(Conversation c, MessageKind k) => c.messages.where((m) => m.kind == k);

void main() {
  group('stop word spotting (kws)', () {
    Future<(Harness, FakeStopWordSpotter?, List<int>)> speaking({bool on = true, int audioMs = 4000}) async {
      FakeStopWordSpotter? kws;
      final created = <int>[0];
      final h = await Harness.create(
        options: PipelineOptions(autoScreenshot: false, stopWordDetection: on, stopWords: const ['stop']),
        stopWordSpotter: () {
          created[0]++;
          return kws = FakeStopWordSpotter();
        },
      );
      final b = h.scripted;
      b.emit(const AssistantTranscriptDelta('Once upon a time there was a lighthouse keeper. '));
      b.emit(AssistantAudioDelta(voice(audioMs, amplitude: 8000, f0: 140)));
      for (var i = 0; i < 10; i++) {
        h.mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      await Future<void>.delayed(Duration.zero);
      return (h, kws, created);
    }

    test('a hit while Woi speaks pauses and cuts locally; it stays stopped', () async {
      final (h, kws, _) = await speaking();
      expect(kws, isNotNull);
      expect(kws!.starts, [
        ['stop'],
      ]);
      expect(kws.refPlayAt, hasLength(1), reason: 'the reference is fed with its play time');
      expect(kws.micChunks, 10, reason: 'the mic is fed while Woi is audible');
      final written = h.player.written.length;
      kws.hit();
      await Future<void>.delayed(Duration.zero);
      expect(h.pipeline.kwsCuts, 1);
      expect(h.pipeline.localCuts, 1);
      expect(h.pipeline.bargeIns, 1);
      expect(h.scripted.cancels, 1);
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
      expect(h.pipeline.phase, AssistantPhase.listening);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(h.pipeline.onsetsResumed, 0);
      expect(h.player.written.length, written, reason: 'Woi stays silent');
      expect(h.scripted.texts, isEmpty, reason: 'no response created');
      await h.dispose();
      expect(kws.disposed, isTrue);
    });

    test('a hit while Woi is silent is ignored, and the mic is not fed', () async {
      final (h, kws, _) = await speaking(audioMs: 200);
      h.player.playing = false;
      await Future<void>.delayed(const Duration(milliseconds: 700)); // played + the echo tail
      final fed = kws!.micChunks;
      for (var i = 0; i < 5; i++) {
        h.mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      expect(kws.micChunks, fed, reason: 'no CPU while Woi is silent');
      kws.hit();
      await Future<void>.delayed(Duration.zero);
      expect(h.pipeline.kwsIgnored, 1);
      expect(h.pipeline.kwsCuts, 0);
      expect(h.pipeline.bargeIns, 0);
      expect(h.scripted.cancels, 0);
      await h.dispose();
    });

    test('setting off: the spotter is never created', () async {
      final (h, kws, created) = await speaking(on: false);
      expect(created[0], 0);
      expect(kws, isNull);
      await h.dispose();
    });
  });

  test('reopenMic re-opens the microphone with the current echo-cancellation setting', () async {
    final h = await Harness.create();
    expect(h.fp.audio.micOpens, [true]);
    expect(h.pipeline.backendManagesAudio, isFalse);
    final first = h.mic;
    h.fp.audio.echoCancellation = false;
    await h.pipeline.reopenMic();
    expect(h.fp.audio.micOpens, [true, false]);
    expect(first.closed, isTrue);
    await h.pipeline.setMicMode(MicMode.muted);
    await h.pipeline.reopenMic(); // no mic open: stays closed
    expect(h.fp.audio.micOpens.length, 2);
    await h.dispose();
  });

  group('screenshot tiers', () {
    test('older screenshots go to 1/2 size, then to a description, in the live context', () async {
      final sizes = <(int, int)>[];
      final h = await Harness.create(
        images: (store) => ImageCompactor(
          // No user turns here; the raw-last-3-turns rule is tested in image_tiers_test.
          policy: const ImageTierPolicy(rawRecentTurns: 0),
          downscale: (png, w, h) async {
            sizes.add((w, h));
            return Uint8List.fromList(png.take(16).toList());
          },
          describe: (png, note) async => 'A terminal with ls output.',
          save: store.saveImage,
        ),
      );
      for (var i = 0; i < 9; i++) {
        final shot = await h.fp.screen.capture();
        await h.pipeline.attachScreenshot(shot, note: 'shot $i');
      }
      await h.pipeline.compactImages();
      final shots = h.conv.messages.where((m) => m.image != null).toList();
      expect(shots.map(imageTierOf), [
        ImageTier.described,
        ...List.filled(5, ImageTier.reduced),
        ...List.filled(3, ImageTier.full),
      ]);
      final r = h.scripted.replaced;
      expect(r.where((x) => x.$2 != null), hasLength(6), reason: 'images 1-6 were downscaled once each');
      final described = r.singleWhere((x) => x.$3 != null && x.$2 == null);
      expect(described.$1, 'img_1_v1', reason: 'the second swap targets the item the first one created');
      expect(described.$3, contains('A terminal with ls output.'));
      expect(sizes.first, (640, 360), reason: '1280x720 / 2');
      // Originals stay; the reduced copy is saved next to them.
      expect(File(shots.first.image!.path).existsSync(), isTrue);
      expect(File(shots[1].meta[ImageMeta.sentPath]! as String).existsSync(), isTrue);
      expect(shots.first.meta[ImageMeta.serverItem], startsWith('img_1_v'));
      expect(h.scripted.screenMemory, contains('A terminal with ls output.'));
      // The meter shows the savings.
      final p = h.context.parts();
      expect(p.imagesReduced, 5);
      expect(p.imagesDescribed, 1);
      expect(p.imagesSaved, greaterThan(5 * 100));
      await h.dispose();
    });

    test('a usage limit (429) pauses descriptions until it resets; downscaling goes on', () async {
      var asked = 0;
      final h = await Harness.create(
        images: (store) => ImageCompactor(
          policy: const ImageTierPolicy(rawRecentTurns: 0, fullCount: 1, reducedCount: 1),
          downscale: (png, w, h) async => Uint8List.fromList(png.take(16).toList()),
          describe: (png, note) async {
            asked++;
            throw Exception('Responses API error 429: The usage limit has been reached');
          },
          save: store.saveImage,
        ),
      );
      for (var i = 0; i < 5; i++) {
        final shot = await h.fp.screen.capture();
        await h.pipeline.attachScreenshot(shot, note: 'shot $i');
      }
      await h.pipeline.compactImages();
      await h.pipeline.compactImages();
      expect(asked, 1, reason: 'one refused request, then no more until the reset');
      expect(h.pipeline.imageCompactor!.describeLimit, isNotNull);
      final shots = h.conv.messages.where((m) => m.image != null).toList();
      expect(shots.map(imageTierOf), isNot(contains(ImageTier.described)));
      expect(shots.map(imageTierOf), contains(ImageTier.reduced));
      expect(imageTierOf(shots.last), ImageTier.full);
      await h.dispose();
    });
  });

  group('screenshots on speech', () {
    test('captured ~delay after speechStarted and sent with sendImage', () async {
      final h = await Harness.create();
      final t0 = DateTime.now();
      h.scripted.emit(const SpeechStarted());
      expect(h.pipeline.phase, AssistantPhase.userSpeaking);
      expect(h.fp.screen.captureTimes, isEmpty);
      await waitFor(() => h.scripted.images.isNotEmpty);
      final dt = h.fp.screen.captureTimes.single.difference(t0);
      expect(dt.inMilliseconds, greaterThanOrEqualTo(190));
      expect(dt.inMilliseconds, lessThan(1000));
      final user = ofKind(h.conv, MessageKind.user).single;
      expect(user.image, isNotNull);
      expect(user.image!.originalWidth, 2560);
      expect(h.scripted.images.single.$2, contains('1280x720'));
      expect(h.pipeline.screenshotsSent, 1);
      await h.dispose();
    });

    test('speech shorter than the delay captures immediately on stop', () async {
      final h = await Harness.create(options: const PipelineOptions(screenshotDelay: Duration(seconds: 5)));
      h.scripted.emit(const SpeechStarted());
      h.scripted.emit(const SpeechStopped());
      await waitFor(() => h.scripted.images.isNotEmpty, timeout: const Duration(seconds: 2));
      expect(h.fp.screen.captureTimes, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.fp.screen.captureTimes, hasLength(1), reason: 'timer cancelled');
      await h.dispose();
    });

    test('no screenshot when auto-screenshot is off', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false, screenshotDelay: Duration(milliseconds: 10)),
      );
      h.scripted.emit(const SpeechStarted());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      h.scripted.emit(const SpeechStopped());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.scripted.images, isEmpty);
      await h.dispose();
    });
  });

  group('user transcripts', () {
    test('partial transcript streams into the message, then finalizes', () async {
      final h = await Harness.create();
      h.scripted.emit(const SpeechStarted(itemId: 'item_1'));
      h.scripted.emit(const UserTranscriptDelta('open the ', itemId: 'item_1'));
      h.scripted.emit(const UserTranscriptDelta('file', itemId: 'item_1'));
      final user = ofKind(h.conv, MessageKind.user).single;
      expect(user.text, 'open the file');
      expect(user.streaming, isTrue);
      h.scripted.emit(const SpeechStopped(itemId: 'item_1'));
      h.scripted.emit(const UserTranscriptDone('Open the file.', itemId: 'item_1'));
      expect(user.text, 'Open the file.');
      expect(user.streaming, isFalse);
      await h.dispose();
    });

    test('late transcription after the reply started stays with its screenshot and audio', () async {
      final h = await Harness.create(options: const PipelineOptions(screenshotDelay: Duration(milliseconds: 20)));
      h.scripted.emit(const SpeechStarted(itemId: 'item_a'));
      await h.speak(300);
      await waitFor(() => h.scripted.images.isNotEmpty);
      h.scripted.emit(const SpeechStopped(itemId: 'item_a'));
      // The model answers (and calls a tool) before transcription completes.
      h.scripted.emit(const AssistantTranscriptDelta('Sure, '));
      h.scripted.emit(const ResponseDone());
      // Next turn starts before the first transcript arrives.
      h.scripted.emit(const SpeechStarted(itemId: 'item_b'));
      h.scripted.emit(const SpeechStopped(itemId: 'item_b'));
      h.scripted.emit(const UserTranscriptDone('second', itemId: 'item_b'));
      h.scripted.emit(const UserTranscriptDone('first', itemId: 'item_a'));
      final users = ofKind(h.conv, MessageKind.user).toList();
      expect(users, hasLength(2));
      expect(users[0].text, 'first');
      expect(users[0].image, isNotNull);
      await waitFor(() => users[0].audio != null);
      expect(users[1].text, 'second');
      expect(
        h.conv.messages.indexOf(users[0]),
        lessThan(h.conv.messages.indexWhere((m) => m.kind == MessageKind.assistant)),
      );
      await h.dispose();
    });

    test('a resumed turn id continues the same message with one screenshot', () async {
      final h = await Harness.create(options: const PipelineOptions(screenshotDelay: Duration(milliseconds: 10)));
      h.scripted.emit(const SpeechStarted(itemId: 'user_1'));
      await h.speak(200);
      await waitFor(() => h.scripted.images.isNotEmpty);
      h.scripted.emit(const SpeechStopped(itemId: 'user_1'));
      h.scripted.emit(const SpeechStarted(itemId: 'user_1'));
      await h.speak(200);
      h.scripted.emit(const SpeechStopped(itemId: 'user_1'));
      h.scripted.emit(const UserTranscriptDone('one long sentence', itemId: 'user_1'));
      final user = ofKind(h.conv, MessageKind.user).single;
      expect(user.text, 'one long sentence');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.scripted.images, hasLength(1));
      await waitFor(() => (user.audio?.durationMs ?? 0) >= 400);
      await h.dispose();
    });

    test('noSpeech closes an empty false start without a bubble', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      h.scripted.emit(const SpeechStarted(itemId: 'user_9'));
      h.scripted.emit(const SpeechStopped(itemId: 'user_9'));
      h.scripted.emit(const UserTranscriptDone('', itemId: 'user_9', noSpeech: true));
      expect(ofKind(h.conv, MessageKind.user), isEmpty);
      await h.dispose();
    });

    test('transcripts without ids still pair in order', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      h.scripted.emit(const SpeechStarted());
      h.scripted.emit(const SpeechStopped());
      h.scripted.emit(const SpeechStarted());
      h.scripted.emit(const SpeechStopped());
      h.scripted.emit(const UserTranscriptDone('a'));
      h.scripted.emit(const UserTranscriptDone('b'));
      expect(ofKind(h.conv, MessageKind.user).map((m) => m.text), ['a', 'b']);
      await h.dispose();
    });
  });

  group('mic', () {
    test('streams mic audio continuously; muted stops forwarding', () async {
      final h = await Harness.create();
      await h.speak(200, amplitude: 0);
      expect(h.scripted.audioBytes, 200 * 48);
      await h.pipeline.setMicMode(MicMode.muted);
      expect(h.fp.audio.mic!.closed, isTrue);
      await h.dispose();
    });

    test('push-to-talk forwards only while held and closes with silence', () async {
      final h = await Harness.create(
        options: const PipelineOptions(micMode: MicMode.pushToTalk, screenshotDelay: Duration(milliseconds: 200)),
      );
      await h.speak(100);
      expect(h.scripted.audioBytes, 0);
      h.pipeline.pttDown();
      await h.speak(100);
      expect(h.scripted.audioBytes, 100 * 48);
      h.pipeline.pttUp();
      expect(h.scripted.audioBytes, 100 * 48 + 800 * 48, reason: '800 ms trailing silence');
      await h.speak(100);
      expect(h.scripted.audioBytes, 900 * 48);
      await h.dispose();
    });

    test('switching to push-to-talk mid-utterance closes the turn', () async {
      final h = await Harness.create();
      h.scripted.emit(const SpeechStarted());
      expect(h.pipeline.phase, AssistantPhase.userSpeaking);
      final before = h.scripted.audioBytes;
      await h.pipeline.setMicMode(MicMode.pushToTalk);
      expect(h.pipeline.phase, isNot(AssistantPhase.userSpeaking), reason: 'no stuck "Hearing you…"');
      expect(h.scripted.audioBytes, before + 800 * 48, reason: 'closed with trailing silence');
      await h.dispose();
    });

    test('local VAD drives turns when the backend has no server VAD', () async {
      final h = await Harness.create(backend: () => ScriptedBackend(serverVad: false));
      await h.speak(600, amplitude: 30); // calibration on quiet room noise
      expect(ofKind(h.conv, MessageKind.user), isEmpty);
      await h.speak(400, amplitude: 8000);
      expect(h.pipeline.phase, AssistantPhase.userSpeaking);
      final user = ofKind(h.conv, MessageKind.user).single;
      await h.speak(1000, amplitude: 30);
      expect(h.pipeline.phase, AssistantPhase.thinking);
      await waitFor(() => user.audio != null, reason: 'utterance wav saved');
      expect(user.audio!.durationMs, greaterThan(300));
      await h.dispose();
    });
  });

  group('thinking feedback', () {
    test('orb shows thinking on end of speech; the earcon is off by default', () async {
      final h = await Harness.create();
      h.scripted.emit(const SpeechStarted(itemId: 'u1'));
      h.scripted.emit(const SpeechStopped(itemId: 'u1'));
      expect(h.pipeline.phase, AssistantPhase.thinking, reason: 'before any server event');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.pipeline.earconsPlayed, 0);
      expect(h.fp.audio.extraPlayers, isEmpty);
      await h.dispose();
    });

    test('earcon plays on its own player while waiting, not when the reply already started', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false, thinkingEarcon: true, localBargeIn: false),
      );
      // Main player opened by the pipeline first.
      h.scripted.emit(const SpeechStarted(itemId: 'u1'));
      h.scripted.emit(const SpeechStopped(itemId: 'u1'));
      await waitFor(() => h.pipeline.earconsPlayed == 1);
      final chime = h.fp.audio.extraPlayers.single;
      expect(chime.written.length, thinkingEarconPcm().length);
      expect(h.player.written.length, 0, reason: 'never mixed into assistant audio');
      expect(h.pipeline.phase, AssistantPhase.thinking, reason: 'the chime is not assistant speech');

      // Reply starts immediately: no chime.
      h.scripted.emit(const SpeechStarted(itemId: 'u2'));
      h.scripted.emit(const SpeechStopped(itemId: 'u2'));
      h.scripted.emit(const AssistantTranscriptDelta('Sure.'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.pipeline.earconsPlayed, 1);
      await h.dispose();
    });

    test('earcon is quiet and short', () {
      final pcm = thinkingEarconPcm();
      expect(pcm.length / kVoiceBytesPerSecond, lessThan(0.25));
      final bd = ByteData.sublistView(pcm);
      var peak = 0;
      for (var i = 0; i + 1 < pcm.length; i += 2) {
        peak = math.max(peak, bd.getInt16(i, Endian.little).abs());
      }
      expect(peak, inInclusiveRange(1000, 32767 ~/ 10));
    });
  });

  test('streaming transcript deltas are coalesced (at most ~15 notifications a second)', () async {
    final h = await Harness.create();
    final b = h.scripted;
    var notes = 0;
    h.pipeline.addListener(() => notes++);
    b.emit(const AssistantTranscriptDelta('Hello'));
    // The phase changed (speaking): heard at once.
    expect(notes, greaterThanOrEqualTo(1));
    final first = notes;
    for (var i = 0; i < 30; i++) {
      b.emit(AssistantTranscriptDelta(' w$i'));
    }
    expect(notes, first, reason: 'deltas inside the interval are held');
    await Future<void>.delayed(h.pipeline.transcriptNotifyInterval * 2);
    expect(notes, first + 1, reason: 'one notification for the burst');
    expect(ofKind(h.conv, MessageKind.assistant).single.text, endsWith(' w29'));
    // Any other change notifies at once and takes the pending delta along.
    b.emit(const AssistantTranscriptDelta(' more'));
    b.emit(const ResponseDone());
    final n = notes;
    await Future<void>.delayed(h.pipeline.transcriptNotifyInterval * 2);
    expect(notes, n, reason: 'no trailing notification after an immediate one');
    await h.dispose();
  });

  group('assistant audible', () {
    Future<List<String>> captureLogs(Future<void> Function() body) async {
      final logs = <String>[];
      final prev = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        await body();
      } finally {
        debugPrint = prev;
      }
      return logs;
    }

    test('a turn that cuts Woi off logs audible=y (snapshot before the cut)', () async {
      final h = await Harness.create();
      final b = h.scripted;
      final logs = await captureLogs(() async {
        b.emit(const AssistantTranscriptDelta('Hello there, '));
        b.emit(AssistantAudioDelta(pcm(200, amplitude: 1000)));
        expect(h.player.isPlaying, isTrue);
        b.emit(const SpeechStarted(itemId: 'u1'));
        expect(h.player.isPlaying, isFalse, reason: 'barge-in stopped the player');
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('Wait a second.', itemId: 'u1'));
        await Future<void>.delayed(Duration.zero);
      });
      final line = logs.firstWhere((l) => l.startsWith('user turn:'));
      expect(line, contains('audible=y'));
      await h.dispose();
    });

    test('just after playback is cut the echo tail still counts (audible=t), later not', () async {
      final h = await Harness.create();
      final b = h.scripted;
      final logs = await captureLogs(() async {
        b.emit(const AssistantTranscriptDelta('Hello there, '));
        b.emit(AssistantAudioDelta(pcm(200, amplitude: 1000)));
        b.emit(const SpeechStarted(itemId: 'u1'));
        b.emit(const SpeechStopped(itemId: 'u1'));
        // Inside the ~360 ms tail after the cut.
        b.emit(const SpeechStarted(itemId: 'u2'));
        b.emit(const SpeechStopped(itemId: 'u2'));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        b.emit(const SpeechStarted(itemId: 'u3'));
        b.emit(const SpeechStopped(itemId: 'u3'));
        for (final id in ['u1', 'u2', 'u3']) {
          b.emit(UserTranscriptDone('Turn $id here.', itemId: id));
        }
        await Future<void>.delayed(Duration.zero);
      });
      final turns = logs.where((l) => l.startsWith('user turn:')).toList();
      expect(turns, hasLength(3));
      expect(turns[0], contains('audible=y'));
      expect(turns[1], contains('audible=t'));
      expect(turns[2], contains('audible=n'));
      await h.dispose();
    });
  });

  group('barge-in', () {
    test('user speech stops playback, cancels the response and drops late deltas', () async {
      final h = await Harness.create();
      final b = h.scripted;
      b.emit(const AssistantTranscriptDelta('Hello there, '));
      b.emit(AssistantAudioDelta(pcm(200, amplitude: 1000)));
      expect(h.player.isPlaying, isTrue);
      expect(h.pipeline.phase, AssistantPhase.speaking);
      final stopsBefore = h.player.stops;

      b.emit(const SpeechStarted());
      expect(h.player.stops, stopsBefore + 1);
      expect(b.cancels, 1);
      expect(h.pipeline.bargeIns, 1);
      final reply = ofKind(h.conv, MessageKind.assistant).single;
      expect(reply.interrupted, isTrue);
      expect(reply.streaming, isFalse);

      // Late events from the cancelled response are ignored.
      final written = h.player.written.length;
      b.emit(const AssistantTranscriptDelta('more words'));
      b.emit(AssistantAudioDelta(pcm(100, amplitude: 1000)));
      expect(h.player.written.length, written);
      expect(reply.text, 'Hello there, ');
      b.emit(const ResponseDone(cancelled: true));

      // The next response is held until the interruption's transcript shows
      // it was not just "stop", then accepted again.
      b.emit(const SpeechStopped());
      b.emit(const AssistantTranscriptDelta('Sure.'));
      expect(ofKind(h.conv, MessageKind.assistant).length, 1, reason: 'held');
      b.emit(const UserTranscriptDone('Tell me about Mars instead.'));
      b.emit(const ResponseDone());
      expect(ofKind(h.conv, MessageKind.assistant).last.text, 'Sure.');
      await h.dispose();
    });

    test('local mic onset pauses playback; the server confirms the barge-in', () async {
      // The guard's clock stands still: no real-time dependence.
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      h.pipeline.echoGate = true; // off by default; covered here
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time '));
      // Assistant audio plays; the mic hears only its faint echo.
      b.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
      for (var i = 0; i < 40; i++) {
        mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      expect(h.pipeline.localOnsets, 0, reason: 'echo is not an onset');
      expect(b.audioSent.every((c) => c.every((v) => v == 0)), isTrue, reason: 'the echo never reaches the server');
      final stops = h.player.stops;
      final sent = b.audioSent.length;
      // The user talks over it.
      for (var i = 0; i < 10; i++) {
        mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
      }
      expect(h.pipeline.localOnsets, 1);
      expect(h.player.stops, stops + 1, reason: 'paused at once');
      expect(b.cancels, 0, reason: 'not cut before the server confirms');
      expect(b.audioSent.skip(sent).any((c) => c.any((v) => v != 0)), isTrue, reason: 'gate open: the user reaches the server');
      // Server VAD confirms: that is the barge-in.
      b.emit(const SpeechStarted(itemId: 'u1'));
      expect(h.pipeline.bargeIns, 1);
      expect(b.cancels, 1);
      expect(b.holds, [true], reason: 'reply held until we know it is not "stop"');
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
      await h.dispose();
    });

    test('a filler transcript after a (weak) local onset while Woi is audible is echo: Woi resumes', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      // Echo-level onset peak (below the local-cut level); a strong one
      // stays stopped (see 'local hold').
      h.pipeline.onsetCutRms = double.infinity;
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time there was a lighthouse keeper. '));
      b.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
      for (var i = 0; i < 40; i++) {
        mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      for (var i = 0; i < 10; i++) {
        mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
      }
      expect(h.pipeline.localOnsets, 1);
      b.emit(const SpeechStarted(itemId: 'u1'));
      expect(h.pipeline.bargeIns, 1);
      final written = h.player.written.length;
      b.emit(const SpeechStopped(itemId: 'u1'));
      b.emit(const UserTranscriptDone('啊', itemId: 'u1'));
      expect(h.pipeline.shortEchoDrops, 1);
      expect(h.pipeline.echoTurnsDropped, 1);
      expect(ofKind(h.conv, MessageKind.user), isEmpty);
      expect(h.player.written.length, greaterThan(written), reason: 'the cut-off reply resumes');
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
      await h.dispose();
    });

    test('a stop phrase after a local onset while Woi is audible still stops', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time there was a lighthouse keeper. '));
      b.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
      for (var i = 0; i < 40; i++) {
        mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      for (var i = 0; i < 10; i++) {
        mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
      }
      b.emit(const SpeechStarted(itemId: 'u1'));
      b.emit(const SpeechStopped(itemId: 'u1'));
      b.emit(const UserTranscriptDone('停', itemId: 'u1'));
      expect(h.pipeline.shortEchoDrops, 0);
      expect(h.pipeline.echoTurnsDropped, 0);
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
      await h.dispose();
    });

    test('an onset the server does not confirm resumes playback where it paused', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      h.pipeline.onsetHoldMinRms = double.infinity; // a weak onset: no local hold
      h.pipeline.onsetCutRms = double.infinity; // ... and no local cut
      h.pipeline.onsetShortCutRmsValue = double.infinity;
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time '));
      b.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
      for (var i = 0; i < 40; i++) {
        mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
      }
      for (var i = 0; i < 10; i++) {
        mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
      }
      expect(h.pipeline.localOnsets, 1);
      final written = h.player.written.length;
      // More of the reply arrives while paused: kept, not played yet.
      b.emit(AssistantAudioDelta(voice(200, amplitude: 8000, f0: 140)));
      expect(h.player.written.length, written);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(h.pipeline.onsetsResumed, 1);
      expect(b.cancels, 0);
      expect(h.pipeline.bargeIns, 0);
      final resumed = h.player.written.length - written;
      // Nothing was heard yet (the guard's clock stands still): the 4 s
      // queued plus the 0.2 s that arrived while paused.
      expect(resumed, kVoiceBytesPerSecond * 42 ~/ 10);
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
      await h.dispose();
    });

    group('local hold', () {
      /// A strong onset; [cut] false: its peak is below the local-cut
      /// thresholds (held, then resumed).
      Future<Harness> strongOnset({bool cut = false, bool fast = true}) async {
        final h = await Harness.create(
          options: const PipelineOptions(autoScreenshot: false),
          echoGuard: EchoGuard(nowUs: () => 0),
        );
        h.pipeline.onsetHoldExtra = const Duration(milliseconds: 600);
        if (!cut) h.pipeline.onsetCutRms = double.infinity;
        if (!cut || !fast) h.pipeline.onsetShortCutRmsValue = double.infinity;
        final b = h.scripted;
        final mic = h.fp.audio.mic!;
        b.emit(const AssistantTranscriptDelta('Once upon a time there was a lighthouse keeper. '));
        b.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
        for (var i = 0; i < 40; i++) {
          mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
        }
        for (var i = 0; i < 10; i++) {
          mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
        }
        expect(h.pipeline.localOnsets, 1);
        return h;
      }

      test('a strong onset stays paused past the confirm window; a late speech start cuts', () async {
        final h = await strongOnset();
        final b = h.scripted;
        final written = h.player.written.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(h.pipeline.onsetsHeld, 1);
        expect(h.pipeline.onsetsResumed, 0, reason: 'held, not resumed');
        expect(h.player.written.length, written, reason: 'still silent');
        // The server's (deferred) speech start arrives late: still a barge-in.
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        expect(h.pipeline.bargeIns, 1);
        expect(b.cancels, 1);
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(h.pipeline.onsetsResumed, 0);
        await h.dispose();
      });

      test('a held onset with no speech start resumes after the hold', () async {
        final h = await strongOnset();
        final b = h.scripted;
        final written = h.player.written.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(h.pipeline.onsetsResumed, 0);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(h.pipeline.onsetsHeld, 1);
        expect(h.pipeline.onsetsResumed, 1);
        expect(b.cancels, 0);
        expect(h.player.written.length - written, kVoiceBytesPerSecond * 4, reason: 'resumes where it paused');
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
        await h.dispose();
      });

      test('a held onset whose late turn is an echo transcript resumes the reply', () async {
        final h = await strongOnset();
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        expect(h.pipeline.bargeIns, 1);
        final written = h.player.written.length;
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('啊', itemId: 'u1'));
        expect(h.pipeline.echoTurnsDropped, 1);
        expect(ofKind(h.conv, MessageKind.user), isEmpty);
        expect(h.player.written.length, greaterThan(written), reason: 'the cut-off reply resumes');
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
        await h.dispose();
      });

      test('a short word (strong peak, still voiced at firing) is cut after the tail window: stopped, never resumed', () async {
        final h = await strongOnset(cut: true);
        final b = h.scripted;
        expect(h.pipeline.onsetCutRms, TurnPipeline.onsetCutMinRms);
        final written = h.player.written.length;
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(h.pipeline.localCuts, 1);
        expect(h.pipeline.onsetsHeld, 0, reason: 'cut without the extra hold');
        expect(h.pipeline.bargeIns, 1);
        expect(b.cancels, 1, reason: 'reply cancelled / truncated like a barge-in');
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        expect(h.pipeline.phase, AssistantPhase.listening);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(h.pipeline.onsetsResumed, 0);
        expect(h.player.written.length, written, reason: 'Woi stays silent');
        expect(b.texts, isEmpty, reason: 'no response created');
        await h.dispose();
      });

      test('echo onset (strong peak, not voiced at firing) with a silent pause: held, then resumed', () async {
        // e28b: echo peak 0.062 with excess 0.000 at the firing frame, the
        // mic silent once the tail passed. Peak alone never cuts.
        final h = await strongOnset(cut: true, fast: false);
        expect(h.pipeline.onsetCutRms, TurnPipeline.onsetCutMinRms);
        final written = h.player.written.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(h.pipeline.onsetsHeld, 1);
        expect(h.pipeline.localCuts, 0);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(h.pipeline.localCuts, 0);
        expect(h.pipeline.onsetsResumed, 1);
        expect(h.scripted.cancels, 0);
        expect(h.player.written.length - written, kVoiceBytesPerSecond * 4, reason: 'resumes where it paused');
        await h.dispose();
      });

      test('the user keeps talking during the pause: cut after the echo tail', () async {
        final h = await strongOnset(cut: true, fast: false);
        final mic = h.fp.audio.mic!;
        final sw = Stopwatch()..start();
        for (var i = 0; sw.elapsedMilliseconds < 800; i++) {
          mic.push(voice(20, amplitude: 6000, f0: 220, phase0: i * 480));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(h.pipeline.localCuts, 1);
        expect(h.pipeline.onsetsHeld, 0, reason: 'decided at tail + window, before any hold');
        expect(h.scripted.cancels, 1);
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(h.pipeline.onsetsResumed, 0);
        await h.dispose();
      });

      test('short stop word (quiet pause, not a short-word cut) + server transcript "stop": cut, stays stopped', () async {
        final h = await strongOnset(cut: true, fast: false);
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(h.pipeline.localCuts, 0);
        expect(h.pipeline.onsetsHeld, 1);
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        expect(h.pipeline.bargeIns, 1);
        expect(b.cancels, 1);
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('Stop.', itemId: 'u1'));
        b.emit(const ResponseDone(cancelled: true));
        final written = h.player.written.length;
        b.emit(const AssistantTranscriptDelta('Okay.'));
        b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
        b.emit(const ResponseDone());
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(h.pipeline.stopsHandled, 1);
        expect(h.pipeline.onsetsResumed, 0);
        expect(h.player.written.length, written, reason: 'stays stopped');
        expect(ofKind(h.conv, MessageKind.assistant).first.interrupted, isTrue);
        await h.dispose();
      });

      test('after a local cut, a late echo transcript keeps Woi stopped (no reply, no resume)', () async {
        final h = await strongOnset(cut: true);
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(h.pipeline.localCuts, 1);
        b.emit(const ResponseDone(cancelled: true));
        final written = h.player.written.length;
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const AssistantTranscriptDelta('Upon a time? '));
        b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
        b.emit(const UserTranscriptDone('Once upon a time.', itemId: 'u1'));
        b.emit(const ResponseDone());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(ofKind(h.conv, MessageKind.user), isEmpty, reason: 'echo turn dropped');
        expect(h.player.written.length, written, reason: 'no reply and the cut reply is not resumed');
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        expect(h.pipeline.onsetsResumed, 0);
        await h.dispose();
      });

      test('a strong onset confirmed by the server whose transcript is filler stays stopped', () async {
        final h = await strongOnset(cut: true);
        final b = h.scripted;
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        expect(h.pipeline.bargeIns, 1);
        final written = h.player.written.length;
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('어', itemId: 'u1'));
        expect(h.pipeline.echoTurnsDropped, 1);
        expect(ofKind(h.conv, MessageKind.user), isEmpty);
        expect(h.player.written.length, written, reason: 'the cut reply is not resumed');
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        await h.dispose();
      });

      test('after a local cut, a late "stop" transcript stays stopped', () async {
        final h = await strongOnset(cut: true);
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        b.emit(const ResponseDone(cancelled: true));
        final written = h.player.written.length;
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('Stop.', itemId: 'u1'));
        b.emit(const AssistantTranscriptDelta('Okay.'));
        b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
        b.emit(const ResponseDone());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(h.pipeline.stopsHandled, 1);
        expect(h.player.written.length, written);
        await h.dispose();
      });

      test('after a local cut, a late real request is answered', () async {
        final h = await strongOnset(cut: true);
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        b.emit(const ResponseDone(cancelled: true));
        final written = h.player.written.length;
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('What time is it in Tokyo?', itemId: 'u1'));
        b.emit(const AssistantTranscriptDelta('It is nine in the morning.'));
        b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
        b.emit(const AssistantTranscriptDone('It is nine in the morning.'));
        b.emit(const ResponseDone());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(ofKind(h.conv, MessageKind.user).single.text, contains('Tokyo'));
        expect(ofKind(h.conv, MessageKind.assistant).last.text, 'It is nine in the morning.');
        expect(h.player.written.length, greaterThan(written), reason: 'the answer plays');
        await h.dispose();
      });

      test('a weak onset is not held', () async {
        final h = await Harness.create(
          options: const PipelineOptions(autoScreenshot: false),
          echoGuard: EchoGuard(nowUs: () => 0),
        );
        h.pipeline.onsetHoldMinRms = 1.0;
        h.pipeline.onsetCutRms = double.infinity;
        h.pipeline.onsetShortCutRmsValue = double.infinity;
        final mic = h.fp.audio.mic!;
        h.scripted.emit(const AssistantTranscriptDelta('Once upon a time '));
        h.scripted.emit(AssistantAudioDelta(voice(4000, amplitude: 8000, f0: 140)));
        for (var i = 0; i < 40; i++) {
          mic.push(voice(20, amplitude: 300, f0: 140, phase0: i * 480));
        }
        for (var i = 0; i < 10; i++) {
          mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
        }
        expect(h.pipeline.localOnsets, 1);
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        expect(h.pipeline.onsetsHeld, 0);
        expect(h.pipeline.onsetsResumed, 1);
        await h.dispose();
      });

      test('a quiet pause with no excess left at firing resumes right after the measurement, no hold', () async {
        final h = await strongOnset(cut: true, fast: false);
        h.pipeline.onsetShortCutFireRmsValue = 1.0; // the firing excess counts as "below"
        final written = h.player.written.length;
        await Future<void>.delayed(const Duration(milliseconds: 820));
        expect(h.pipeline.onsetsQuietResumed, 1);
        expect(h.pipeline.onsetsResumed, 1, reason: 'resumed at ~700 ms, before the 900 ms confirm window');
        expect(h.pipeline.onsetsHeld, 0);
        expect(h.pipeline.localCuts, 0);
        expect(h.player.written.length - written, kVoiceBytesPerSecond * 4, reason: 'resumes where it paused');
        await h.dispose();
      });

      test('after a quiet resume, a late server speech start (< 1.5 s after the onset) still cuts', () async {
        final h = await strongOnset(cut: true, fast: false);
        h.pipeline.onsetShortCutFireRmsValue = 1.0;
        await Future<void>.delayed(const Duration(milliseconds: 820));
        expect(h.pipeline.onsetsQuietResumed, 1);
        h.scripted.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        expect(h.pipeline.bargeIns, 1);
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
        await h.dispose();
      });

      test('an ambiguous pause (voiced, but below the cut rule) is still held for the server', () async {
        final h = await strongOnset(cut: true, fast: false);
        h.pipeline.onsetShortCutFireRmsValue = 1.0;
        final mic = h.fp.audio.mic!;
        await Future<void>.delayed(const Duration(milliseconds: 520));
        for (var i = 0; i < 2; i++) {
          mic.push(voice(20, amplitude: 6000, f0: 220, phase0: i * 480)); // 40 ms < 80 ms
        }
        await Future<void>.delayed(const Duration(milliseconds: 580));
        expect(h.pipeline.localCuts, 0);
        expect(h.pipeline.onsetsQuietResumed, 0);
        expect(h.pipeline.onsetsHeld, 1);
        expect(h.pipeline.onsetsResumed, 0, reason: 'held');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(h.pipeline.onsetsResumed, 1);
        await h.dispose();
      });

      group('WOI_QA_IGNORE_SERVER_SPEECH', () {
        test('is off unless the env var is set', () {
          expect(TurnPipeline.qaIgnoreServerSpeechEnv, Platform.environment['WOI_QA_IGNORE_SERVER_SPEECH'] == '1');
        });

        test('a server speech start in the pause waits for the local rule; after a local cut the turn is processed', () async {
          final h = await strongOnset(cut: true);
          h.pipeline.qaIgnoreServerSpeech = true;
          final b = h.scripted;
          b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
          expect(h.pipeline.bargeIns, 0, reason: 'the server does not decide');
          expect(h.pipeline.qaServerStartsHeld, 1);
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          expect(h.pipeline.localCuts, 1);
          expect(b.accepts, 1, reason: 'the held turn is replayed and accepted');
          b.emit(const SpeechStopped(itemId: 'u1'));
          b.emit(const UserTranscriptDone('What time is it in Tokyo?', itemId: 'u1'));
          b.emit(const ResponseDone(cancelled: true));
          b.emit(const AssistantTranscriptDelta('It is nine.'));
          b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
          b.emit(const ResponseDone());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(ofKind(h.conv, MessageKind.user).single.text, contains('Tokyo'));
          expect(ofKind(h.conv, MessageKind.assistant).last.text, 'It is nine.');
          await h.dispose();
        });

        test('a server "stop" in a quiet echo pause is ignored: resumed, turn dropped', () async {
          final h = await strongOnset(cut: true, fast: false);
          h.pipeline.qaIgnoreServerSpeech = true;
          h.pipeline.onsetShortCutFireRmsValue = 1.0;
          final b = h.scripted;
          b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
          b.emit(const SpeechStopped(itemId: 'u1'));
          expect(h.pipeline.bargeIns, 0);
          await Future<void>.delayed(const Duration(milliseconds: 820));
          expect(h.pipeline.onsetsResumed, 1);
          expect(b.echoDrops.single.$1, 'u1');
          b.emit(const UserTranscriptDone('Stop.', itemId: 'u1'));
          expect(h.pipeline.stopsHandled, 0);
          expect(ofKind(h.conv, MessageKind.user), isEmpty);
          expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
          await h.dispose();
        });
      });
    });

    test('half-duplex (Android media route): echo goes out as silence, an onset reopens the mic', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false, halfDuplexWhileSpeaking: true),
      );
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      bool silent(Uint8List c) => c.every((x) => x == 0);
      b.emit(const AssistantTranscriptDelta('Once upon a time '));
      b.sentAudio.clear();
      for (var i = 0; i < 40; i++) {
        b.emit(AssistantAudioDelta(voice(20, amplitude: 8000, f0: 140, phase0: i * 480)));
        mic.push(pcm(20, amplitude: 300));
      }
      expect(h.pipeline.localOnsets, 0);
      expect(b.sentAudio, hasLength(40));
      expect(b.sentAudio.every(silent), isTrue, reason: 'echo never reaches the server');
      b.sentAudio.clear();
      for (var i = 0; i < 10; i++) {
        mic.push(voice(20, amplitude: 9000, f0: 230, phase0: i * 480));
      }
      expect(h.pipeline.localOnsets, 1);
      // The reference-aware detector soft-pauses Woi; the server (now hearing
      // the user) confirms the turn.
      final written = h.player.written.length;
      b.emit(AssistantAudioDelta(voice(100, amplitude: 8000, f0: 140)));
      expect(h.player.written.length, written, reason: "paused: new reply audio is held");
      // Lead-in chunks plus the onset chunk and the rest are real audio.
      final real = b.sentAudio.where((c) => !silent(c)).length;
      expect(real, greaterThanOrEqualTo(9), reason: 'the user is heard, including the lead-in');
      await h.dispose();
    });

    test('half-duplex off (default): the mic goes to the server while Woi speaks', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time '));
      b.sentAudio.clear();
      for (var i = 0; i < 5; i++) {
        b.emit(AssistantAudioDelta(pcm(20, amplitude: 8000)));
        mic.push(pcm(20, amplitude: 300));
      }
      expect(b.sentAudio.where((c) => c.any((x) => x != 0)), hasLength(5));
      expect(h.pipeline.gatedChunks, 0);
      await h.dispose();
    });

    test('"stop" while speaking: stopped locally, its spoken answer is dropped (no bubble)', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      b.emit(const AssistantTranscriptDelta('A long story '));
      b.emit(AssistantAudioDelta(pcm(500, amplitude: 1000)));
      b.emit(const SpeechStarted(itemId: 'u1'));
      expect(b.cancels, 1);
      b.emit(const ResponseDone(cancelled: true));
      b.emit(const SpeechStopped(itemId: 'u1'));
      // Server answers before the transcript is in: held.
      b.emit(const AssistantTranscriptDelta('Okay, stopping.'));
      b.emit(AssistantAudioDelta(pcm(100, amplitude: 1000)));
      final written = h.player.written.length;
      b.emit(const UserTranscriptDone('Stop.', itemId: 'u1'));
      expect(h.pipeline.stopsHandled, 1);
      expect(b.stopDrops, 1);
      b.emit(const AssistantTranscriptDone('Okay, stopping.'));
      b.emit(const ResponseDone());
      expect(h.player.written.length, written, reason: 'ack never played');
      final replies = ofKind(h.conv, MessageKind.assistant);
      expect(replies.map((m) => m.text), ['A long story '], reason: 'no stray bubble');
      expect(b.texts, isEmpty, reason: 'nothing delegated or sent');
      await h.dispose();
    });

    test('idle "never mind" drops the reply; a normal short turn still gets one', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      b.emit(const SpeechStarted(itemId: 'u1'));
      b.emit(const SpeechStopped(itemId: 'u1'));
      b.emit(const AssistantTranscriptDelta('Alright.'));
      b.emit(const UserTranscriptDone('Never mind.', itemId: 'u1'));
      b.emit(const ResponseDone());
      expect(ofKind(h.conv, MessageKind.assistant), isEmpty);
      expect(b.stopDrops, 1);

      b.emit(const SpeechStarted(itemId: 'u2'));
      b.emit(const SpeechStopped(itemId: 'u2'));
      b.emit(const AssistantTranscriptDelta('Hi!'));
      b.emit(AssistantAudioDelta(pcm(100, amplitude: 1000)));
      b.emit(const UserTranscriptDone('Hello.', itemId: 'u2'));
      b.emit(const ResponseDone());
      expect(ofKind(h.conv, MessageKind.assistant).single.text, 'Hi!');
      expect(h.player.written.length, greaterThan(0));
      await h.dispose();
    });

    test('held reply is released after a timeout when no transcript arrives', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      b.emit(const SpeechStarted(itemId: 'u1'));
      b.emit(const SpeechStopped(itemId: 'u1'));
      b.emit(const AssistantTranscriptDelta('Hi!'));
      expect(ofKind(h.conv, MessageKind.assistant), isEmpty);
      await waitFor(() => ofKind(h.conv, MessageKind.assistant).isNotEmpty, timeout: const Duration(seconds: 3));
      await h.dispose();
    });

    test('typed "cancel" is handled locally and never sent', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      b.emit(AssistantAudioDelta(pcm(300, amplitude: 1000)));
      h.pipeline.sendText('cancel');
      expect(b.texts, isEmpty);
      expect(h.player.isPlaying, isFalse);
      expect(h.pipeline.stopsHandled, 1);
      await h.dispose();
    });

    test('interrupt() (stop button) behaves like barge-in', () async {
      final h = await Harness.create();
      h.scripted.emit(AssistantAudioDelta(pcm(100, amplitude: 1000)));
      h.pipeline.interrupt();
      expect(h.scripted.cancels, 1);
      expect(h.player.isPlaying, isFalse);
      await h.dispose();
    });

    test('no cancel when nothing is playing', () async {
      final h = await Harness.create();
      h.scripted.emit(const SpeechStarted());
      expect(h.scripted.cancels, 0);
      expect(h.pipeline.bargeIns, 0);
      await h.dispose();
    });
  });

  group('echo turns (transcript guard)', () {
    /// Woi is replying (audible); the server hears its echo as a user turn
    /// and replies to it with a tool call.
    Future<Harness> echoTurn(String heard, {String said = 'Pointer moved. Now I will open the settings for you.'}) async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      final b = h.scripted;
      b.emit(AssistantTranscriptDelta(said));
      b.emit(AssistantAudioDelta(voice(3000, amplitude: 8000, f0: 140)));
      b.emit(const SpeechStarted(itemId: 'u1'));
      expect(h.pipeline.bargeIns, 1);
      b.emit(const SpeechStopped(itemId: 'u1'));
      b.emit(const ResponseDone(cancelled: true)); // the cut reply
      // The server's reply to the "user" turn: held.
      b.emit(const AssistantTranscriptDelta('Typing it. '));
      b.emit(AssistantAudioDelta(voice(400, amplitude: 8000, f0: 150)));
      b.emit(const ToolCall('c1', 'type_text', '{"text":"hey"}'));
      b.emit(const ResponseDone());
      expect(ofKind(h.conv, MessageKind.tool), isEmpty, reason: 'no action before the transcript decides');
      b.emit(UserTranscriptDone(heard, itemId: 'u1'));
      return h;
    }

    test('Woi heard back ("Boiner moot." for "Pointer moved."): no reply, no tool, no bubble; the reply plays on', () async {
      final h = await echoTurn('Boiner moot.');
      final b = h.scripted;
      expect(h.pipeline.echoTurnsDropped, 1);
      expect(b.echoDrops.single.$1, 'u1');
      expect(b.echoDrops.single.$2, ['c1']);
      expect(ofKind(h.conv, MessageKind.user), isEmpty);
      expect(ofKind(h.conv, MessageKind.tool), isEmpty);
      expect(h.fp.input.log, isEmpty);
      final replies = ofKind(h.conv, MessageKind.assistant);
      expect(replies.map((m) => m.text), ['Pointer moved. Now I will open the settings for you.']);
      expect(replies.single.interrupted, isFalse);
      // The unheard rest of the cut reply (all 3 s: the guard clock stands
      // still) is played again; the reply to the echo never is.
      expect(h.player.written.length, kVoiceBytesPerSecond * 6);
      await h.dispose();
    });

    test('the user talking over Woi: the held reply and its tool call go ahead', () async {
      final h = await echoTurn('Open the browser please.');
      expect(h.pipeline.echoTurnsDropped, 0);
      expect(h.scripted.echoDrops, isEmpty);
      expect(ofKind(h.conv, MessageKind.user).single.text, 'Open the browser please.');
      await waitFor(() => h.scripted.toolResults.isNotEmpty);
      expect(h.fp.input.log, ['type hey']);
      expect(ofKind(h.conv, MessageKind.assistant).last.text, 'Typing it. ');
      await h.dispose();
    });

    group('deferred server turns (the server did not cut Woi off)', () {
      Future<Harness> deferredTurn() async {
        final h = await Harness.create(
          options: const PipelineOptions(autoScreenshot: false),
          echoGuard: EchoGuard(nowUs: () => 0),
        );
        h.pipeline.deferWindow = const Duration(milliseconds: 200);
        final b = h.scripted;
        b.emit(const AssistantTranscriptDelta('Pointer moved. Now I will open the settings for you.'));
        b.emit(AssistantAudioDelta(voice(3000, amplitude: 8000, f0: 140)));
        b.emit(const SpeechStarted(itemId: 'u1', deferred: true));
        return h;
      }

      test('echo transcript within the window: dropped, Woi never cut and talks on', () async {
        final h = await deferredTurn();
        final b = h.scripted;
        expect(h.pipeline.bargeIns, 0);
        final written = h.player.written.length;
        b.emit(AssistantAudioDelta(voice(200, amplitude: 8000, f0: 140)));
        expect(h.player.written.length, greaterThan(written), reason: 'the reply keeps playing');
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('Boiner moot.', itemId: 'u1'));
        expect(h.pipeline.deferredEchoDrops, 1);
        expect(b.echoDrops.single.$1, 'u1');
        expect(ofKind(h.conv, MessageKind.user), isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(h.pipeline.bargeIns, 0);
        expect(b.accepts, 0);
        await h.dispose();
      });

      test('no transcript in time and no local onset: Woi plays on; an empty transcript drops it unanswered', () async {
        final h = await deferredTurn();
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(h.pipeline.bargeIns, 0, reason: 'no evidence it is the user');
        expect(b.accepts, 0);
        expect(b.cancels, 0);
        final written = h.player.written.length;
        b.emit(AssistantAudioDelta(voice(200, amplitude: 8000, f0: 140)));
        expect(h.player.written.length, greaterThan(written), reason: 'the reply keeps playing');
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('', itemId: 'u1'));
        expect(h.pipeline.deferredEchoDrops, 1);
        expect(b.echoDrops.single.$1, 'u1', reason: 'the server item goes; nothing answers it');
        expect(b.accepts, 0);
        expect(h.pipeline.bargeIns, 0);
        expect(ofKind(h.conv, MessageKind.user), isEmpty);
        expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isFalse);
        await h.dispose();
      });

      test('after the timeout a real (non-echo) transcript still interrupts', () async {
        final h = await deferredTurn();
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(h.pipeline.bargeIns, 0);
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('What is the weather in Paris tomorrow?', itemId: 'u1'));
        expect(h.pipeline.deferredInterrupts, 1);
        expect(h.pipeline.bargeIns, 1);
        expect(b.accepts, 1);
        expect(ofKind(h.conv, MessageKind.user).single.text, 'What is the weather in Paris tomorrow?');
        await h.dispose();
      });

      test('after the timeout an echo transcript drops it, a stop phrase stops', () async {
        final h = await deferredTurn();
        final b = h.scripted;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        b.emit(const SpeechStopped(itemId: 'u1'));
        b.emit(const UserTranscriptDone('Pointer moved. Now I', itemId: 'u1'));
        expect(h.pipeline.deferredEchoDrops, 1);
        expect(h.pipeline.bargeIns, 0);
        expect(b.accepts, 0);
        await h.dispose();
        final h2 = await deferredTurn();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        h2.scripted.emit(const UserTranscriptDelta('Stop.', itemId: 'u1'));
        expect(h2.pipeline.deferredInterrupts, 1);
        expect(h2.pipeline.bargeIns, 1);
        await h2.dispose();
      });
    });

    test('a quick answer right after Woi finished is not echo', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      final b = h.scripted;
      b.emit(const AssistantTranscriptDelta('Is that right?'));
      b.emit(AssistantAudioDelta(voice(300, amplitude: 8000, f0: 140)));
      b.emit(const ResponseDone());
      h.player.playing = false;
      b.emit(const SpeechStarted(itemId: 'u2'));
      b.emit(const SpeechStopped(itemId: 'u2'));
      b.emit(const AssistantTranscriptDelta('Great.'));
      b.emit(const ResponseDone());
      b.emit(const UserTranscriptDone('Yes.', itemId: 'u2'));
      expect(h.pipeline.echoTurnsDropped, 0);
      expect(ofKind(h.conv, MessageKind.user).single.text, 'Yes.');
      expect(ofKind(h.conv, MessageKind.assistant).last.text, 'Great.');
      await h.dispose();
    });

    test('three echo turns in a row pause hands-free listening with a notice', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      var paused = 0;
      h.pipeline.onSelfTalk = () => paused++;
      final b = h.scripted;
      for (final (i, said, heard) in [
        (1, 'Tell me what you would like next.', 'Tell me.'),
        (2, 'Jasne, już otwieram.', 'Jasne.'),
        (3, 'Pointer moved.', 'Boiner moot.'),
      ]) {
        b.emit(AssistantTranscriptDelta(said));
        b.emit(AssistantAudioDelta(voice(300, amplitude: 8000, f0: 140)));
        b.emit(const ResponseDone());
        b.emit(SpeechStarted(itemId: 'u$i'));
        b.emit(SpeechStopped(itemId: 'u$i'));
        b.emit(const AssistantTranscriptDelta('Okay.'));
        b.emit(const ResponseDone());
        b.emit(UserTranscriptDone(heard, itemId: 'u$i'));
        expect(h.pipeline.echoTurnsDropped, i);
        expect(paused, i == 3 ? 1 : 0);
      }
      expect(h.pipeline.selfTalkBreaks, 1);
      expect(ofKind(h.conv, MessageKind.system).last.meta['type'], 'self_talk');
      expect(ofKind(h.conv, MessageKind.user), isEmpty);
      await h.dispose();
    });

    test('a genuine turn resets the self-talk count', () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
        echoGuard: EchoGuard(nowUs: () => 0),
      );
      final b = h.scripted;
      for (final (i, said, heard) in [
        (1, 'Tell me what you would like next.', 'Tell me.'),
        (2, 'Jasne, już otwieram.', 'Jasne.'),
        (3, 'Done.', 'Make it bigger.'),
        (4, 'Pointer moved.', 'Boiner moot.'),
      ]) {
        b.emit(AssistantTranscriptDelta(said));
        b.emit(AssistantAudioDelta(voice(300, amplitude: 8000, f0: 140)));
        b.emit(const ResponseDone());
        b.emit(SpeechStarted(itemId: 'u$i'));
        b.emit(SpeechStopped(itemId: 'u$i'));
        b.emit(const AssistantTranscriptDelta('Okay.'));
        b.emit(const ResponseDone());
        b.emit(UserTranscriptDone(heard, itemId: 'u$i'));
      }
      expect(h.pipeline.echoTurnsDropped, 3);
      expect(h.pipeline.selfTalkBreaks, 0);
      await h.dispose();
    });
  });

  group('tools', () {
    test('tool call round trip: dispatch, card status, result sent back', () async {
      final h = await Harness.create();
      h.scripted.emit(const ToolCall('c1', 'type_text', '{"text":"hey"}'));
      expect(h.pipeline.phase, AssistantPhase.toolRunning);
      await waitFor(() => h.scripted.toolResults.isNotEmpty);
      final (id, out) = h.scripted.toolResults.single;
      expect(id, 'c1');
      expect(jsonDecode(out), {'ok': true, 'chars': 3});
      expect(h.fp.input.log, ['type hey']);
      final card = ofKind(h.conv, MessageKind.tool).single.tool!;
      expect(card.status, ToolStatus.success);
      expect(card.finishedAt, isNotNull);
      await h.dispose();
    });

    test('rejected edit reports denied to the model', () async {
      final h = await Harness.create();
      h.confirm.approveWrites = false;
      h.scripted.emit(const ToolCall('w', 'write_file', '{"path":"~/x.txt","content":"x"}'));
      await waitFor(() => h.scripted.toolResults.isNotEmpty);
      expect(jsonDecode(h.scripted.toolResults.single.$2)['denied'], isTrue);
      expect(ofKind(h.conv, MessageKind.tool).single.tool!.status, ToolStatus.denied);
      expect(h.confirm.writeRequests, hasLength(1));
      await h.dispose();
    });

    test('take_screenshot tool attaches and sends the image', () async {
      final h = await Harness.create();
      h.scripted.emit(const ToolCall('s', 'take_screenshot', '{}'));
      await waitFor(() => h.scripted.toolResults.isNotEmpty);
      expect(h.scripted.images, hasLength(1));
      expect(h.conv.messages.where((m) => m.image != null), hasLength(1));
      await h.dispose();
    });
  });

  group('context', () {
    test('usage events feed the context manager; compaction adds a system note', () async {
      final h = await Harness.create(threshold: 100000, compressor: _ShortCompressor());
      final overhead = h.context.overheadTokens;
      expect(overhead, greaterThan(100), reason: 'instructions + tool definitions are context');
      expect(h.context.accounting, ContextAccounting.usage);
      final events = <ContextCompacted>[];
      h.pipeline.compactionEvents.listen(events.add);
      for (var i = 0; i < 4; i++) {
        h.pipeline.sendText('message number $i ${'x' * 200}');
        h.scripted.emit(AssistantTranscriptDelta('reply $i ${'y' * 200}'));
        h.scripted.emit(const ResponseDone());
      }
      h.scripted.emit(Usage(overhead + 500, 100, overhead + 600));
      expect(h.context.estimatedTokens, overhead + 600);
      h.context.threshold = overhead + 300;
      h.context.onConversationChanged();
      await waitFor(() => events.isNotEmpty);
      final e = events.first;
      expect(e.tokensBefore, overhead + 600, reason: 'the meter value before');
      expect(e.tokensAfter, h.context.estimatedTokens, reason: 'the meter value after');
      expect(e.substantial, isTrue);
      final note = h.conv.messages.lastWhere((m) => m.meta['type'] == 'compaction');
      expect(note.kind, MessageKind.system);
      expect(
        note.text,
        startsWith(
          'Context compacted: ${formatTokenCount(e.tokensBefore)} → ${formatTokenCount(e.tokensAfter)} tokens',
        ),
      );
      expect(h.conv.summary, isNotNull);
      await h.dispose();
    });
  });

  group('MockVoiceBackend integration', () {
    test('typed request triggers a tool call, result, and spoken reply', () async {
      late MockVoiceBackend mock;
      final h = await Harness.create(
        backend: () => mock = MockVoiceBackend(wordDelay: const Duration(milliseconds: 1)),
      );
      expect(h.pipeline.status, SessionStatus.connected);
      h.pipeline.sendText('please take a screenshot');
      await waitFor(() => ofKind(h.conv, MessageKind.tool).any((m) => m.tool!.status == ToolStatus.success));
      await waitFor(
        () =>
            ofKind(h.conv, MessageKind.assistant).length >= 2 && !ofKind(h.conv, MessageKind.assistant).last.streaming,
      );
      expect(mock.imagesReceived, 1);
      expect(ofKind(h.conv, MessageKind.assistant).last.text, isNotEmpty);
      expect(h.player.written.length, greaterThan(0), reason: 'reply audio played');
      expect(h.context.estimatedTokens, greaterThan(0));
      await h.dispose();
    });

    test('mock server VAD + barge-in on real-time audio', () async {
      late MockVoiceBackend mock;
      final h = await Harness.create(
        backend: () => mock = MockVoiceBackend(wordDelay: const Duration(milliseconds: 60)),
        options: const PipelineOptions(screenshotDelay: Duration(milliseconds: 100)),
      );
      await h.speak(600, amplitude: 30); // calibrate
      await h.speak(500, amplitude: 8000, realtime: true);
      await waitFor(() => h.pipeline.phase == AssistantPhase.userSpeaking);
      await h.speak(900, amplitude: 30, realtime: true);
      await waitFor(() => ofKind(h.conv, MessageKind.assistant).isNotEmpty, reason: 'reply starts');
      expect(mock.imagesReceived, 1, reason: 'speech-triggered screenshot reached backend');
      expect(ofKind(h.conv, MessageKind.user).single.text, contains('s of speech'));

      // Interrupt while the reply is still streaming.
      // (Voice-like: the echo gate only opens for something that is not
      // Woi's own sound.)
      await h.speak(600, amplitude: 20000, realtime: true, voiced: true);
      await waitFor(() => h.pipeline.bargeIns == 1);
      expect(mock.cancelCount, 1);
      expect(ofKind(h.conv, MessageKind.assistant).first.interrupted, isTrue);
      await h.dispose();
    });
  });

  test('history is persisted as JSON with the wav clip', () async {
    final h = await Harness.create();
    h.scripted.emit(const SpeechStarted());
    await h.speak(300);
    h.scripted.emit(const SpeechStopped());
    h.scripted.emit(const UserTranscriptDone('hello'));
    final user = ofKind(h.conv, MessageKind.user).single;
    await waitFor(() => user.audio != null);
    await h.store.save(h.conv);
    final loaded = await h.store.load(h.conv.id);
    expect(loaded!.messages.first.text, 'hello');
    expect(loaded.messages.first.audio!.path, endsWith('.wav'));
    final wavs = await h.fp.root.list(recursive: true).where((e) => e.path.endsWith('.wav')).length;
    expect(wavs, 1);
    await h.dispose();
  });

  group('camera frames', () {
    Future<(Harness, FakeCamera)> withCamera({bool replace = false, bool autoScreenshot = true}) async {
      final h = await Harness.create(
        options: PipelineOptions(
          screenshotDelay: const Duration(milliseconds: 50),
          cameraReplacesScreenshot: replace,
          autoScreenshot: autoScreenshot,
        ),
      );
      final cam = FakeCamera();
      await cam.open();
      h.pipeline.cameraImage = () {
        final f = cam.latest();
        return f == null ? null : ContextImage.camera(f);
      };
      return (h, cam);
    }

    test('adds: a spoken turn gets the screenshot and the camera frame', () async {
      final (h, cam) = await withCamera();
      h.scripted.emit(const SpeechStarted());
      await waitFor(() => h.scripted.images.length == 2);
      expect(h.fp.screen.captureTimes, hasLength(1));
      final camImg = h.scripted.images.firstWhere((i) => i.$2!.contains('Live camera frame'));
      expect(jpegSize(camImg.$1), (1280, 720));
      await waitFor(() => h.conv.messages.where((m) => m.image != null).length == 2);
      final camMsg = h.conv.messages.singleWhere((m) => m.meta['type'] == 'camera');
      expect(camMsg.meta[ContextImageMeta.kind], 'camera');
      expect(camMsg.image!.path, endsWith('.jpg'));
      expect(imageLabel(camMsg), 'Camera frame');
      expect(ofKind(h.conv, MessageKind.user).single.image, isNotNull, reason: 'screenshot stays on the turn');
      await cam.close();
      await h.dispose();
    });

    test('replaces: only the camera frame, on the user turn itself', () async {
      final (h, cam) = await withCamera(replace: true);
      h.scripted.emit(const SpeechStarted());
      await waitFor(() => h.scripted.images.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.scripted.images, hasLength(1));
      expect(h.fp.screen.captureTimes, isEmpty);
      final user = ofKind(h.conv, MessageKind.user).single;
      await waitFor(() => user.image != null);
      expect(user.meta[ContextImageMeta.kind], 'camera');
      await cam.close();
      await h.dispose();
    });

    test('camera on with auto-screenshot off still attaches frames; off attaches nothing', () async {
      final (h, cam) = await withCamera(autoScreenshot: false);
      h.scripted.emit(const SpeechStarted());
      await waitFor(() => h.scripted.images.isNotEmpty);
      expect(h.fp.screen.captureTimes, isEmpty);
      h.scripted.emit(const SpeechStopped());
      await cam.close();
      h.scripted.emit(const SpeechStarted());
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(h.scripted.images, hasLength(1));
      await h.dispose();
    });

    test('typed turns carry the frame before the text', () async {
      final (h, cam) = await withCamera();
      h.pipeline.sendText('what do you see?');
      expect(h.scripted.images, hasLength(1), reason: 'sent synchronously, before the text');
      expect(h.scripted.texts.single, 'what do you see?');
      expect(h.pipeline.contextImagesSent, 1);
      await cam.close();
      await h.dispose();
    });

    test('frames tier like screenshots', () async {
      final h = await Harness.create(
        images: (store) => ImageCompactor(
          policy: const ImageTierPolicy(rawRecentTurns: 0),
          downscale: (png, w, h) async => Uint8List.fromList(png.take(8).toList()),
          describe: (png, note) async => 'A person at a desk.',
          save: store.saveImage,
        ),
      );
      final cam = FakeCamera();
      await cam.open();
      for (var i = 0; i < 9; i++) {
        h.pipeline.attachContextImage(ContextImage.camera(cam.latest()!));
      }
      await waitFor(() => h.conv.messages.where((m) => m.image != null).length == 9);
      await h.pipeline.compactImages();
      final frames = h.conv.messages.where((m) => m.image != null).toList();
      expect(frames.map(imageTierOf), [
        ImageTier.described,
        ...List.filled(5, ImageTier.reduced),
        ...List.filled(3, ImageTier.full),
      ]);
      final described = h.scripted.replaced.singleWhere((x) => x.$3 != null && x.$2 == null);
      expect(described.$3, startsWith('Earlier camera frame from'));
      expect(h.scripted.replaced.firstWhere((x) => x.$2 != null).$3, startsWith('Camera frame from'));
      await cam.close();
      await h.dispose();
    });

    test('backends that cannot take images keep the frame for delegations', () async {
      final h = await Harness.create(backend: () => _SinkBackend());
      final cam = FakeCamera();
      await cam.open();
      h.pipeline.attachContextImage(ContextImage.camera(cam.latest()!));
      final b = h.lastBackend! as _SinkBackend;
      expect(b.images, isEmpty);
      expect(b.slots['camera']!.note, contains('Live camera frame'));
      h.pipeline.clearContextImage('camera');
      expect(b.slots, isEmpty);
      await h.dispose();
    });
  });

  group('phase settles (iter6)', () {
    test('a typed fast-path turn whose outcome is never voiced settles back to listening', () async {
      final h = await Harness.create();
      h.pipeline.settleAfter = const Duration(milliseconds: 300);
      h.pipeline.sendText('switch to terminal');
      expect(h.pipeline.phase, AssistantPhase.thinking);
      // The fast path runs a tool through the pipeline; the model then says nothing.
      h.scripted.emit(const ToolCall('dlg_1', 'get_clipboard', '{}'));
      await waitFor(() => h.scripted.toolResults.isNotEmpty);
      expect(h.pipeline.phase, AssistantPhase.thinking);
      await waitFor(() => h.pipeline.phase == AssistantPhase.listening, timeout: const Duration(seconds: 2));
      await h.dispose();
    });

    test('a spoken turn with no reply settles too; a busy backend keeps thinking', () async {
      final h = await Harness.create();
      h.pipeline.settleAfter = const Duration(milliseconds: 250);
      h.scripted
        ..busyFlag = true
        ..emit(const SpeechStarted(itemId: 'u1'))
        ..emit(const SpeechStopped(itemId: 'u1'));
      expect(h.pipeline.phase, AssistantPhase.thinking);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(h.pipeline.phase, AssistantPhase.thinking, reason: 'a delegation is still running');
      h.scripted.busyFlag = false;
      await waitFor(() => h.pipeline.phase == AssistantPhase.listening, timeout: const Duration(seconds: 2));
      await h.dispose();
    });

    test('a ResponseDone with no reply (backend settle) ends thinking at once', () async {
      final h = await Harness.create();
      h.pipeline.sendText('open camera');
      expect(h.pipeline.phase, AssistantPhase.thinking);
      h.scripted.emit(const ResponseDone());
      await waitFor(() => h.pipeline.phase == AssistantPhase.listening, timeout: const Duration(seconds: 1));
      await h.dispose();
    });

    test('speech start while the mic is muted is ignored (no barge-in, no phase change)', () async {
      final h = await Harness.create();
      await h.pipeline.setMicMode(MicMode.muted);
      // The assistant is talking.
      h.scripted
        ..emit(const AssistantTranscriptDelta('Here is a long story'))
        ..emit(AssistantAudioDelta(pcm(400)));
      expect(h.pipeline.phase, AssistantPhase.speaking);
      final users = ofKind(h.conv, MessageKind.user).length;
      h.scripted.emit(const SpeechStarted(itemId: 'server_turn'));
      expect(h.pipeline.phase, AssistantPhase.speaking);
      expect(h.pipeline.bargeIns, 0);
      expect(h.scripted.cancels, 0);
      expect(ofKind(h.conv, MessageKind.user).length, users);
      h.scripted.emit(const SpeechStopped(itemId: 'server_turn'));
      expect(h.pipeline.phase, isNot(AssistantPhase.thinking));
      await h.dispose();
    });
  });

  group('auto reconnect (iter6)', () {
    test('a dropped connection reconnects with backoff, shows reconnecting, no Retry needed', () async {
      final h = await Harness.create();
      h.pipeline.reconnectBaseDelay = const Duration(milliseconds: 50);
      final first = h.scripted;
      h.pipeline.sendText('hello');
      first.emit(const BackendError('gpt-live connection lost (1006)', code: 'connection_lost', fatal: true));
      expect(h.pipeline.reconnecting, isTrue);
      expect(h.pipeline.status, SessionStatus.connecting);
      expect(h.pipeline.phase, AssistantPhase.offline);
      await waitFor(() => h.pipeline.status == SessionStatus.connected && !h.pipeline.reconnecting);
      expect(identical(h.lastBackend, first), isFalse);
      expect(first.closed, isTrue);
      expect(h.scripted.config, isNotNull);
      expect(h.pipeline.autoReconnects, 1);
      expect(h.pipeline.phase, AssistantPhase.listening);
      expect(h.conv.messages.where((m) => m.text == 'Reconnected'), hasLength(1));
      await h.dispose();
    });

    test('failed attempts back off and retry; after the last one the error stays (Retry)', () async {
      var n = 0;
      final h = await Harness.create(
        backend: () {
          n++;
          return ScriptedBackend()..connectError = n >= 2 ? StateError('network down') : null;
        },
      );
      h.pipeline
        ..reconnectBaseDelay = const Duration(milliseconds: 20)
        ..maxAutoReconnects = 3;
      h.scripted.emit(const BackendError('lost', code: 'connection_lost', fatal: true));
      await waitFor(() => !h.pipeline.reconnecting, timeout: const Duration(seconds: 3));
      expect(n, 4, reason: 'initial connect + 3 attempts');
      expect(h.pipeline.status, SessionStatus.error);
      expect(h.conv.messages.last.text, contains('Could not reconnect'));
      await h.dispose();
    });

    test('a non-connection fatal error does not reconnect', () async {
      final h = await Harness.create();
      h.scripted.emit(const BackendError('invalid model', code: 'invalid_request', fatal: true));
      expect(h.pipeline.reconnecting, isFalse);
      expect(h.pipeline.status, SessionStatus.error);
      await h.dispose();
    });
  });

  group('auto connect (launch)', () {
    test('a failed connect at launch keeps retrying until connected; the mic opens', () async {
      var n = 0;
      final h = await Harness.create(
        backend: () {
          n++;
          return ScriptedBackend()..connectError = n <= 3 ? StateError('network down') : null;
        },
        setup: (p) => p.reconnectBaseDelay = const Duration(milliseconds: 10),
      );
      expect(h.pipeline.status, SessionStatus.error, reason: 'the failure stays visible until the next attempt');
      await waitFor(() => h.pipeline.status == SessionStatus.connected, timeout: const Duration(seconds: 3));
      expect(n, 4);
      expect(h.fp.audio.mic, isNotNull, reason: 'hands-free listening after the reconnect');
      await h.dispose();
    });

    test('a usage limit at launch does not retry right away', () async {
      var n = 0;
      final h = await Harness.create(
        backend: () {
          n++;
          return ScriptedBackend()
            ..connectError = StateError('HTTP 429 {"error":{"type":"usage_limit_reached","resets_in_seconds":3600}}');
        },
        setup: (p) => p.reconnectBaseDelay = const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(n, 1);
      expect(h.pipeline.reconnecting, isFalse);
      expect(h.pipeline.usageLimit, isNotNull);
      await h.dispose();
    });
  });

  group('idle power and usage limit (iter8)', () {
    const limit429 = 'gpt-live call failed: HTTP 429 {"error":{"type":"usage_limit_reached","resets_at":4102444800}}';

    test('a failed connect closes the pre-connect mic and releases the backend', () async {
      final h = await Harness.create(backend: () => ScriptedBackend()..connectError = StateError('network down'));
      expect(h.pipeline.status, SessionStatus.error);
      // The mic opens with the connect (pre-connect capture), and closes when
      // it fails with no automatic retry pending.
      expect(h.fp.audio.mic?.closed ?? true, isTrue, reason: 'no capture without a session');
      expect(h.pipeline.capturingWhileConnecting, isFalse);
      expect(h.scripted.closed, isTrue, reason: 'a half-built session must not keep its media alive');
      expect(h.pipeline.phase, AssistantPhase.offline);
      await h.dispose();
    });

    test('429: friendly status, no reconnect storm', () async {
      var n = 0;
      final h = await Harness.create(
        backend: () {
          n++;
          return ScriptedBackend()..connectError = n >= 2 ? StateError(limit429) : null;
        },
      );
      h.pipeline
        ..reconnectBaseDelay = const Duration(milliseconds: 10)
        ..maxAutoReconnects = 5;
      h.scripted.emit(const BackendError('lost', code: 'connection_lost', fatal: true));
      await waitFor(() => !h.pipeline.reconnecting, timeout: const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(n, 2, reason: 'initial connect + one attempt that hit the limit');
      expect(h.pipeline.status, SessionStatus.error);
      expect(h.pipeline.usageLimit, isNotNull);
      expect(h.pipeline.statusDetail, startsWith('ChatGPT usage limit reached, resets '));
      expect(h.pipeline.statusDetail, isNot(contains('{')));
      await h.dispose();
    });

    test('onUsageLimit returning true retries once (fallback backend); false does not', () async {
      var n = 0;
      var fallback = false;
      final h = await Harness.create(
        backend: () {
          n++;
          return ScriptedBackend()..connectError = fallback ? null : StateError(limit429);
        },
      );
      expect(n, 1);
      var calls = 0;
      h.pipeline.onUsageLimit = (l) async {
        calls++;
        return false;
      };
      await h.pipeline.connect();
      expect((n, calls, h.pipeline.status), (2, 1, SessionStatus.error));
      h.pipeline.onUsageLimit = (l) async {
        calls++;
        fallback = true;
        return true;
      };
      await h.pipeline.connect();
      expect((n, calls, h.pipeline.status), (4, 2, SessionStatus.connected));
      expect(h.pipeline.usageLimit, isNull);
      expect(h.fp.audio.mic, isNotNull);
      await h.dispose();
    });

    test('suspend frees the session and mic; resume reconnects', () async {
      final h = await Harness.create();
      final first = h.scripted;
      expect(h.fp.audio.mic, isNotNull);
      await h.pipeline.suspend();
      expect(h.pipeline.suspended, isTrue);
      expect(h.pipeline.status, SessionStatus.disconnected);
      expect(first.closed, isTrue);
      expect(h.mic.closed, isTrue);
      await h.pipeline.resume();
      expect(h.pipeline.suspended, isFalse);
      expect(h.pipeline.status, SessionStatus.connected);
      expect(identical(h.lastBackend, first), isFalse);
      expect(h.mic.closed, isFalse);
      await h.dispose();
    });

    test('a screenshot attached while offline is sent once connected, with the short label shown', () async {
      final h = await Harness.create();
      await h.pipeline.suspend();
      final shot = await h.fp.screen.capture();
      await h.pipeline.attachScreenshot(shot, note: 'Long note with visible text ...', label: 'Assist screenshot');
      final msg = h.conv.messages.lastWhere((m) => m.image != null);
      expect(msg.text, 'Assist screenshot');
      await h.pipeline.resume();
      expect(h.scripted.images, hasLength(1));
      expect(h.scripted.images.single.$2, startsWith('Long note with visible text'));
      await h.dispose();
    });
  });

  group('typed media questions', () {
    test('the hook runs before the text is sent and can extend it', () async {
      final h = await Harness.create();
      final gate = Completer<String?>();
      h.pipeline.beforeTypedTurn = (t) => t.contains('image') ? gate.future : null;
      h.pipeline.sendText('hello');
      expect(h.scripted.texts, ['hello']);
      h.pipeline.sendText("what's in this image");
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.scripted.texts, ['hello'], reason: 'waits for the media');
      gate.complete("what's in this image\n[media attached]");
      await waitFor(() => h.scripted.texts.length == 2);
      expect(h.scripted.texts.last, contains('[media attached]'));
      expect(
        ofKind(h.conv, MessageKind.user).last.text,
        "what's in this image",
        reason: 'transcript keeps the typed text',
      );
      await h.dispose();
    });

    test('a failing hook still sends the text', () async {
      final h = await Harness.create();
      h.pipeline.beforeTypedTurn = (t) => Future<String?>.error(StateError('ffmpeg missing'));
      h.pipeline.sendText('what is this song?');
      await waitFor(() => h.scripted.texts.isNotEmpty);
      expect(h.scripted.texts.single, 'what is this song?');
      expect(h.conv.messages.any((m) => m.text.contains('ffmpeg missing')), isTrue);
      await h.dispose();
    });
  });
}

class _SinkBackend extends ScriptedBackend implements ContextImageSink {
  final slots = <String, DelegationImage>{};
  @override
  void setContextImage(String slot, DelegationImage? image) => image == null ? slots.remove(slot) : slots[slot] = image;
}
