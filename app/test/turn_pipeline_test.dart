import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
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
  }) async {
    final fp = await FakePlatform.create();
    final store = HistoryStore(fp.services.paths);
    await store.init();
    final ctx = ContextManager(
      compressor: compressor ?? StubCompressor(latency: Duration.zero),
      threshold: threshold,
      keepRecent: 2,
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
      expect(h.conv.messages.indexOf(users[0]), lessThan(h.conv.messages.indexWhere((m) => m.kind == MessageKind.assistant)));
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

      // The next response is accepted again.
      b.emit(const SpeechStopped());
      b.emit(const AssistantTranscriptDelta('Sure.'));
      b.emit(const ResponseDone());
      expect(ofKind(h.conv, MessageKind.assistant).last.text, 'Sure.');
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
      final h = await Harness.create(threshold: 300, compressor: _ShortCompressor());
      final events = <ContextCompacted>[];
      h.pipeline.compactionEvents.listen(events.add);
      for (var i = 0; i < 4; i++) {
        h.pipeline.sendText('message number $i ${'x' * 200}');
        h.scripted.emit(AssistantTranscriptDelta('reply $i ${'y' * 200}'));
        h.scripted.emit(const ResponseDone());
      }
      h.scripted.emit(const Usage(500, 100, 600));
      await waitFor(() => events.isNotEmpty);
      expect(events.first.tokensBefore, greaterThan(events.first.tokensAfter));
      final note = h.conv.messages.lastWhere((m) => m.meta['type'] == 'compaction');
      expect(note.kind, MessageKind.system);
      expect(note.text, startsWith('Context compacted: '));
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
