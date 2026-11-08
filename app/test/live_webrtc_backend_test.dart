import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart' show kAssistantInstructions, kLiveInstructions;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/context_sync.dart';
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
      transportFactory: () {
        if (_made++ > 0) rtcs.add(FakeLiveTransport());
        return rtcs.last;
      },
      sideband: server.connect,
      createCall: server.createCall,
      delegationModelFactory: (_) => model,
      swapQuiet: const Duration(milliseconds: 60),
      swapPoll: const Duration(milliseconds: 10),
    );
    sub = backend.events.listen(events.add);
  }

  /// One transport per call (a compaction swap creates a second one).
  final rtcs = [FakeLiveTransport()];
  int _made = 0;
  FakeLiveTransport get rtc => rtcs.last;
  final server = FakeLiveServer();
  final FakeDelegationModel model;
  late final LiveWebRtcBackend backend;
  final events = <BackendEvent>[];
  late final StreamSubscription<BackendEvent> sub;

  FakeSideband get ws => server.socket;

  Future<void> connect({String model = 'gpt-live-1.1', String voice = 'cove', Credentials? creds = _creds}) => backend
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
      await r.connect(voice: 'cove', model: 'gpt-live-1.1');
      final (uri, headers, body) = r.server.calls.single;
      expect(uri.path, '/backend-api/codex/realtime/calls');
      expect(uri.queryParameters, {'intent': 'quicksilver', 'architecture': 'avas'});
      expect(headers['openai-alpha'], 'quicksilver=v2');
      expect(headers['Authorization'], 'Bearer tok_secret');
      expect(headers['chatgpt-account-id'], 'acct_1');
      expect(body['sdp'], startsWith('v=0'));
      final session = body['session']! as Map;
      // The selected valid model and voice reach the request unchanged.
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

    test('forwards an explicit custom live model without replacing it', () async {
      final r = _Rig();
      await r.connect(model: 'tenant-audio-current', voice: 'juniper');
      final session = r.server.calls.single.$3['session']! as Map;
      expect(session['model'], 'tenant-audio-current');
      expect((session['audio'] as Map)['output'], {'voice': 'juniper'});
      expect(r._made, 1);
      await r.dispose();
    });

    test('unsupported voices fail before transport or microphone creation', () async {
      for (final voice in ['marin', 'echo', 'unlisted-voice', ' ']) {
        final r = _Rig();
        await expectLater(
          r.connect(voice: voice),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('voice'))),
        );
        expect(r._made, 0, reason: voice);
        expect(r.server.calls, isEmpty);
        expect(r.rtc.micAtOffer, isNull);
        expect(r.rtc.captureSuspensions, isEmpty);
        await r.dispose();
        await r.rtc.close(); // This test intentionally never hands the fixture to the backend.
      }
    });

    test('empty or known-realtime models fail before opening the live transport', () async {
      for (final model in ['', '  ', 'gpt-realtime-2.1']) {
        final r = _Rig();
        await expectLater(
          r.connect(model: model),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('audio model'))),
        );
        expect(r._made, 0, reason: model);
        expect(r.server.calls, isEmpty);
        expect(r.rtc.micAtOffer, isNull);
        await r.dispose();
        await r.rtc.close();
      }
    });

    test('provider rejection of a custom model stays visible without a fallback request', () async {
      final requests = <Map<String, Object?>>[];
      final rtc = FakeLiveTransport();
      var transports = 0;
      final backend = LiveWebRtcBackend(
        transportFactory: () {
          transports++;
          return rtc;
        },
        createCall: (uri, headers, body) async {
          requests.add(body);
          throw LiveCallException('requested model is unavailable', status: 404);
        },
      );
      await expectLater(
        backend.connect(
          const SessionConfig(model: 'tenant-audio-unavailable', voice: 'cove', instructions: '', credentials: _creds),
        ),
        throwsA(
          isA<LiveCallException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', contains('requested model')),
        ),
      );
      expect((requests.single['session']! as Map)['model'], 'tenant-audio-unavailable');
      expect(transports, 1);
      await backend.close();
      expect(rtc.closed, isTrue);
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

    test('user turn key: VAD pauses merge, late transcript keeps its key, false starts close', () async {
      final r = _Rig();
      await r.connect();
      final ws = r.ws;
      // Local VAD opens the turn, pauses, resumes: same key.
      ws.micEcho(pcm(500));
      ws.micEcho(pcm(400, amplitude: 8000));
      await _tick();
      ws.micEcho(pcm(800));
      await _tick();
      ws.micEcho(pcm(400, amplitude: 8000));
      await _tick();
      ws.micEcho(pcm(800));
      await _tick();
      final starts = r.of<SpeechStarted>();
      expect(starts, hasLength(2));
      expect(starts[1].itemId, starts[0].itemId);
      final key = starts[0].itemId!;
      ws.turn('created', 'user', 500, 0, '');
      ws.inputWords('open the', 600);
      await _tick();
      expect(r.of<UserTranscriptDelta>().single.itemId, key);
      // Assistant answers before the user turn is finalized.
      ws.outputWords('Sure.', 2000);
      ws.turn('created', 'assistant', 2000, 0, 'Sure.');
      await _tick();
      ws.turn('done', 'user', 500, 1900, 'Open the file.');
      await _tick();
      final done = r.of<UserTranscriptDone>().single;
      expect(done.itemId, key);
      expect(done.text, 'Open the file.');
      // A VAD false start that the server never turns into a user turn is
      // closed (noSpeech) when the assistant takes the floor.
      ws.turn('done', 'assistant', 2000, 2400, 'Sure.');
      await _tick(700);
      ws.micEcho(pcm(400, amplitude: 8000));
      await _tick();
      final falseKey = r.of<SpeechStarted>().last.itemId;
      expect(falseKey, isNot(key));
      ws.outputWords('Anything else?', 3000);
      await _tick();
      final closed = r.of<UserTranscriptDone>().last;
      expect(closed.itemId, falseKey);
      expect(closed.noSpeech, isTrue);
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

    for (final suppression in ['barge-in', 'reply suppression', 'echo suppression']) {
      test('$suppression silences active narration without cancelling pending background work', () async {
        final r = _Rig(
          turns: [
            DelegationModelTurn(
              text: '',
              calls: [
                call('run_bash', {'command': 'fixture-one'}, id: 'first-work'),
                call('run_bash', {'command': 'fixture-two'}, id: 'queued-work'),
              ],
            ),
          ],
        );
        addTearDown(r.dispose);
        await r.connect();
        r.ws.delegation('pending-work', 'Run the two prepared fixture commands.');
        await waitFor(() => r.of<ToolCall>().length == 1);
        r.ws.outputWords('The work is still running.', 200);
        r.ws.audio(200, pcm(200, amplitude: 4000));
        await waitFor(() => r.of<AssistantTranscriptDelta>().isNotEmpty && r.rtc.speakerEnabled);
        switch (suppression) {
          case 'barge-in':
            r.backend.cancelResponse();
            r.backend.sendText('Thanks for the update');
          case 'reply suppression':
            r.backend.stopAndDrop();
          case 'echo suppression':
            r.backend.dropEchoTurn(itemId: 'echo-turn');
        }
        expect(r.rtc.speakerEnabled, isFalse, reason: 'speech still stops immediately');
        final first = r.of<ToolCall>().single;
        r.backend.sendToolResult(first.callId, '{"ok":true}');
        await waitFor(() => r.of<ToolCall>().length > 1 || r.ws.ofType('delegation.context.append').isNotEmpty);
        expect(r.of<ToolCall>(), hasLength(2), reason: 'the existing task keeps its queued continuation');
        r.backend.sendToolResult(r.of<ToolCall>().last.callId, '{"ok":true}');
        await waitFor(() => r.ws.ofType('delegation.context.append').isNotEmpty);
        expect(jsonEncode(r.ws.ofType('delegation.context.append').single), isNot(contains('cancelled')));
        expect(r.model.requests, hasLength(1), reason: 'no model retry or replacement task');
        if (suppression == 'barge-in') {
          expect(jsonEncode(r.ws.ofType('session.context.append')), contains('Thanks for the update'));
        }
      });
    }

    test('explicit tool cancellation still stops queued work while narration is active', () async {
      final r = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('run_bash', {'command': 'fixture-one'}, id: 'first-work'),
              call('run_bash', {'command': 'fixture-two'}, id: 'queued-work'),
            ],
          ),
        ],
      );
      addTearDown(r.dispose);
      await r.connect();
      r.ws.delegation('pending-work', 'Run the two prepared fixture commands.');
      await waitFor(() => r.of<ToolCall>().length == 1);
      r.ws.outputWords('The work is still running.', 200);
      r.ws.audio(200, pcm(200, amplitude: 4000));
      await waitFor(() => r.of<AssistantTranscriptDelta>().isNotEmpty);
      r.backend.cancelPendingTools();
      r.backend.stopAndDrop();
      r.backend.sendToolResult(r.of<ToolCall>().single.callId, '{"ok":true}');
      await waitFor(() => r.ws.ofType('delegation.context.append').isNotEmpty);
      expect(r.of<ToolCall>(), hasLength(1));
      expect(jsonEncode(r.ws.ofType('delegation.context.append').single), contains('cancelled'));
      expect(r.rtc.speakerEnabled, isFalse);
    });

    test('typed chat becomes channel-less context (answered); errors surface', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendText('What is two plus two?');
      final ev = r.ws.ofType('session.context.append').single;
      expect(ev.containsKey('channel'), isFalse, reason: "the 'developer' channel gets no reply");
      expect(jsonEncode(ev['content']), contains('What is two plus two?'));
      expect(r.model.requests, isEmpty, reason: 'not an action: no executor run');
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

  group('typed actions and stop', () {
    test('typed action runs the executor; the model voices the real result', () async {
      final r = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('run_bash', {'command': 'ls ~'}),
            ],
          ),
          DelegationModelTurn(text: 'Listed 3 entries.', calls: const []),
        ],
      );
      await r.connect();
      r.backend.sendText('Run ls in my home folder');
      await waitFor(() => r.of<ToolCall>().isNotEmpty);
      expect(r.ws.ofType('session.context.append'), isEmpty, reason: 'nothing claimed before the result');
      r.backend.sendToolResult(r.of<ToolCall>().single.callId, '{"ok":false,"error":"permission denied"}');
      await waitFor(() => r.ws.ofType('session.context.append').isNotEmpty);
      final ev = r.ws.ofType('session.context.append').single;
      expect(ev.containsKey('channel'), isFalse);
      final text = jsonEncode(ev['content']);
      expect(text, contains('Run ls in my home folder'));
      expect(text, contains('already carried it out'));
      expect(text, contains('failed'));
      expect(r.model.requests.first.input.toString(), contains('Run ls in my home folder'));
      await r.dispose();
    });

    test('delegation result note flags failures and forbids repeated filler', () {
      final ok = DelegationReport(id: 'a', request: 'x')..resultText = 'Done. show_file(path="README.md") -> ok';
      final bad = DelegationReport(id: 'b', request: 'x')..resultText = 'Not fully done. run_bash(...) -> error';
      expect(LiveWebRtcBackend.delegationResultNote(ok), isNot(contains('NOT')));
      expect(LiveWebRtcBackend.delegationResultNote(bad), contains('did NOT fully succeed'));
      expect(LiveWebRtcBackend.delegationResultNote(bad), contains('Do not repeat'));
    });

    test('assistant identity is Woi', () {
      expect(kAssistantInstructions, contains('Your name is Woi'));
      expect(kAssistantInstructions, contains('Never call yourself ChatGPT, Aurora'));
      expect(kLiveInstructions, contains('every time'));
    });

    test('looksLikeAction', () {
      for (final t in [
        'Open the file notes.txt',
        'please run ls',
        'Can you click the OK button?',
        'type hello world',
        'Show me README.md',
        'take a screenshot',
      ]) {
        expect(looksLikeAction(t), isTrue, reason: t);
      }
      for (final t in ['What is two plus two?', 'Hello, how are you?', 'Tell me a joke', 'Why is the sky blue?']) {
        expect(looksLikeAction(t), isFalse, reason: t);
      }
    });

    test('stopAndDrop mutes, hides the answer to "stop" and declines its delegations', () async {
      final r = _Rig();
      await r.connect();
      r.ws.outputWords('A long story', 200);
      r.ws.audio(200, pcm(200, amplitude: 4000));
      await _tick();
      r.backend.stopAndDrop();
      expect(r.rtc.speakerEnabled, isFalse);
      r.ws.turn('done', 'assistant', 200, 400, 'A long story');
      await _tick(10);
      final deltasBefore = r.of<AssistantTranscriptDelta>().length;
      // The model acknowledges the stop in a new turn: stays muted and hidden.
      r.ws.outputWords('Sure, stopping.', 900);
      r.ws.audio(900, pcm(200, amplitude: 4000));
      await _tick();
      expect(r.rtc.speakerEnabled, isFalse);
      expect(r.of<AssistantTranscriptDelta>().length, deltasBefore);
      r.ws.delegation('del_x', 'Stop the story.');
      await waitFor(() => r.ws.ofType('delegation.context.append').isNotEmpty);
      expect(jsonEncode(r.ws.ofType('delegation.context.append').single), contains('Do nothing'));
      expect(r.model.requests, isEmpty, reason: 'nothing executed');
      await r.dispose();
    });

    test('setReplyHold keeps a new turn muted until released', () async {
      final r = _Rig();
      await r.connect();
      r.backend.setReplyHold(true);
      r.ws.outputWords('Sure.', 200);
      await _tick();
      expect(r.rtc.speakerEnabled, isFalse);
      r.backend.setReplyHold(false);
      expect(r.rtc.speakerEnabled, isTrue);
      await r.dispose();
    });
  });

  test('capture suspension waits for active and prepared sessions before a context swap', () async {
    final r = _Rig();
    await r.connect();
    final active = r.rtc;
    r.server.autoStart = false;
    final swapping = r.backend.applySummary('Held recording context.');
    await waitFor(() => r.server.sockets.length == 2);
    final prepared = r.rtc;
    active.captureSuspendGate = Completer<void>();
    prepared.captureSuspendGate = Completer<void>();
    var released = false;
    final suspending = r.backend.setCaptureSuspended(true).then((_) => released = true);
    await _tick();
    expect(active.captureSuspended, isTrue);
    expect(prepared.captureSuspended, isTrue);
    expect(released, isFalse);
    active.captureSuspendGate!.complete();
    await _tick();
    expect(released, isFalse, reason: 'prepared call also owns a native input');
    prepared.captureSuspendGate!.complete();
    await suspending;
    r.ws.push({'type': 'session.started', 'session': <String, Object?>{}});
    expect((await swapping).method, ContextApplyMethod.reconnected);
    expect(prepared.captureSuspended, isTrue, reason: 'swap cannot reopen a held microphone');
    await r.backend.setCaptureSuspended(false);
    expect(prepared.captureSuspended, isFalse);
    await r.dispose();
  });

  group('compaction swap (applySummary)', () {
    String instructionsOf(_Rig r, int call) => (r.server.calls[call].$3['session']! as Map)['instructions'] as String;

    test('waits for the reply to end, prepares a muted call with summary + recent turns, then swaps', () async {
      final r = _Rig(
        turns: [const DelegationModelTurn(text: 'ok', calls: [])],
      );
      await r.connect();
      final old = r.ws;
      final oldRtc = r.rtc;
      // Assistant is speaking: nothing may happen yet.
      old.audio(200, pcm(200));
      old.outputWords('Here is', 200);
      final res = r.backend.applySummary('Facts: user is Alice.', recentTurns: 'User: hi\nAssistant: hello');
      await _tick(150);
      expect(r.server.calls, hasLength(1), reason: 'never while a reply is active');
      old.turn('done', 'assistant', 200, 400, 'Here is.');
      old.audio(400, pcm(200));
      final result = await res.timeout(const Duration(seconds: 2));
      expect(result.method, ContextApplyMethod.reconnected);
      expect(r.server.calls, hasLength(2));
      final ins = instructionsOf(r, 1);
      expect(ins, startsWith('Be brief.'));
      expect(ins, contains('Earlier in this conversation (summary):\nFacts: user is Alice.'));
      expect(ins, contains('User: hi\nAssistant: hello'));
      // Prepared muted, unmuted on the swap; the old call is closed.
      final next = r.rtc;
      expect(identical(next, oldRtc), isFalse);
      expect(next.micToggles.first, isFalse);
      expect(next.micEnabled, isTrue, reason: 'input state carried over from the old call');
      expect(next.speakerEnabled, isTrue);
      await _tick(10);
      expect(oldRtc.closed, isTrue);
      expect(old.ofType('session.close'), hasLength(1));
      expect(r.backend.callId, 'rtc_test2');
      expect(r.of<BackendError>(), isEmpty, reason: 'closing the old sideband is not an error');
      // The new call drives the turn state; delegations get the summary.
      r.ws.inputWords('and now', 300);
      await _tick();
      expect(r.of<UserTranscriptDelta>().last.text, 'and now');
      r.ws.delegation('d1', 'open the file');
      await _tick(20);
      final input = jsonEncode(r.model.requests.last.input);
      expect(input, contains('Conversation memory'));
      expect(input, contains('Facts: user is Alice.'));
      await r.dispose();
    });

    test('muted input: no call ever creates its mic track enabled (connect and prepared call)', () async {
      final r = _Rig();
      r.backend.setInputEnabled(false);
      await r.connect();
      expect(r.rtc.micAtOffer, isFalse, reason: 'Muted mode sends no mic audio while connecting');
      final res = r.backend.applySummary('Facts: x.', recentTurns: 'User: hi');
      await res.timeout(const Duration(seconds: 2));
      expect(r.rtcs, hasLength(2));
      expect(r.rtc.micAtOffer, isFalse, reason: 'a prepared call must not hear the user');
      expect(r.rtc.micEnabled, isFalse, reason: 'still muted after the swap');
      await r.dispose();
    });

    test('a turn during preparation discards the prepared call and retries', () async {
      final r = _Rig();
      await r.connect();
      final old = r.ws;
      r.server.autoStart = false;
      final res = r.backend.applySummary('S1');
      await _tick(120);
      expect(r.server.sockets, hasLength(2), reason: 'second call is being prepared');
      final prepared = r.server.sockets[1];
      // The user starts talking before the new call is ready.
      old.turn('created', 'user', 500, 0, '');
      prepared.push({'type': 'session.started', 'session': <String, Object?>{}});
      await _tick(30);
      expect(prepared.closed, isTrue, reason: 'it would miss this turn');
      expect(r.backend.callId, 'rtc_test1');
      old.turn('done', 'user', 500, 900, 'Hello.');
      r.server.autoStart = true;
      final result = await res.timeout(const Duration(seconds: 2));
      expect(result.method, ContextApplyMethod.reconnected);
      expect(r.backend.callId, 'rtc_test3');
      expect(r.of<UserTranscriptDone>().single.text, 'Hello.');
      await r.dispose();
    });

    test('close while waiting resolves as skipped', () async {
      final r = _Rig();
      await r.connect();
      r.ws.outputWords('Talking', 200);
      final res = r.backend.applySummary('S');
      await r.dispose();
      expect((await res).method, ContextApplyMethod.skipped);
      expect(r.server.calls, hasLength(1));
    });
  });

  group('iter6: settle and drops', () {
    test(
      'a result the model never voices settles the turn (ResponseDone); a voiced one does not double-settle',
      () async {
        final r = _Rig();
        r.backend.settleAfterResult = const Duration(milliseconds: 80);
        await r.connect();
        r.backend.sendText('thanks');
        expect(r.backend.busy, isTrue, reason: 'waiting for the model to answer');
        await waitFor(() => r.of<ResponseDone>().isNotEmpty, timeout: const Duration(seconds: 1));
        expect(r.backend.busy, isFalse);
        // Voiced: the assistant turn opens in time, so the timer does nothing extra.
        final before = r.of<ResponseDone>().length;
        r.backend.sendText('and again');
        r.ws.outputWords('Sure.', 0);
        await _tick(200);
        expect(r.of<ResponseDone>().length, lessThanOrEqualTo(before + 1));
        await r.dispose();
      },
    );

    test('an unexpected sideband close (1006) is a reconnectable connection_lost', () async {
      final r = _Rig();
      await r.connect();
      await r.ws.close(1006);
      await _tick();
      final err = r.of<BackendError>().single;
      expect(err.code, 'connection_lost');
      expect(err.fatal, isTrue);
      expect(err.message, contains('1006'));
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
    test('quiet Stop cancels queued keyboard tools and accepts the next explicit request', () async {
      final fp = await FakePlatform.create();
      final store = HistoryStore(fp.services.paths);
      await store.init();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final executions = <String>[];
      final tools = ToolRegistry()
        ..register(
          ToolDefinition(
            spec: const ToolSpec(
              name: 'send_keys',
              description: 'keyboard',
              parameters: {
                'type': 'object',
                'properties': {
                  'keys': {'type': 'string'},
                },
                'required': ['keys'],
              },
            ),
            handler: (args, _) async {
              final keys = args['keys']! as String;
              executions.add(keys);
              if (keys == 'ctrl+c') {
                firstStarted.complete();
                await releaseFirst.future;
              }
              return {'ok': true, 'delivery': 'dispatched'};
            },
          ),
        );
      final rig = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('send_keys', {'keys': 'ctrl+c'}, id: 'first-key'),
              call('send_keys', {'keys': 'ctrl+v'}, id: 'queued-key'),
            ],
          ),
        ],
      );
      final pipeline = TurnPipeline(
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
        options: () => const PipelineOptions(autoScreenshot: false),
      );
      addTearDown(() async {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
        await pipeline.shutdown();
        await rig.dispose();
        await fp.dispose();
      });
      await pipeline.start();
      await waitFor(() => pipeline.status == SessionStatus.connected);
      rig.ws.delegation('quiet-keys', 'Perform the requested keyboard task');
      await firstStarted.future.timeout(const Duration(seconds: 5));
      expect(pipeline.conversation.messages.where((m) => m.kind == MessageKind.assistant), isEmpty);
      expect(fp.audio.player.written, isEmpty);
      pipeline.interrupt();
      releaseFirst.complete();
      await waitFor(() => rig.ws.ofType('delegation.context.append').isNotEmpty);
      expect(executions, ['ctrl+c']);
      expect(jsonEncode(rig.ws.ofType('delegation.context.append').single), contains('cancelled'));
      pipeline.sendText('Ctrl+A');
      await waitFor(() => executions.length == 2);
      expect(executions, ['ctrl+c', 'Ctrl+A']);
      expect(rig.model.requests, hasLength(1), reason: 'the new explicit shortcut uses the direct path');
    });

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
      // WebRTC owns the mic; the platform mic is only a local barge-in detector.
      await waitFor(() => fp.audio.mic != null, reason: 'onset-detector mic');
      expect(fp.audio.mic!.closed, isFalse);
      expect(rig.rtc.micEnabled, isTrue);
      expect(p.context.accounting, ContextAccounting.textEstimate, reason: 'gpt-live: no usage, text context');
      expect(p.context.overheadTokens, greaterThan(ContextManager.textTokens(DelegationExecutor.instructions)));

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
