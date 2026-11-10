import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/media/media_context.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/audio_io.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _Audio extends FakeAudioIO {
  void Function()? beforeOpen;
  final microphones = <FakeMic>[];

  @override
  Future<MicStream> openMic() async {
    beforeOpen?.call();
    final opened = await super.openMic();
    microphones.add(opened as FakeMic);
    return opened;
  }
}

class _Transport extends FakeLiveTransport {
  void Function()? beforeOffer;
  Completer<void>? closeGate;
  Completer<void>? captureResumeGate;
  bool closing = false;

  @override
  Future<String> createOffer() async {
    beforeOffer?.call();
    return super.createOffer();
  }

  @override
  Future<void> setCaptureSuspended(bool suspended) async {
    await super.setCaptureSuspended(suspended);
    if (!suspended) await captureResumeGate?.future;
  }

  @override
  Future<void> close() async {
    closing = true;
    await closeGate?.future;
    await super.close();
  }
}

class _Harness {
  _Harness(this.platform);
  final FakePlatform platform;
  final audio = _Audio();
  final transports = <_Transport>[];
  final violations = <String>[];
  final server = FakeLiveServer();
  final tools = ToolRegistry();
  final models = <FakeDelegationModel>[];
  final toolGate = Completer<void>();
  late final TurnPipeline pipeline;
  Duration idle = const Duration(milliseconds: 300);
  bool useRealtime = false;
  bool failConnect = false;
  bool closed = false;
  Completer<void>? configGate;
  ScriptedBackend? realtime;

  static Future<_Harness> create({
    bool withTool = false,
    Duration? idle,
    MicMode micMode = MicMode.handsFree,
    bool acknowledgeContext = true,
    String delegatedText = 'Finished.',
  }) async {
    final h = _Harness(await FakePlatform.create());
    // Normal provider sessions acknowledge each accepted append. Missing-receipt
    // behavior is exercised explicitly below, not by every standby fixture.
    h.server.autoAcknowledgeContext = acknowledgeContext;
    if (idle != null) h.idle = idle;
    h.audio.beforeOpen = () {
      if (h.transports.any((t) => !t.closed)) h.violations.add('Local capture opened before live close');
    };
    if (withTool) {
      h.tools.register(
        ToolDefinition(
          spec: const ToolSpec(name: 'slow_task', description: 'fixture', parameters: {'type': 'object'}),
          handler: (_, _) async {
            await h.toolGate.future;
            return {'ok': true};
          },
        ),
      );
    }
    final store = HistoryStore(h.platform.services.paths);
    await store.init();
    h.pipeline = TurnPipeline(
      backendFactory: () {
        if (h.useRealtime) return h.realtime = ScriptedBackend();
        return LiveWebRtcBackend(
          transportFactory: () {
            final transport = _Transport();
            transport.beforeOffer = () {
              if (h.audio.microphones.any((m) => !m.closed)) h.violations.add('Live capture opened before local close');
              if (h.transports.any((t) => !identical(t, transport) && !t.closed)) {
                h.violations.add('Live captures overlap');
              }
            };
            h.transports.add(transport);
            return transport;
          },
          sideband: h.server.connect,
          createCall: (uri, headers, body) async {
            if (h.failConnect) throw StateError('fixture connect failed');
            return h.server.createCall(uri, headers, body);
          },
          delegationModelFactory: (_) {
            final model = FakeDelegationModel([
              if (withTool) DelegationModelTurn(text: '', calls: [call('slow_task', {})]),
              DelegationModelTurn(text: delegatedText, calls: const []),
            ]);
            h.models.add(model);
            return model;
          },
        )..settleAfterResult = const Duration(milliseconds: 40);
      },
      audio: h.audio,
      screen: h.platform.screen,
      tools: h.tools,
      context: ContextManager(compressor: StubCompressor(latency: Duration.zero), threshold: 100000),
      store: store,
      conversation: Conversation(),
      sessionConfig: (_) async {
        await h.configGate?.future;
        return SessionConfig(
          model: 'gpt-live-1.1',
          voice: 'cove',
          instructions: 'test',
          tools: h.tools.specs,
          credentials: const Credentials(mode: AuthMode.codex, bearerToken: 'fixture-token'),
        );
      },
      options: () => PipelineOptions(
        autoScreenshot: false,
        micMode: micMode,
        onsetMicWithManagedAudio: false,
        localBargeIn: false,
        idleStandby: h.idle,
      ),
    );
    await h.pipeline.start();
    return h;
  }

  Future<void> asleep() => waitFor(
    () =>
        pipeline.standby &&
        pipeline.status == SessionStatus.disconnected &&
        (pipeline.micMode != MicMode.handsFree || audio.mic != null),
    timeout: const Duration(seconds: 4),
  );

  void wakeBySpeech() {
    final microphone = audio.mic!;
    for (var i = 0; i < 20; i++) {
      microphone.push(pcm(20, amplitude: 8));
    }
    for (var i = 0; i < 15; i++) {
      microphone.push(pcm(20, amplitude: 5000));
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!toolGate.isCompleted) toolGate.complete();
    await pipeline.shutdown();
    expect(violations, isEmpty);
    expect(audio.microphones.every((m) => m.closed), isTrue);
    expect(transports.every((t) => t.closed), isTrue);
    await platform.dispose();
  }
}

void main() {
  test('live push-to-talk honors off and configured idle, then waits without local capture', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk, idle: Duration.zero);
    addTearDown(h.close);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.pipeline.standby, isFalse);
    h.idle = const Duration(seconds: 30);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.pipeline.standby, isFalse);
    h.idle = const Duration(milliseconds: 300);
    await h.asleep();
    expect(h.transports.single.closed, isTrue);
    expect(h.transports.single.captureSuspensions, contains(true));
    expect(h.audio.micOpens, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(h.server.calls, hasLength(1));
    expect(h.pipeline.standby, isTrue);
  });

  test('an accepted context request prevents standby until its real answer arrives', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk, acknowledgeContext: false);
    addTearDown(h.close);
    h.pipeline.sendText('A synthetic ordinary question?');
    await waitFor(() => h.server.socket.ofType('session.context.append').isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(h.pipeline.standby, isFalse);
    expect(h.transports.single.closed, isFalse);
    expect(h.server.socket.ofType('session.context.append'), hasLength(1));
    h.server.socket.push({'type': 'session.context.appended'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.pipeline.standby, isFalse, reason: 'An ACK without an answer is still pending.');
    h.server.socket.turn('created', 'assistant', 100, 0, '');
    h.server.socket.turn('done', 'assistant', 100, 100, 'A synthetic answer.');
    await h.asleep();
    expect(h.transports.single.closed, isTrue);
    expect(h.server.calls, hasLength(1));
  });

  test('live push-to-talk press wakes and a held button prevents idle standby', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    h.pipeline.pttDown();
    await waitFor(() => h.server.calls.length == 2 && h.pipeline.status == SessionStatus.connected);
    expect(h.transports.last.micEnabled, isTrue);
    expect(h.audio.micOpens, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(h.pipeline.standby, isFalse, reason: 'a held button is activity even before server VAD');
    h.pipeline.pttUp();
    expect(h.transports.last.micEnabled, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.pipeline.standby, isFalse, reason: 'release starts a fresh idle interval');
    await h.asleep();
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
  });

  test('releasing live push-to-talk during wake keeps the new native mic disabled', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    final gate = h.configGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    h.pipeline.pttDown();
    await waitFor(() => h.pipeline.status == SessionStatus.connecting);
    h.pipeline.pttUp();
    gate.complete();
    await waitFor(() => h.server.calls.length == 2 && h.pipeline.status == SessionStatus.connected);
    expect(h.transports.last.micAtOffer, isFalse);
    expect(
      h.transports.last.micToggles,
      everyElement(isFalse),
      reason: 'released input must never flash on during native resume',
    );
    expect(h.audio.micOpens, isEmpty);
    expect(h.server.socket.ofType('session.context.append'), isEmpty);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
    h.pipeline.pttDown();
    await waitFor(() => h.transports.last.micEnabled);
    expect(h.server.calls, hasLength(2), reason: 'a later press uses the already awake session');
    h.pipeline.pttUp();
  });

  test('opening a managed observation stream preserves mute throughout slow native resume', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk, idle: Duration.zero);
    addTearDown(h.close);
    final transport = h.transports.single;
    final gate = transport.captureResumeGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final before = transport.captureSuspensions.length;
    final opening = (h.pipeline.backend! as ManagedAudioBackend).openManagedMic();
    await waitFor(() => transport.captureSuspensions.length > before);
    expect(transport.micEnabled, isFalse);
    expect(transport.micToggles, everyElement(isFalse));
    gate.complete();
    final microphone = await opening;
    expect(transport.micEnabled, isFalse);
    await microphone.close();
  });

  test('live push-to-talk typed wake delivers once and leaves capture disabled', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    const text = 'Hello from push-to-talk standby';
    h.pipeline.sendText(text);
    await waitFor(() => h.server.calls.length == 2 && h.pipeline.status == SessionStatus.connected);
    await waitFor(() => h.server.socket.ofType('session.context.append').isNotEmpty);
    expect(h.server.socket.ofType('session.context.append'), hasLength(1));
    expect(h.server.socket.ofType('session.context.append').single['content'], [
      {'type': 'input_text', 'text': 'The user typed (instead of speaking): $text'},
    ]);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user && m.text == text), hasLength(1));
    expect(h.transports.last.micToggles, everyElement(isFalse));
    expect(h.audio.micOpens, isEmpty);
  });

  ContextImage imageFixture([int marker = 7]) => ContextImage(
    bytes: Uint8List.fromList([137, 80, 78, 71, marker, 11, 13]),
    width: 3,
    height: 2,
    kind: 'attachment:fixture-$marker',
    note: 'Explicit attachment fixture',
    capturedAt: DateTime(2026, 11, 9),
  );

  test('accepted attachment analysis stays readable without live narration', () async {
    const answer = 'A teal triangle sits to the left of an orange circle.';
    final h = await _Harness.create(micMode: MicMode.pushToTalk, idle: Duration.zero, delegatedText: answer);
    addTearDown(h.close);
    expect(await h.pipeline.sendText('Describe this image.', attachedImages: [imageFixture()]), isTrue);
    await waitFor(() => h.server.socket.ofType('session.context.append').isNotEmpty);
    final messages = h.pipeline.conversation.messages;
    final user = messages.singleWhere((m) => m.kind == MessageKind.user);
    final written = messages.where((m) => m.kind == MessageKind.assistant).toList();
    expect(
      written,
      hasLength(1),
      reason: 'A completed vision result must remain useful when live narration never arrives.',
    );
    expect(written.single.text, answer);
    expect(written.single.meta['type'], 'attachment_analysis');
    expect(written.single.meta['sourceMessageId'], user.id);
    expect(written.single.meta['model'], 'gpt-6-luna');
    expect(written.single.audio, isNull, reason: 'Written analysis is not a fabricated spoken transcript.');
    expect(h.models.single.requests, hasLength(1));
  });

  test('standby attachment wake preserves immutable pixels, display, audio, and user intent', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    final gate = h.configGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final image = imageFixture();
    final expected = Uint8List.fromList(image.bytes);
    final images = [image];
    const prompt = 'Describe the attached picture, then explain its spatial arrangement.';
    const display = 'My image question\n\n[selected.png](file:///synthetic/selected.png)';
    const audio = AudioClip(path: 'synthetic.wav', durationMs: 1250);
    var completed = false;
    final accepted = h.pipeline.sendText(
      prompt,
      displayText: display,
      attachedImages: images,
      audioClip: audio,
      includesSystemAudio: true,
    )..then((_) => completed = true);
    await waitFor(() => h.pipeline.status == SessionStatus.connecting);
    expect(completed, isFalse, reason: 'Request is not accepted until dispatch.');
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
    image.bytes[4] = 99;
    images.clear();
    gate.complete();
    expect(await accepted, isTrue);
    await waitFor(() => h.models.any((model) => model.requests.isNotEmpty));
    final request = h.models.expand((model) => model.requests).single;
    final content = request.input.single['content'] as List;
    final pixels = content.whereType<Map>().where((item) => item['type'] == 'input_image').toList();
    expect(pixels, hasLength(1));
    expect(pixels.single['image_url'], 'data:image/png;base64,${base64Encode(expected)}');
    expect(jsonEncode(content), contains(prompt));
    final user = h.pipeline.conversation.messages.singleWhere((m) => m.kind == MessageKind.user);
    expect(user.text, display);
    expect(user.audio, same(audio));
    expect(user.meta['captureSources'], ['microphone', 'system']);
    expect(user.meta['imageKind'], image.kind);
    expect(h.server.calls, hasLength(2));
    expect(h.audio.micOpens, isEmpty);
  });

  test('explicit image request preserves web-search intent after typed wake', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    h.tools.register(
      ToolDefinition(
        spec: const ToolSpec(name: 'web_search', description: 'search', parameters: {'type': 'object'}),
        handler: (_, _) async => {'answer': 'fixture'},
      ),
    );
    await h.asleep();
    const prompt = 'Use web search to find an official explanation of the symbol in this attached image.';
    expect(await h.pipeline.sendText(prompt, displayText: prompt, attachedImages: [imageFixture()]), isTrue);
    await waitFor(() => h.models.any((model) => model.requests.isNotEmpty));
    final request = h.models.expand((model) => model.requests).single;
    expect(jsonEncode(request.input), contains(prompt));
    expect(request.tools.any((tool) => tool['name'] == 'web_search'), isTrue);
    expect(h.pipeline.conversation.messages.singleWhere((m) => m.kind == MessageKind.user).text, prompt);
  });

  test('attachment preparation target remains valid when normal standby starts during file I/O', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    final target = h.pipeline.captureTypedSendTarget();
    await h.asleep();
    expect(await h.pipeline.sendText('Describe this image.', attachedImages: [imageFixture()], target: target), isTrue);
    await waitFor(() => h.models.any((model) => model.requests.isNotEmpty));
    expect(h.models.expand((model) => model.requests), hasLength(1));
  });

  test('failed attachment wake rejects once and never replays on explicit reconnect', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    h.failConnect = true;
    h.pipeline.maxAutoReconnects = 0;
    expect(await h.pipeline.sendText('Describe this image.', attachedImages: [imageFixture()]), isFalse);
    await waitFor(() => h.pipeline.status == SessionStatus.error);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
    expect(h.models.expand((model) => model.requests), isEmpty);
    h.failConnect = false;
    await h.pipeline.connect();
    expect(h.models.expand((model) => model.requests), isEmpty);
    expect(h.server.socket.ofType('session.context.append'), isEmpty);
    expect(await h.pipeline.sendText('Hello after retry'), isTrue);
    expect(h.server.socket.ofType('session.context.append').single['content'], [
      {'type': 'input_text', 'text': 'The user typed (instead of speaking): Hello after retry'},
    ]);
  });

  test('Stop rejects a queued image and permits only the subsequent ordinary turn', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.asleep();
    final gate = h.configGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final old = h.pipeline.sendText('Describe this image.', attachedImages: [imageFixture()]);
    await waitFor(() => h.pipeline.status == SessionStatus.connecting);
    h.pipeline.interrupt();
    expect(await old, isFalse);
    final fresh = h.pipeline.sendText('What is two plus two?');
    gate.complete();
    expect(await fresh, isTrue);
    expect(h.models.expand((model) => model.requests), isEmpty);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user).map((m) => m.text), [
      'What is two plus two?',
    ]);
    expect(h.server.socket.ofType('session.context.append').single['content'], [
      {'type': 'input_text', 'text': 'The user typed (instead of speaking): What is two plus two?'},
    ]);
  });

  for (final replacement in ['conversation', 'reconnect', 'suspend']) {
    test('$replacement rejects queued attachments before a new session can dispatch them', () async {
      final h = await _Harness.create(micMode: MicMode.pushToTalk);
      addTearDown(h.close);
      await h.asleep();
      final gate = h.configGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final old = h.pipeline.sendText('Describe the old image.', attachedImages: [imageFixture()]);
      await waitFor(() => h.pipeline.status == SessionStatus.connecting);
      h.configGate = null;
      if (replacement == 'conversation') {
        await h.pipeline.switchConversation(Conversation());
      } else if (replacement == 'reconnect') {
        await h.pipeline.connect();
      } else {
        await h.pipeline.suspend();
        await h.pipeline.resume();
      }
      expect(await old, isFalse);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.models.expand((model) => model.requests), isEmpty);
      expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
      expect(h.server.socket.ofType('session.context.append'), isEmpty);
    });
  }

  test('a target captured before Stop cannot send after asynchronous attachment preparation', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    final old = h.pipeline.captureTypedSendTarget();
    h.pipeline.interrupt();
    expect(await h.pipeline.sendText('Describe this image.', attachedImages: [imageFixture()], target: old), isFalse);
    expect(h.models.expand((model) => model.requests), isEmpty);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
  });

  test('a live push-to-talk wake during close never reenables the retiring capture', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    final first = h.transports.single;
    final gate = first.closeGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await waitFor(() => first.closing);
    h.pipeline.pttDown();
    expect(first.micEnabled, isFalse);
    h.pipeline.pttUp();
    gate.complete();
    await waitFor(() => h.server.calls.length == 2 && h.pipeline.status == SessionStatus.connected);
    expect(first.micToggles, everyElement(isFalse));
    expect(h.transports.last.micToggles, everyElement(isFalse));
    expect(h.audio.micOpens, isEmpty);
  });

  test('standby mode changes and recording resume preserve push-to-talk mic privacy', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    await h.asleep();
    final local = h.audio.mic!;
    await h.pipeline.setMicMode(MicMode.pushToTalk);
    expect(local.closed, isTrue);
    final opens = h.audio.micOpens.length;
    await h.pipeline.suspendForRecording();
    await h.pipeline.resumeAfterRecording();
    expect(h.audio.micOpens, hasLength(opens));
    expect(h.pipeline.standby, isTrue);
    await h.pipeline.setMicMode(MicMode.handsFree);
    expect(h.audio.mic!.closed, isFalse);
    h.wakeBySpeech();
    await waitFor(() => h.server.calls.length == 2 && h.pipeline.status == SessionStatus.connected);
    expect(h.transports.last.micEnabled, isTrue);
  });

  test('recording hold prevents live push-to-talk standby and stray presses', () async {
    final h = await _Harness.create(micMode: MicMode.pushToTalk);
    addTearDown(h.close);
    await h.pipeline.suspendForRecording();
    h.pipeline.pttDown();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(h.pipeline.standby, isFalse);
    expect(h.transports.single.micEnabled, isFalse);
    expect(h.transports.single.captureSuspended, isTrue);
    await h.pipeline.resumeAfterRecording();
    await h.asleep();
    expect(h.audio.micOpens, isEmpty);
  });

  test('configured live idle disconnects, stays asleep, and wakes with exclusive capture', () async {
    final h = await _Harness.create(idle: const Duration(seconds: 30));
    addTearDown(h.close);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.pipeline.standby, isFalse, reason: 'the configured 30-second duration is honored');
    expect(h.audio.micOpens, isEmpty);
    h.idle = const Duration(milliseconds: 300);
    await h.asleep();
    final first = h.transports.single;
    final local = h.audio.mic!;
    expect(first.closed, isTrue);
    expect(first.captureSuspensions, contains(true));
    expect(h.server.sockets.single.closed, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(h.server.calls, hasLength(1), reason: 'intentional idle never schedules automatic reconnect');
    expect(h.pipeline.reconnecting, isFalse);
    for (var i = 0; i < 30; i++) {
      local.push(pcm(20, amplitude: 8));
    }
    expect(h.pipeline.standby, isTrue, reason: 'room noise is not a wake');
    h.wakeBySpeech();
    await waitFor(() => h.pipeline.status == SessionStatus.connected && h.transports.length == 2);
    expect(local.closed, isTrue);
    expect(h.transports.last.micEnabled, isTrue);
    expect(h.pipeline.backendManagesAudio, isTrue);
    expect(
      h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user),
      isEmpty,
      reason: 'WebRTC cannot inject pre-roll; wake audio must not become a fabricated partial request',
    );
    expect(h.violations, isEmpty);
  });

  test('typed wake waits for native close, queues once, and Stop does not reopen a sleeping call', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final gate = h.transports.single.closeGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await waitFor(() => h.transports.single.closing);
    expect(h.audio.micOpens, isEmpty);
    h.pipeline.interrupt();
    expect(h.server.calls, hasLength(1));
    h.pipeline.sendText('Hello after standby');
    h.pipeline.sendText('A second message');
    expect(h.server.calls, hasLength(1));
    gate.complete();
    await waitFor(() => h.server.calls.length == 3 && h.pipeline.status == SessionStatus.connected);
    await waitFor(() => h.server.sockets.expand((socket) => socket.ofType('session.context.append')).length == 2);
    expect(h.server.sockets[1].ofType('session.context.append'), hasLength(1));
    expect(h.server.sockets[2].ofType('session.context.append'), hasLength(1));
    expect(h.transports[1].closed, isTrue, reason: 'New input replaces the unanswered call without replay.');
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), hasLength(2));
    expect(h.audio.micOpens, isEmpty, reason: 'a cancelled handoff never opens a redundant wake mic');
    expect(h.violations, isEmpty);
  });

  test('new backend selection while waking wins without retaining either old capture', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    await h.asleep();
    final local = h.audio.mic!;
    final gate = h.configGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    h.wakeBySpeech();
    await waitFor(() => h.pipeline.status == SessionStatus.connecting && local.closed);
    h.pipeline.interrupt();
    h.useRealtime = true;
    h.configGate = null;
    await h.pipeline.connect();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.pipeline.backend, same(h.realtime));
    expect(h.pipeline.status, SessionStatus.connected);
    expect(h.transports, hasLength(1), reason: 'the superseded live connect never acquires capture');
    expect(h.audio.mic!.closed, isFalse);
    expect(h.violations, isEmpty);
  });

  for (final mode in [MicMode.handsFree, MicMode.pushToTalk]) {
    test('${mode.name}: user speech and a pending answer prevent live standby', () async {
      final h = await _Harness.create(micMode: mode);
      addTearDown(h.close);
      h.server.socket.turn('created', 'user', 100, 0, '');
      await waitFor(() => h.pipeline.phase == AssistantPhase.userSpeaking);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(h.pipeline.standby, isFalse);
      h.server.socket.turn('done', 'user', 100, 900, 'Tell me about this task.');
      await waitFor(() => h.pipeline.phase == AssistantPhase.thinking);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(h.pipeline.standby, isFalse);
      expect(h.transports.single.closed, isFalse);
    });

    test('${mode.name}: assistant playback and its tail prevent standby and a false wake', () async {
      final h = await _Harness.create(micMode: mode);
      addTearDown(h.close);
      h.server.socket.turn('created', 'assistant', 100, 0, 'Here is the answer.');
      h.server.socket.audio(100, pcm(1000, amplitude: 5000));
      h.server.socket.turn('done', 'assistant', 100, 1100, 'Here is the answer.');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(h.pipeline.standby, isFalse);
      expect(h.audio.micOpens, isEmpty, reason: 'no local wake listener can hear assistant playback');
      await h.asleep();
      expect(h.server.calls, hasLength(1));
    });

    test('${mode.name}: a running delegated tool keeps the live call active until it completes', () async {
      final h = await _Harness.create(withTool: true, micMode: mode);
      addTearDown(h.close);
      h.server.socket.delegation('slow-work', 'Use slow_task to finish the fixture task.');
      await waitFor(() => h.pipeline.phase == AssistantPhase.toolRunning);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(h.pipeline.standby, isFalse);
      expect(h.transports.single.closed, isFalse);
      h.toolGate.complete();
      await waitFor(() => h.server.socket.ofType('delegation.context.append').isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.pipeline.standby, isFalse, reason: 'Completed work still awaits its live outcome.');
      h.server.socket.turn('created', 'assistant', 100, 0, '');
      h.server.socket.turn('done', 'assistant', 100, 100, 'Finished.');
      await h.asleep();
    });
  }

  test('activity during native release aborts standby and restores the original live capture', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final first = h.transports.single;
    final gate = first.captureSuspendGate = Completer<void>();
    final resumeGate = first.captureResumeGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      if (!resumeGate.isCompleted) resumeGate.complete();
    });
    await waitFor(() => first.captureSuspended);
    h.server.socket.turn('created', 'user', 100, 0, '');
    await waitFor(() => h.pipeline.phase == AssistantPhase.userSpeaking);
    gate.complete();
    await waitFor(() => !h.pipeline.standby && !first.captureSuspended);
    const text = 'Hello again';
    h.pipeline.sendText(text);
    expect(h.server.socket.ofType('session.context.append'), isEmpty);
    resumeGate.complete();
    await waitFor(() => h.server.socket.ofType('session.context.append').isNotEmpty);
    final appended = h.server.socket.ofType('session.context.append');
    expect(appended, hasLength(1));
    expect(appended.single['content'], [
      {'type': 'input_text', 'text': 'The user typed (instead of speaking): $text'},
    ]);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user && m.text == text), hasLength(1));
    expect(first.closed, isFalse);
    expect(first.micEnabled, isTrue);
    expect(h.audio.micOpens, isEmpty);
    expect(h.server.calls, hasLength(1));
  });

  test('suspend cancels a slow wake-mic open and resume returns to live', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final gate = h.audio.openMicGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await waitFor(() => h.audio.micOpens.isNotEmpty);
    final suspending = h.pipeline.suspend();
    gate.complete();
    await suspending;
    expect(h.pipeline.suspended, isTrue);
    expect(h.pipeline.standby, isFalse);
    expect(h.audio.mic!.closed, isTrue);
    h.audio.openMicGate = null;
    await h.pipeline.resume();
    expect(h.pipeline.status, SessionStatus.connected);
    expect(h.transports, hasLength(2));
    expect(h.violations, isEmpty);
  });

  test('muting during native release prevents local capture until listening resumes', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final gate = h.transports.single.captureSuspendGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await waitFor(() => h.transports.single.captureSuspended);
    final muting = h.pipeline.setMicMode(MicMode.muted);
    gate.complete();
    await muting;
    expect(h.audio.micOpens, isEmpty);
    expect(h.pipeline.status, SessionStatus.disconnected);
    await h.pipeline.setMicMode(MicMode.handsFree);
    expect(h.audio.mic!.closed, isFalse);
    h.wakeBySpeech();
    await waitFor(() => h.pipeline.status == SessionStatus.connected);
    expect(h.violations, isEmpty);
  });

  test('failed native release closes the call and never opens an unsafe local capture', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    h.transports.single.captureSuspendError = StateError('fixture release failed');
    await waitFor(() => h.pipeline.status == SessionStatus.error);
    expect(h.pipeline.standby, isFalse);
    expect(h.pipeline.statusDetail, contains('release voice capture'));
    expect(h.audio.micOpens, isEmpty);
    expect(h.transports.single.closed, isTrue);
    expect(h.pipeline.backend, isNull);
  });

  test('failed wake microphone and failed reconnect both clean up capture', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    h.audio.openMicError = StateError('fixture mic unavailable');
    await waitFor(() => h.pipeline.status == SessionStatus.error);
    expect(h.pipeline.standby, isFalse);
    expect(h.transports.single.closed, isTrue);
    expect(h.audio.mic, isNull);
    h.audio.openMicError = null;
    await h.pipeline.connect();
    await h.asleep();
    h.failConnect = true;
    h.pipeline.maxAutoReconnects = 0;
    h.wakeBySpeech();
    await waitFor(() => h.pipeline.status == SessionStatus.error);
    expect(h.audio.microphones.every((m) => m.closed), isTrue);
    expect(h.transports.every((t) => t.closed), isTrue);
    expect(h.pipeline.backend, isNull);
  });

  test('shutdown waits for and closes a late standby microphone', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final gate = h.audio.openMicGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await waitFor(() => h.audio.micOpens.isNotEmpty);
    final closing = h.close();
    gate.complete();
    await closing;
    expect(h.audio.mic!.closed, isTrue);
  });
}
