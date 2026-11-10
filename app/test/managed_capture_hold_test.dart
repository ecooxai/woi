import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/media/held_audio_recorder.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _FirstReleaseFails extends FakeLiveTransport {
  int releaseAttempts = 0;

  @override
  Future<void> setCaptureSuspended(bool suspended) async {
    await super.setCaptureSuspended(suspended);
    if (suspended && ++releaseAttempts == 1) {
      throw StateError('native capture could not be released');
    }
  }
}

class _Harness {
  _Harness(this.platform);
  final FakePlatform platform;
  final transports = <FakeLiveTransport>[];
  final server = FakeLiveServer()..autoAcknowledgeContext = true;
  Object? nextCallError;
  Completer<void>? callGate;
  int callAttempts = 0;
  late final TurnPipeline pipeline;

  static Future<_Harness> create({FakeLiveTransport? firstTransport}) async {
    final h = _Harness(await FakePlatform.create());
    final store = HistoryStore(h.platform.services.paths);
    await store.init();
    h.pipeline = TurnPipeline(
      backendFactory: () => LiveWebRtcBackend(
        transportFactory: () {
          final transport = h.transports.isEmpty ? firstTransport ?? FakeLiveTransport() : FakeLiveTransport();
          h.transports.add(transport);
          return transport;
        },
        sideband: h.server.connect,
        createCall: (uri, headers, body) async {
          h.callAttempts++;
          await h.callGate?.future;
          final error = h.nextCallError;
          h.nextCallError = null;
          if (error != null) throw error;
          return h.server.createCall(uri, headers, body);
        },
        delegationModelFactory: (_) => FakeDelegationModel([]),
        swapQuiet: const Duration(milliseconds: 10),
        swapPoll: const Duration(milliseconds: 5),
      ),
      audio: h.platform.audio,
      screen: h.platform.screen,
      tools: ToolRegistry(),
      context: ContextManager(compressor: StubCompressor(latency: Duration.zero), threshold: 100000),
      store: store,
      conversation: Conversation(),
      sessionConfig: (_) async => const SessionConfig(
        model: 'gpt-live-1.1',
        voice: 'cove',
        instructions: 'test',
        credentials: Credentials(mode: AuthMode.codex, bearerToken: 'test'),
      ),
      options: () => const PipelineOptions(autoScreenshot: false, onsetMicWithManagedAudio: false),
    );
    await h.pipeline.start();
    await waitFor(() => h.pipeline.status == SessionStatus.connected);
    return h;
  }

  Future<void> close() async {
    await pipeline.shutdown();
    await platform.dispose();
  }
}

void main() {
  test('held capture waits for native release and keeps a reconnect suspended until recording ends', () async {
    final h = await _Harness.create();
    final first = h.transports.single;
    first.captureSuspendGate = Completer<void>();
    final heldMic = FakeMic();
    var opens = 0;
    final reports = <String>[];
    final recording = HeldAudioRecorder(
      open: () async {
        opens++;
        return heldMic;
      },
      suspendListening: h.pipeline.suspendForRecording,
      resumeListening: h.pipeline.resumeAfterRecording,
      submit: (_, _) async => fail('Cancelled recording must not be submitted'),
      report: reports.add,
    );
    recording.start();
    await waitFor(() => first.captureSuspended);
    expect(opens, 0, reason: 'logical mute is insufficient while native teardown is pending');
    first.captureSuspendGate!.complete();
    await waitFor(() => opens == 1);
    await h.pipeline.connect();
    final next = h.transports.last;
    expect(h.transports, hasLength(2));
    expect(next.captureSuspendedAtOffer, isTrue);
    expect(next.captureSuspended, isTrue);
    expect(next.micAtOffer, isFalse);
    expect(h.platform.audio.micOpens, isEmpty);
    await recording.cancel();
    expect(heldMic.closed, isTrue);
    expect(next.captureSuspended, isFalse);
    expect(next.micEnabled, isTrue);
    expect(reports, isEmpty);
    recording.dispose();
    await h.close();
  });

  test('fatal capture release failure cannot be bypassed by an offline held recording', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final transport = h.transports.single;
    transport.captureSuspendError = StateError('native capture release unconfirmed');
    h.pipeline.interrupt();
    expect(await h.pipeline.sendText('Keep this draft.', displayText: 'Keep this draft.'), isFalse);
    await waitFor(() => h.pipeline.status == SessionStatus.error && h.pipeline.backend == null && transport.closed);
    var opens = 0;
    final reports = <String>[];
    final recording = HeldAudioRecorder(
      open: () async {
        opens++;
        return FakeMic();
      },
      suspendListening: h.pipeline.suspendForRecording,
      resumeListening: h.pipeline.resumeAfterRecording,
      submit: (_, _) async => fail('Failed capture must not be submitted'),
      report: reports.add,
    );
    addTearDown(() async {
      await recording.cancel();
      recording.dispose();
    });
    recording.start();
    await waitFor(() => opens > 0 || !recording.busy);
    expect(opens, 0, reason: 'Fatal backend detachment must retain the unconfirmed-release guard.');
    expect(reports.single, contains('Reconnect'));
    expect(h.transports, hasLength(1));
    expect(h.pipeline.voiceInputNeedsReconnect, isTrue);
    expect(h.pipeline.phase, AssistantPhase.offline);
    expect(
      h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user),
      isEmpty,
      reason: 'The rejected draft is not committed or replayed.',
    );
  });

  test('ordinary offline held recording still opens when no native release failed', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    await h.pipeline.suspend();
    final mic = FakeMic();
    var opens = 0;
    final reports = <String>[];
    final recording = HeldAudioRecorder(
      open: () async {
        opens++;
        return mic;
      },
      suspendListening: h.pipeline.suspendForRecording,
      resumeListening: h.pipeline.resumeAfterRecording,
      submit: (_, _) async => fail('Cancelled recording must not be submitted'),
      report: reports.add,
    );
    addTearDown(() async {
      await recording.cancel();
      recording.dispose();
    });
    recording.start();
    await waitFor(() => opens == 1);
    await recording.cancel();
    expect(mic.closed, isTrue);
    expect(reports, isEmpty);
    expect(h.transports, hasLength(1));
    expect(h.pipeline.voiceInputNeedsReconnect, isFalse);
  });

  test('failed native release blocks holds and automatic retries until explicit reconnect succeeds', () async {
    final transport = _FirstReleaseFails();
    final h = await _Harness.create(firstTransport: transport);
    addTearDown(h.close);
    h.pipeline.reconnectBaseDelay = const Duration(milliseconds: 1);
    var opens = 0;
    final reports = <String>[];
    final recording = HeldAudioRecorder(
      open: () async {
        opens++;
        return FakeMic();
      },
      suspendListening: h.pipeline.suspendForRecording,
      resumeListening: h.pipeline.resumeAfterRecording,
      submit: (_, _) async => fail('Failed or cancelled capture must not be submitted'),
      report: reports.add,
    );
    addTearDown(() async {
      await recording.cancel();
      recording.dispose();
    });
    recording.start();
    await waitFor(() => !recording.busy && transport.closed);
    expect(opens, 0);
    expect(reports.single, contains('native capture could not be released'));
    expect(transport.captureSuspended, isTrue);
    expect(transport.micEnabled, isFalse);
    expect(h.pipeline.status, SessionStatus.error);
    expect(h.pipeline.voiceInputNeedsReconnect, isTrue);
    expect(h.pipeline.phase, AssistantPhase.offline);
    expect(h.pipeline.statusDetail, contains('Reconnect'));
    expect(h.pipeline.canSendTypedInput, isFalse);
    final retiredTarget = h.pipeline.captureTypedSendTarget();
    const draft = 'Keep this exact unsent question.';
    expect(await h.pipeline.sendText(draft, displayText: draft), isFalse);
    recording.start();
    await waitFor(() => !recording.busy);
    expect(opens, 0);
    expect(reports.last, contains('Reconnect'));
    expect(transport.releaseAttempts, 1);

    // Settings/lifecycle connect and recorded Send are not explicit recovery.
    await h.pipeline.connect();
    await h.pipeline.suspend();
    await h.pipeline.resume();
    await h.pipeline.enterIdleWarm();
    await h.pipeline.leaveIdleWarm();
    await expectLater(h.pipeline.sendRecordedAudio(Uint8List(4800), 'Unsent recorded question.'), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.transports, hasLength(1));
    expect(h.pipeline.autoReconnects, 0);
    expect(h.pipeline.voiceInputNeedsReconnect, isTrue);

    h.nextCallError = StateError('fixture fresh connection failed');
    await h.pipeline.reconnect();
    expect(h.transports, hasLength(2));
    expect(h.transports.last.closed, isTrue);
    expect(h.pipeline.status, SessionStatus.error);
    expect(h.pipeline.voiceInputNeedsReconnect, isTrue, reason: 'Failed explicit recovery cannot clear the latch.');
    expect(await h.pipeline.sendText(draft, displayText: draft), isFalse);
    await h.pipeline.connect();
    recording.start();
    await waitFor(() => !recording.busy);
    expect(opens, 0);
    expect(h.transports, hasLength(2));

    await h.pipeline.reconnect();
    expect(h.transports, hasLength(3));
    expect(transport.closed, isTrue);
    expect(h.pipeline.status, SessionStatus.connected);
    expect(h.pipeline.voiceInputNeedsReconnect, isFalse);
    expect(h.pipeline.phase, AssistantPhase.listening);
    expect(h.transports.last.micEnabled, isTrue);
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user), isEmpty);
    expect(
      h.server.sockets.every((socket) => socket.ofType('session.context.append').isEmpty),
      isTrue,
      reason: 'Neither failed nor successful reconnect automatically replays the retained draft.',
    );
    expect(await h.pipeline.sendText(draft, displayText: draft, target: retiredTarget), isFalse);
    expect(await h.pipeline.sendText('Fresh question.', displayText: 'Fresh question.'), isTrue);
    await waitFor(() => h.server.socket.ofType('session.context.append').isNotEmpty);
    expect(h.server.socket.ofType('session.context.append'), hasLength(1));
    expect(h.pipeline.conversation.messages.where((m) => m.kind == MessageKind.user).single.text, 'Fresh question.');

    recording.start();
    await waitFor(() => opens == 1);
    await recording.cancel();
    expect(reports, hasLength(3), reason: 'Confirmed capture release restores normal held recording.');
  });

  test('late explicit reconnect cannot clear capture failure after a newer suspend', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    final transport = h.transports.single;
    transport.captureSuspendError = StateError('native capture release unconfirmed');
    h.pipeline.interrupt();
    expect(await h.pipeline.sendText('Unsent draft.', displayText: 'Unsent draft.'), isFalse);
    await waitFor(() => h.pipeline.backend == null && transport.closed);
    final gate = h.callGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final reconnecting = h.pipeline.reconnect();
    await waitFor(() => h.callAttempts == 2);
    await h.pipeline.suspend();
    gate.complete();
    await reconnecting;
    expect(h.pipeline.voiceInputNeedsReconnect, isTrue);
    expect(h.pipeline.status, SessionStatus.disconnected);
    expect(h.transports.last.closed, isTrue);
    await h.pipeline.connect();
    expect(
      h.transports,
      hasLength(2),
      reason: 'A stale successful handshake cannot authorize later automatic capture.',
    );
    await expectLater(h.pipeline.suspendForRecording(), throwsStateError);
  });
}
