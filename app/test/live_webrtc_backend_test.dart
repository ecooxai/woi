import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

const _creds = Credentials(mode: AuthMode.codex, bearerToken: 'tok_secret', accountId: 'acct_1');
const _tools = [
  ToolSpec(name: 'click_screen', description: 'click', parameters: {'type': 'object'}),
  ToolSpec(name: 'run_bash', description: 'bash', parameters: {'type': 'object'}),
];

class _Rig {
  _Rig({List<DelegationModelTurn> turns = const []}) : model = FakeDelegationModel(List.of(turns)) {
    backend = LiveWebRtcBackend(
      transportFactory: () => rtc,
      sideband: server.connect,
      createCall: server.createCall,
      delegationModelFactory: (_) => model,
    );
    sub = backend.events.listen(events.add);
  }

  final rtc = FakeLiveTransport();
  final server = FakeLiveServer();
  final FakeDelegationModel model;
  late final LiveWebRtcBackend backend;
  final events = <BackendEvent>[];
  late final StreamSubscription<BackendEvent> sub;

  FakeSideband get ws => server.socket;

  Future<void> connect({String model = 'gpt-live-1.1', String voice = 'marin', Credentials? creds = _creds}) => backend
      .connect(SessionConfig(model: model, voice: voice, instructions: 'Be brief.', tools: _tools, credentials: creds));

  List<T> of<T>() => events.whereType<T>().toList();

  Future<void> dispose() async {
    await backend.close();
    await sub.cancel();
  }
}

Future<void> _tick([int ms = 0]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('connect', () {
    test('creates the call with a valid session and opens the sideband', () async {
      final r = _Rig();
      await r.connect(voice: 'marin', model: 'gpt-realtime-1.5');
      final (uri, headers, body) = r.server.calls.single;
      expect(uri.path, '/backend-api/codex/realtime/calls');
      expect(uri.queryParameters, {'intent': 'quicksilver', 'architecture': 'avas'});
      expect(headers['openai-alpha'], 'quicksilver=v2');
      expect(headers['Authorization'], 'Bearer tok_secret');
      expect(headers['chatgpt-account-id'], 'acct_1');
      expect(body['sdp'], startsWith('v=0'));
      final session = body['session']! as Map;
      // Realtime voices / models kill the call silently: mapped to valid ones.
      expect(session['model'], 'gpt-live-1.1');
      expect((session['audio'] as Map)['output'], {'voice': 'cove'});
      expect(session['delegation'], {'type': 'client'});
      expect(session.containsKey('tools'), isFalse);
      expect(session['instructions'], 'Be brief.');

      expect(r.rtc.answer, contains('answer'));
      expect(r.ws.uri.toString(), 'wss://api.openai.com/v1/live/rtc_test1');
      expect(r.ws.headers['openai-alpha'], 'quicksilver=v2');
      expect(r.backend.callId, 'rtc_test1');
      expect(r.backend.timings.sessionStarted, isNotNull);
      await r.dispose();
      expect(r.ws.ofType('session.close'), hasLength(1));
      expect(r.rtc.closed, isTrue);
      expect(r.model.closed, isTrue);
    });

    test('keeps a valid v3 voice; rejects API-key credentials and a silent session', () async {
      final r = _Rig();
      await r.connect(voice: 'juniper');
      expect(((r.server.calls.single.$3['session']! as Map)['audio'] as Map)['output'], {'voice': 'juniper'});
      await r.dispose();

      final k = _Rig();
      await expectLater(
        k.connect(
          creds: const Credentials(mode: AuthMode.apiKey, bearerToken: 'sk'),
        ),
        throwsA(isA<StateError>()),
      );
      await k.dispose();

      final s = LiveWebRtcBackend(
        transportFactory: FakeLiveTransport.new,
        sideband: (FakeLiveServer()..autoStart = false).connect,
        createCall: FakeLiveServer().createCall,
        sessionStartTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        s.connect(const SessionConfig(model: 'gpt-live-1', voice: 'cove', instructions: '', credentials: _creds)),
        throwsA(isA<LiveCallException>()),
      );
      await s.close();
    });
  });

  group('sideband mapping', () {
    test('user and assistant turns: transcripts, speech events, audio, ResponseDone', () async {
      final r = _Rig();
      await r.connect();
      final ws = r.ws;
      // Continuous output stream (silence before the reply).
      ws.audio(200, pcm(200));
      ws.audio(400, pcm(200));
      ws.turn('created', 'user', 300, 0, '');
      ws.inputWords('click the', 350);
      ws.inputWords(' center', 650);
      await _tick();
      expect(r.of<SpeechStarted>(), hasLength(1));
      expect(r.of<UserTranscriptDelta>().map((e) => e.text).join(), 'click the center');
      expect(r.of<AssistantAudioDelta>(), isEmpty, reason: 'no assistant turn yet');

      ws.turn('done', 'user', 300, 900, 'Click the center.');
      await _tick();
      expect(r.of<SpeechStopped>(), hasLength(1));
      expect(r.of<UserTranscriptDone>().single.text, 'Click the center.');

      ws.audio(600, pcm(200, amplitude: 5000));
      ws.outputWords('On it.', 600);
      ws.audio(800, pcm(200, amplitude: 5000));
      ws.turn('created', 'assistant', 600, 0, 'On it.');
      await _tick();
      expect(r.of<AssistantTranscriptDelta>().single.text, 'On it.');
      final audio = r.of<AssistantAudioDelta>();
      expect(audio.fold<int>(0, (n, e) => n + e.pcm16.length), 400 * 48, reason: '600..1000 ms');

      ws.turn('done', 'assistant', 600, 1100, 'On it.');
      await _tick();
      expect(r.of<ResponseDone>(), isEmpty, reason: 'waits for audio through end_ms');
      ws.audio(1000, pcm(200, amplitude: 5000));
      await _tick();
      expect(r.of<AssistantTranscriptDone>().single.text, 'On it.');
      expect(r.of<ResponseDone>().single.cancelled, isFalse);
      expect(r.of<AssistantAudioDelta>().fold<int>(0, (n, e) => n + e.pcm16.length), 500 * 48);

      // Reply clip from the session timeline (§3.5).
      expect(r.backend.outputAudio(600, 1100).length, 500 * 48);
      await r.dispose();
    });

    test('assistant turn closes on a timer if the last audio never arrives', () async {
      final r = _Rig();
      await r.connect();
      r.ws.outputWords('Hi.', 200);
      r.ws.turn('done', 'assistant', 200, 900, 'Hi.');
      await _tick();
      expect(r.of<ResponseDone>(), isEmpty);
      await _tick(700);
      expect(r.of<ResponseDone>(), hasLength(1));
      await r.dispose();
    });

    test('mic echo feeds the managed mic and a local VAD', () async {
      final r = _Rig();
      await r.connect();
      final mic = await r.backend.openManagedMic();
      final chunks = <int>[];
      mic.chunks.listen((c) => chunks.add(c.length));
      r.ws.micEcho(pcm(500));
      r.ws.micEcho(pcm(400, amplitude: 8000));
      await _tick();
      await _tick();
      expect(chunks.length, 45, reason: '20 ms chunks');
      expect(r.of<SpeechStarted>(), hasLength(1));
      expect(mic.level.value, greaterThan(0.1));
      r.ws.micEcho(pcm(800));
      await _tick();
      expect(r.of<SpeechStopped>(), hasLength(1));
      await mic.close();
      expect(r.rtc.micEnabled, isFalse, reason: 'last managed mic closed');
      await r.dispose();
    });

    test('cancelResponse mutes the remote track until the next assistant turn', () async {
      final r = _Rig();
      await r.connect();
      r.ws.outputWords('A long answer', 200);
      r.ws.audio(200, pcm(200, amplitude: 4000));
      r.backend.cancelResponse();
      await _tick();
      expect(r.rtc.speakerEnabled, isFalse);
      final before = r.of<AssistantAudioDelta>().length;
      r.ws.audio(400, pcm(200, amplitude: 4000));
      await _tick();
      expect(r.of<AssistantAudioDelta>().length, before, reason: 'muted');
      r.ws.turn('done', 'assistant', 200, 600, 'A long answer');
      await _tick(10);
      await _tick();
      expect(r.of<ResponseDone>().single.cancelled, isTrue);
      r.ws.outputWords('Sure.', 800);
      await _tick();
      expect(r.rtc.speakerEnabled, isTrue);
      await r.dispose();
    });

    test('sendText becomes developer context; errors surface', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendText('open my notes');
      final ev = r.ws.ofType('session.context.append').single;
      expect(ev['channel'], 'developer');
      expect(jsonEncode(ev['content']), contains('open my notes'));
      r.ws.push({
        'type': 'error',
        'error': {'code': 'bad', 'message': 'nope'},
      });
      await _tick();
      expect(r.of<BackendError>().single.message, contains('nope'));
      r.backend.sendAudio(pcm(20, amplitude: 100)); // no-op: audio goes over RTP
      await _tick();
      expect(r.ws.sent.where((e) => '${e['type']}'.contains('audio')), isEmpty);
      await r.dispose();
    });
  });

  group('delegation', () {
    test('delegation.created → ToolCall → sendToolResult → delegation.context.append', () async {
      final r = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('click_screen', {'x': 640, 'y': 360}),
            ],
          ),
        ],
      );
      await r.connect();
      r.backend.sendImage(tinyPng(4, 4), note: 'Image is 1280x720');
      final reports = <DelegationReport>[];
      r.backend.delegations.listen(reports.add);

      r.ws.delegation('del_1', 'Click the center of the screen.');
      await waitFor(() => r.of<ToolCall>().isNotEmpty);
      final tc = r.of<ToolCall>().single;
      expect(tc.name, 'click_screen');
      expect(jsonDecode(tc.argsJson), {'x': 640, 'y': 360});
      expect(r.ws.ofType('delegation.context.append'), isEmpty);

      r.backend.sendToolResult(tc.callId, '{"ok":true,"clicked":[1280,720]}');
      await waitFor(() => r.ws.ofType('delegation.context.append').isNotEmpty);
      final app = r.ws.ofType('delegation.context.append').single;
      expect(app['delegation_item_id'], 'del_1');
      final text = ((app['content']! as List).single as Map)['text'] as String;
      expect(text, startsWith('Done. click_screen(x=640, y=360)'));

      // The model saw the screenshot and the request.
      final input = jsonEncode(r.model.requests.single.input);
      expect(input, contains('input_image'));
      expect(input, contains('Click the center'));

      r.ws.push({'type': 'delegation.context.appended', 'delegation_item_id': 'del_1'});
      r.ws.outputWords('Done.', 3000);
      await waitFor(() => reports.isNotEmpty);
      await _tick();
      expect(reports.single.appended, isNotNull);
      expect(reports.single.spoken, isNotNull);
      expect(reports.single.tools.single.ok, isTrue);
      await r.dispose();
    });

    test('close completes pending tools', () async {
      final r = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('run_bash', {'command': 'sleep 100'}),
            ],
          ),
        ],
      );
      await r.connect();
      r.backend.sendImage(tinyPng(4, 4));
      r.ws.delegation('del_2', 'run sleep');
      await waitFor(() => r.of<ToolCall>().isNotEmpty);
      await r.dispose();
    });
  });

  group('with TurnPipeline', () {
    test('pipeline uses the managed mic and routes delegated tools through the registry', () async {
      final fp = await FakePlatform.create();
      final store = HistoryStore(fp.services.paths);
      await store.init();
      final confirm = FakeConfirmations();
      late final TurnPipeline p;
      final env = ToolEnvironment(
        platform: fp.services,
        confirmations: confirm,
        delegate: StubDelegateBackend(),
        settings: () => const AppSettings(),
        onScreenshot: (s, note) => p.attachScreenshot(s, note: note),
      );
      final tools = ToolRegistry()..registerAll(builtinTools(env));
      final rig = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('run_bash', {'command': 'echo hi'}),
            ],
          ),
        ],
      );
      p = TurnPipeline(
        backendFactory: () => rig.backend,
        audio: fp.audio,
        screen: fp.screen,
        tools: tools,
        context: ContextManager(compressor: StubCompressor(latency: Duration.zero), threshold: 100000),
        store: store,
        conversation: Conversation(),
        sessionConfig: (c) async => SessionConfig(
          model: 'gpt-live-1.1',
          voice: 'cove',
          instructions: 'test',
          tools: tools.specs,
          credentials: _creds,
        ),
        options: () => const PipelineOptions(screenshotDelay: Duration(milliseconds: 50)),
        onScreenshotCaptured: (s) => env.lastScreenshot = s,
      );
      await p.start();
      await waitFor(() => p.status == SessionStatus.connected);
      expect(fp.audio.mic, isNull, reason: 'WebRTC owns the mic: no pw-record');
      expect(rig.rtc.micEnabled, isTrue);

      // User speaks (server echo) → pipeline sees speech, takes a screenshot.
      rig.ws.micEcho(pcm(500));
      rig.ws.micEcho(pcm(400, amplitude: 8000));
      await waitFor(() => p.phase == AssistantPhase.userSpeaking);
      rig.ws.inputWords('run echo hi', 300);
      rig.ws.micEcho(pcm(800));
      rig.ws.turn('done', 'user', 300, 1200, 'Run echo hi.');
      await waitFor(() => fp.screen.captureTimes.isNotEmpty);

      rig.ws.delegation('del_9', 'Run the command echo hi.');
      await waitFor(() => rig.ws.ofType('delegation.context.append').isNotEmpty);
      await _tick();
      expect(fp.shell.commands, ['echo hi']);
      expect(confirm.commandRequests, ['echo hi'], reason: 'went through the confirmation UI');
      final text = jsonEncode(rig.ws.ofType('delegation.context.append').single['content']);
      expect(text, contains('hi'));
      final toolMsgs = p.conversation.messages.where((m) => m.kind == MessageKind.tool).toList();
      expect(toolMsgs.last.tool!.name, 'run_bash');

      // Assistant speaks the result; audio feeds levels, not the platform player.
      rig.ws.outputWords('It printed hi.', 2000);
      rig.ws.audio(2000, pcm(200, amplitude: 6000));
      await _tick();
      await _tick();
      expect(fp.audio.player.written.length, 0);
      expect(p.outputLevel, isNotNull);
      rig.ws.turn('done', 'assistant', 2000, 2200, 'It printed hi.');
      await waitFor(() => p.conversation.messages.any((m) => m.kind == MessageKind.assistant && !m.streaming));
      await _tick();
      expect(p.conversation.messages.lastWhere((m) => m.kind == MessageKind.assistant).text, 'It printed hi.');

      await p.shutdown();
      await _tick(50);
      await fp.dispose();
    });
  });
}
