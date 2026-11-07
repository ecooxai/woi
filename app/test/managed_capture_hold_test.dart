import 'dart:async';

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

class _Harness {
  _Harness(this.platform);
  final FakePlatform platform;
  final transports = <FakeLiveTransport>[];
  final server = FakeLiveServer();
  late final TurnPipeline pipeline;

  static Future<_Harness> create() async {
    final h = _Harness(await FakePlatform.create());
    final store = HistoryStore(h.platform.services.paths);
    await store.init();
    h.pipeline = TurnPipeline(
      backendFactory: () => LiveWebRtcBackend(
        transportFactory: () {
          final transport = FakeLiveTransport();
          h.transports.add(transport);
          return transport;
        },
        sideband: h.server.connect,
        createCall: h.server.createCall,
        delegationModelFactory: (_) => FakeDelegationModel([]),
      ),
      audio: h.platform.audio,
      screen: h.platform.screen,
      tools: ToolRegistry(),
      context: ContextManager(
        compressor: StubCompressor(latency: Duration.zero),
        threshold: 100000,
      ),
      store: store,
      conversation: Conversation(),
      sessionConfig: (_) async => const SessionConfig(
        model: 'gpt-live-1.1',
        voice: 'cove',
        instructions: 'test',
        credentials: Credentials(mode: AuthMode.codex, bearerToken: 'test'),
      ),
      options: () => const PipelineOptions(
        autoScreenshot: false,
        onsetMicWithManagedAudio: false,
      ),
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
    expect(
      opens,
      0,
      reason: 'logical mute is insufficient while native teardown is pending',
    );
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

  test('failed native release prevents held capture from opening and restores listening', () async {
    final h = await _Harness.create();
    final transport = h.transports.single;
    transport.captureSuspendError = StateError(
      'native capture could not be released',
    );
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
    recording.start();
    await waitFor(() => !recording.busy);
    expect(opens, 0);
    expect(reports.single, contains('native capture could not be released'));
    expect(transport.captureSuspended, isFalse);
    expect(transport.micEnabled, isTrue);
    recording.dispose();
    await h.close();
  });
}
