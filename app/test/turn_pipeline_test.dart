import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/earcon.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/mock_voice_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
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
    );
    await h.pipeline.start();
    return h;
  }

  FakeMic get mic => fp.audio.mic!;
  FakePcmPlayer get player => fp.audio.player;

  /// Feeds [ms] of audio in 20 ms chunks, yielding to timers in between.
  Future<void> speak(int ms, {int amplitude = 6000, bool realtime = false}) async {
    for (var t = 0; t < ms; t += 20) {
      mic.push(pcm(20, amplitude: amplitude));
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

Iterable<Message> ofKind(Conversation c, MessageKind k) => c.messages.where((m) => m.kind == k);

void main() {
  group('screenshot tiers', () {
    test('older screenshots go to 1/5 size, then to a description, in the live context', () async {
      final sizes = <(int, int)>[];
      final h = await Harness.create(
        images: (store) => ImageCompactor(
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
      expect(sizes.first, (256, 144), reason: '1280x720 / 5');
      // Originals stay; the reduced copy is saved next to them.
      expect(File(shots.first.image!.path).existsSync(), isTrue);
      expect(File(shots[1].meta[ImageMeta.sentPath]! as String).existsSync(), isTrue);
      expect(shots.first.meta[ImageMeta.serverItem], startsWith('img_1_v'));
      expect(h.scripted.screenMemory, contains('A terminal with ls output.'));
      // The meter shows the savings.
      final p = h.context.parts();
      expect(p.imagesReduced, 5);
      expect(p.imagesDescribed, 1);
      expect(p.imagesSaved, greaterThan(5 * 400));
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

    test('local mic onset cuts playback before the server notices', () async {
      final h = await Harness.create(options: const PipelineOptions(autoScreenshot: false));
      final b = h.scripted;
      final mic = h.fp.audio.mic!;
      b.emit(const AssistantTranscriptDelta('Once upon a time '));
      // Assistant audio plays; the mic hears only faint echo for a while.
      for (var i = 0; i < 40; i++) {
        b.emit(AssistantAudioDelta(pcm(20, amplitude: 8000)));
        mic.push(pcm(20, amplitude: 300));
      }
      expect(h.pipeline.localOnsets, 0, reason: 'echo is not an onset');
      final stops = h.player.stops;
      // The user talks over it.
      for (var i = 0; i < 10; i++) {
        mic.push(pcm(20, amplitude: 9000));
      }
      expect(h.pipeline.localOnsets, 1);
      expect(h.player.stops, stops + 1);
      expect(b.cancels, 1);
      expect(b.holds, [true], reason: 'reply held until we know it is not "stop"');
      expect(ofKind(h.conv, MessageKind.assistant).single.interrupted, isTrue);
      // Server VAD confirms later: no second barge-in.
      b.emit(const SpeechStarted(itemId: 'u1'));
      expect(h.pipeline.bargeIns, 1);
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
      await h.speak(400, amplitude: 20000, realtime: true);
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
}
