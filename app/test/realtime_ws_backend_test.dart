import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/playback_tracker.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/voice/context_sync.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/fake_realtime.dart';

const _creds = Credentials(mode: AuthMode.codex, bearerToken: 'tok_secret', accountId: 'acct_1');

const _cfg = SessionConfig(
  model: 'gpt-realtime-1.5',
  voice: 'marin',
  instructions: 'Be brief.',
  tools: [
    ToolSpec(
      name: 'run_bash',
      description: 'Run a command',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
      },
    ),
  ],
);

/// 24 kHz PCM16: 48 bytes per ms.
String _audio(int ms) => base64Encode(Uint8List(ms * 48));

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Rig {
  _Rig({int keepRecentTurns = 2, int maxReconnectAttempts = 3, bool defer = false}) {
    backend = RealtimeWsBackend(
      deferInterrupts: defer,
      connector: server.connect,
      credentialsProvider: () async => _creds,
      playback: PlaybackTracker(outputLatency: Duration.zero, now: () => clock),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      maxReconnectAttempts: maxReconnectAttempts,
      connectTimeout: const Duration(seconds: 2),
      keepRecentTurns: keepRecentTurns,
      log: logs.add,
    );
    sub = backend.events.listen(events.add);
  }

  final server = FakeRealtimeServer();
  final events = <BackendEvent>[];
  final logs = <String>[];
  DateTime clock = DateTime(2026, 1, 1, 12);
  late final RealtimeWsBackend backend;
  late final StreamSubscription<BackendEvent> sub;

  FakeSocket get ws => server.last;

  Future<void> connect([SessionConfig cfg = _cfg]) async {
    await backend.connect(cfg);
    await _pump();
  }

  void advance(int ms) => clock = clock.add(Duration(milliseconds: ms));

  List<T> of<T>() => events.whereType<T>().toList();

  void respond(String id) => ws.push({
    'type': 'response.created',
    'response': {'id': id, 'status': 'in_progress'},
  });

  void audioItem(String resp, String item, int ms) {
    ws.addItem({'id': item, 'type': 'message', 'role': 'assistant', 'status': 'in_progress'});
    ws.push({'type': 'response.output_audio.delta', 'response_id': resp, 'item_id': item, 'delta': _audio(ms)});
  }

  void done(String id, {String status = 'completed', List<Object?> output = const [], Map<String, Object?>? usage}) =>
      ws.push({
        'type': 'response.done',
        'response': {'id': id, 'status': status, 'output': output, 'usage': ?usage},
      });

  void userTurn(String id, [String text = '']) {
    ws.addItem({
      'id': id,
      'type': 'message',
      'role': 'user',
      'status': 'completed',
      'content': [
        {'type': 'input_audio', 'transcript': null},
      ],
    });
    if (text.isNotEmpty) {
      ws.push({'type': 'conversation.item.input_audio_transcription.completed', 'item_id': id, 'transcript': text});
    }
  }

  Future<void> dispose() async {
    await backend.close();
    await sub.cancel();
  }
}

void main() {
  group('RealtimeWsBackend handshake', () {
    test('connects with model query + Codex headers and sends session.update', () async {
      final r = _Rig();
      await r.connect();
      expect(r.backend.isReady, isTrue);
      expect(r.ws.uri.toString(), 'wss://api.openai.com/v1/realtime?model=gpt-realtime-1.5');
      expect(r.ws.headers['Authorization'], 'Bearer tok_secret');
      expect(r.ws.headers['chatgpt-account-id'], 'acct_1');
      expect(r.ws.headers['originator'], 'codex_cli_rs');
      expect(r.ws.headers['version'], kCodexVersion);
      expect(r.ws.headers['User-Agent'], startsWith('codex_cli_rs/'));
      expect(r.ws.headers.containsKey('openai-alpha'), isFalse);

      final upd = r.ws.ofType('session.update').single['session'] as Map;
      expect(upd['type'], 'realtime');
      expect(upd['instructions'], 'Be brief.');
      final input = (upd['audio'] as Map)['input'] as Map;
      expect((input['turn_detection'] as Map)['type'], 'server_vad');
      expect((input['turn_detection'] as Map)['interrupt_response'], isTrue);
      expect((input['transcription'] as Map)['model'], 'gpt-4o-mini-transcribe');
      expect(((upd['audio'] as Map)['output'] as Map)['voice'], 'marin');
      final tools = upd['tools'] as List;
      expect(tools.single, containsPair('name', 'run_bash'));
      expect(tools.single, containsPair('type', 'function'));
      // Logs never contain the token.
      expect(r.logs.join('\n'), isNot(contains('tok_secret')));
      await r.dispose();
    });

    test('injects priorContext as a system item', () async {
      final r = _Rig();
      await r.connect(const SessionConfig(model: 'm', voice: 'v', instructions: 'i', priorContext: 'User likes tea.'));
      final create = r.ws.ofType('conversation.item.create').single['item'] as Map;
      expect(create['role'], 'system');
      expect(jsonEncode(create), contains('User likes tea.'));
      await r.dispose();
    });

    test('handshake error is thrown and not retried', () async {
      final r = _Rig();
      r.server.connectErrorCode = 'invalid_api_key';
      await expectLater(r.backend.connect(_cfg), throwsA(isA<RealtimeException>()));
      expect(r.server.sockets, hasLength(1));
      await r.dispose();
    });
  });

  group('streaming', () {
    test('audio in, transcripts and audio out, usage', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendAudio(Uint8List(960));
      final app = r.ws.ofType('input_audio_buffer.append').single;
      expect(base64Decode(app['audio'] as String), hasLength(960));

      r.ws.push({'type': 'input_audio_buffer.speech_started', 'item_id': 'u1'});
      r.ws.push({'type': 'input_audio_buffer.speech_stopped', 'item_id': 'u1'});
      r.ws.push({'type': 'conversation.item.input_audio_transcription.delta', 'item_id': 'u1', 'delta': 'hel'});
      r.ws.push({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'transcript': 'hello',
      });
      r.respond('r1');
      r.audioItem('r1', 'a1', 100);
      r.ws.push({
        'type': 'response.output_audio_transcript.delta',
        'response_id': 'r1',
        'item_id': 'a1',
        'delta': 'Hi',
      });
      r.ws.push({
        'type': 'response.output_audio_transcript.done',
        'response_id': 'r1',
        'item_id': 'a1',
        'transcript': 'Hi',
      });
      r.done('r1', usage: {'input_tokens': 120, 'output_tokens': 30});
      await _pump();

      expect(r.of<SpeechStarted>(), hasLength(1));
      expect(r.of<SpeechStopped>(), hasLength(1));
      expect(r.of<UserTranscriptDelta>().single.text, 'hel');
      expect(r.of<UserTranscriptDone>().single.text, 'hello');
      // item_id ties speech and (late) transcription to one user turn.
      expect(r.of<SpeechStarted>().single.itemId, 'u1');
      expect(r.of<UserTranscriptDelta>().single.itemId, 'u1');
      expect(r.of<UserTranscriptDone>().single.itemId, 'u1');
      expect(r.of<AssistantAudioDelta>().single.pcm16, hasLength(4800));
      expect(r.of<AssistantTranscriptDelta>().single.text, 'Hi');
      expect(r.of<AssistantTranscriptDone>().single.text, 'Hi');
      final u = r.of<Usage>().single;
      expect([u.inputTokens, u.outputTokens, u.totalContextTokens], [120, 30, 150]);
      expect(r.of<ResponseDone>().single.cancelled, isFalse);
      await r.dispose();
    });

    test('probeSpan transcribes a clip on its own: not a turn, deleted after', () async {
      final r = _Rig(defer: true);
      await r.connect();
      expect(r.backend.probeSpan(Uint8List(48 * 1200)), isTrue);
      final sent = r.ws.sent.map((e) => e['type']).toList();
      final i = sent.indexOf('input_audio_buffer.clear');
      expect(i, greaterThanOrEqualTo(0));
      expect(sent.sublist(i), ['input_audio_buffer.clear', 'input_audio_buffer.append', 'input_audio_buffer.commit']);
      expect(base64Decode(r.ws.ofType('input_audio_buffer.append').last['audio'] as String), hasLength(48 * 1200));
      r.ws.push({'type': 'input_audio_buffer.committed', 'item_id': 'p1'});
      r.ws.addItem({
        'id': 'p1',
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_audio', 'transcript': null},
        ],
      });
      r.ws.push({'type': 'conversation.item.input_audio_transcription.delta', 'item_id': 'p1', 'delta': 'St'});
      r.ws.push({'type': 'conversation.item.input_audio_transcription.completed', 'item_id': 'p1', 'transcript': ' Stop. '});
      await _pump();
      expect(r.of<ProbeTranscript>().single.text, 'Stop.');
      expect(r.of<UserTranscriptDelta>(), isEmpty);
      expect(r.of<UserTranscriptDone>(), isEmpty);
      expect(r.of<SpeechStarted>(), isEmpty);
      expect(r.ws.ofType('conversation.item.delete').single['item_id'], 'p1');
      await r.dispose();
    });

    test('probeSpan: an empty-buffer error ends the probe quietly', () async {
      final r = _Rig();
      await r.connect();
      expect(r.backend.probeSpan(Uint8List(48 * 50)), isFalse, reason: 'too short to transcribe');
      expect(r.backend.probeSpan(Uint8List(48 * 600)), isTrue);
      r.ws.push({
        'type': 'error',
        'error': {'type': 'invalid_request_error', 'code': 'input_audio_buffer_commit_empty', 'message': 'empty'},
      });
      await _pump();
      expect(r.of<ProbeTranscript>().single.text, '');
      expect(r.of<BackendError>(), isEmpty);
      await r.dispose();
    });

    test('sendImage adds input_image without creating a response', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendImage(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), note: 'screen');
      final item = r.ws.ofType('conversation.item.create').single['item'] as Map;
      final content = item['content'] as List;
      expect((content[0] as Map)['type'], 'input_image');
      expect((content[0] as Map)['image_url'], startsWith('data:image/png;base64,'));
      expect((content[1] as Map)['text'], 'screen');
      expect(r.ws.ofType('response.create'), isEmpty);
      await r.dispose();
    });

    test('sendText creates an item and a response', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendText('hi');
      expect(r.ws.types.skip(1), ['conversation.item.create', 'response.create']);
      await r.dispose();
    });
  });

  group('tool calls', () {
    test('function call round trip: output then response.create after response.done', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.ws.push({
        'type': 'response.function_call_arguments.done',
        'response_id': 'r1',
        'item_id': 'fc1',
        'call_id': 'call_1',
        'name': 'run_bash',
        'arguments': '{"command":"ls ~"}',
      });
      await _pump();
      final call = r.of<ToolCall>().single;
      expect([call.callId, call.name, call.argsJson], ['call_1', 'run_bash', '{"command":"ls ~"}']);

      // Result arrives while the response is still active: no response.create yet.
      r.backend.sendToolResult('call_1', '{"ok":true}');
      final out = r.ws.ofType('conversation.item.create').last['item'] as Map;
      expect(out, {'type': 'function_call_output', 'call_id': 'call_1', 'output': '{"ok":true}'});
      expect(r.ws.ofType('response.create'), isEmpty);

      // response.done output repeats the call: not emitted twice.
      r.done(
        'r1',
        output: [
          {'type': 'function_call', 'call_id': 'call_1', 'name': 'run_bash', 'arguments': '{}'},
        ],
      );
      await _pump();
      expect(r.of<ToolCall>(), hasLength(1));
      expect(r.ws.ofType('response.create'), hasLength(1));
      expect(r.backend.responseActive, isTrue);
      await r.dispose();
    });

    test('waits for all pending calls before creating a response', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.done(
        'r1',
        output: [
          {'type': 'function_call', 'call_id': 'a', 'name': 'run_bash', 'arguments': '{}'},
          {'type': 'function_call', 'call_id': 'b', 'name': 'run_bash', 'arguments': '{}'},
        ],
      );
      await _pump();
      expect(r.of<ToolCall>().map((c) => c.callId), ['a', 'b']);
      r.backend.sendToolResult('a', '{}');
      expect(r.ws.ofType('response.create'), isEmpty);
      r.backend.sendToolResult('b', '{}');
      expect(r.ws.ofType('response.create'), hasLength(1));
      await r.dispose();
    });

    test('dropEchoTurn: cancels the reply, closes its calls unrun, deletes the user item, no new response', () async {
      final r = _Rig();
      await r.connect();
      r.userTurn('u1', 'Boiner moot.');
      r.respond('r1');
      r.done(
        'r1',
        output: [
          {'type': 'function_call', 'call_id': 'c1', 'name': 'run_bash', 'arguments': '{}'},
        ],
      );
      await _pump();
      expect(r.of<ToolCall>().single.callId, 'c1');
      r.backend.dropEchoTurn(itemId: 'u1', callIds: ['c1']);
      final out = r.ws.ofType('conversation.item.create').last['item'] as Map;
      expect(out['type'], 'function_call_output');
      expect(out['call_id'], 'c1');
      expect(out['output'] as String, contains('echo'));
      expect(r.ws.ofType('conversation.item.delete').single['item_id'], 'u1');
      expect(r.ws.ofType('response.create'), isEmpty);
      // The next real turn is answered (the calls no longer block it).
      r.backend.sendText('hello');
      expect(r.ws.ofType('response.create'), hasLength(1));
      await r.dispose();
    });

    test('conversation_already_has_active_response defers and retries', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendText('x');
      r.ws.push({
        'type': 'error',
        'error': {'code': 'conversation_already_has_active_response', 'message': 'busy'},
      });
      r.respond('r_vad');
      r.done('r_vad');
      await _pump();
      expect(r.ws.ofType('response.create'), hasLength(2));
      expect(r.of<BackendError>(), isEmpty);
      await r.dispose();
    });
  });

  group('interruption', () {
    test('defer mode: far_field; while Woi speaks the server neither cuts nor answers; the client decides', () async {
      final r = _Rig(defer: true);
      await r.connect();
      final first = r.ws.ofType('session.update').first['session'] as Map;
      final input = (first['audio'] as Map)['input'] as Map;
      expect((input['noise_reduction'] as Map)['type'], 'far_field');
      expect((input['turn_detection'] as Map)['interrupt_response'], isTrue);
      r.respond('r1');
      await _pump();
      final upd = r.ws.ofType('session.update').last['session'] as Map;
      final td = ((upd['audio'] as Map)['input'] as Map)['turn_detection'] as Map;
      expect(td['interrupt_response'], isFalse);
      expect(td['create_response'], isFalse);
      r.ws.push({'type': 'session.updated', 'session': upd});
      r.audioItem('r1', 'a1', 3000);
      await _pump();
      // Echo: deferred, not cut; dropped without cancelling the reply.
      r.ws.push({'type': 'input_audio_buffer.speech_started', 'item_id': 'u1'});
      await _pump();
      expect(r.of<SpeechStarted>().single.deferred, isTrue);
      expect(r.ws.ofType('response.cancel'), isEmpty);
      r.userTurn('u1', 'Boiner moot.');
      r.ws.push({'type': 'input_audio_buffer.speech_stopped', 'item_id': 'u1'});
      await _pump();
      r.backend.dropEchoTurn(itemId: 'u1');
      expect(r.ws.ofType('response.cancel'), isEmpty);
      expect(r.ws.ofType('conversation.item.delete').single['item_id'], 'u1');
      // The user: accepted, Woi cut (cancelResponse), answered after it ends.
      r.ws.push({'type': 'input_audio_buffer.speech_started', 'item_id': 'u2'});
      await _pump();
      expect(r.of<SpeechStarted>().last.deferred, isTrue);
      r.backend.cancelResponse();
      r.backend.acceptTurn();
      expect(r.ws.ofType('response.cancel'), hasLength(1));
      r.done('r1', status: 'cancelled');
      r.userTurn('u2', 'Stop.');
      r.ws.push({'type': 'input_audio_buffer.speech_stopped', 'item_id': 'u2'});
      await _pump();
      expect(r.ws.ofType('response.create'), hasLength(1));
      await r.dispose();
    });

    test('speech_started stops playback; truncate with played ms after the cancelled response.done', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.audioItem('r1', 'a1', 3000); // generated 3 s at once (faster than real time)
      await _pump();
      r.advance(1200); // user heard 1.2 s
      r.ws.push({'type': 'input_audio_buffer.speech_started'});
      await _pump();
      expect(r.ws.ofType('conversation.item.truncate'), isEmpty, reason: 'must wait for response.done');
      // Late audio for the interrupted response is dropped.
      r.ws.push({'type': 'response.output_audio.delta', 'response_id': 'r1', 'item_id': 'a1', 'delta': _audio(100)});
      r.ws.push({'type': 'response.output_audio_transcript.delta', 'response_id': 'r1', 'item_id': 'a1', 'delta': 'x'});
      r.done('r1', status: 'cancelled');
      await _pump();
      final t = r.ws.ofType('conversation.item.truncate').single;
      expect(t['item_id'], 'a1');
      expect(t['content_index'], 0);
      expect(t['audio_end_ms'], 1200);
      expect(r.of<AssistantAudioDelta>(), hasLength(1));
      expect(r.of<AssistantTranscriptDelta>(), isEmpty);
      expect(r.of<ResponseDone>().single.cancelled, isTrue);
      expect(r.backend.truncationsSent, 1);
      await r.dispose();
    });

    test('completed response still playing: truncate is sent immediately', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.audioItem('r1', 'a1', 2000);
      r.done('r1');
      await _pump();
      r.advance(500);
      r.ws.push({'type': 'input_audio_buffer.speech_started'});
      await _pump();
      expect(r.ws.ofType('conversation.item.truncate').single['audio_end_ms'], 500);
      expect(r.ws.ofType('response.cancel'), isEmpty);
      await r.dispose();
    });

    test('fully played audio is not truncated', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.audioItem('r1', 'a1', 300);
      r.done('r1');
      await _pump();
      r.advance(1000);
      r.ws.push({'type': 'input_audio_buffer.speech_started'});
      await _pump();
      expect(r.ws.ofType('conversation.item.truncate'), isEmpty);
      await r.dispose();
    });

    test('cancelResponse sends response.cancel once and ignores response_cancel_not_active', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.audioItem('r1', 'a1', 1000);
      await _pump();
      r.advance(250);
      r.backend.cancelResponse();
      r.backend.cancelResponse();
      expect(r.ws.ofType('response.cancel'), hasLength(1));
      r.ws.push({
        'type': 'error',
        'error': {'code': 'response_cancel_not_active', 'message': 'no active response'},
      });
      r.done('r1', status: 'cancelled');
      await _pump();
      expect(r.of<BackendError>(), isEmpty);
      expect(r.ws.ofType('conversation.item.truncate').single['audio_end_ms'], 250);
      await r.dispose();
    });

    test('cancel before response.created cancels on create', () async {
      final r = _Rig();
      await r.connect();
      r.backend.sendText('hi');
      r.backend.cancelResponse();
      expect(r.ws.ofType('response.cancel'), isEmpty);
      r.respond('r2');
      expect(r.ws.ofType('response.cancel'), hasLength(1));
      r.ws.push({'type': 'response.output_audio.delta', 'response_id': 'r2', 'item_id': 'a2', 'delta': _audio(50)});
      await _pump();
      expect(r.of<AssistantAudioDelta>(), isEmpty);
      await r.dispose();
    });

    test('no response.create while the user is speaking', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.done(
        'r1',
        output: [
          {'type': 'function_call', 'call_id': 'c', 'name': 'run_bash', 'arguments': '{}'},
        ],
      );
      await _pump();
      r.ws.push({'type': 'input_audio_buffer.speech_started'});
      await _pump();
      r.backend.sendToolResult('c', '{}');
      expect(r.ws.ofType('response.create'), isEmpty);
      r.ws.push({'type': 'input_audio_buffer.speech_stopped'});
      await _pump();
      // The tool output is still owed a response; the VAD response covers it if it comes first.
      r.respond('r_vad');
      r.done('r_vad');
      await _pump();
      expect(r.ws.ofType('response.create').length, lessThanOrEqualTo(1));
      await r.dispose();
    });
  });

  group('reconnect', () {
    test('unexpected close: cancels in-flight response, reconnects and restores context', () async {
      final r = _Rig();
      await r.connect();
      r.userTurn('u1', 'my name is Alice');
      r.respond('r1');
      await _pump();
      await r.ws.drop();
      await waitUntil(() => r.server.sockets.length == 2 && r.backend.isReady);
      await _pump();
      expect(r.of<ResponseDone>().single.cancelled, isTrue);
      expect(r.of<BackendError>().single.code, 'reconnecting');
      expect(r.backend.reconnects, 1);
      final restored = r.ws.ofType('conversation.item.create').single['item'] as Map;
      expect(restored['role'], 'system');
      expect(jsonEncode(restored), contains('my name is Alice'));
      await r.dispose();
    });

    test('tool result for a call from the old socket is sent as context', () async {
      final r = _Rig();
      await r.connect();
      r.respond('r1');
      r.done(
        'r1',
        output: [
          {'type': 'function_call', 'call_id': 'old', 'name': 'run_bash', 'arguments': '{}'},
        ],
      );
      await _pump();
      await r.ws.drop();
      await waitUntil(() => r.server.sockets.length == 2 && r.backend.isReady);
      r.backend.sendToolResult('old', '{"stdout":"hi"}');
      final item = r.ws.ofType('conversation.item.create').last['item'] as Map;
      expect(item['type'], 'message');
      expect(item['role'], 'system');
      expect(jsonEncode(item), contains('run_bash'));
      expect(r.ws.ofType('response.create'), hasLength(1));
      await r.dispose();
    });

    test('the 60-minute session cap is not fatal: reconnects with the context', () async {
      final r = _Rig();
      await r.connect();
      r.userTurn('u1', 'my name is Alice');
      await _pump();
      r.ws.push({
        'type': 'error',
        'error': {'type': 'invalid_request_error', 'code': 'session_expired', 'message': 'Your session hit the maximum duration of 60 minutes.'},
      });
      await waitUntil(() => r.server.sockets.length == 2 && r.backend.isReady);
      await _pump();
      expect(r.of<BackendError>().where((e) => e.fatal), isEmpty);
      expect(r.backend.reconnects, 1);
      expect(jsonEncode(r.ws.ofType('conversation.item.create')), contains('my name is Alice'));
      await r.dispose();
    });

    test('gives up after maxReconnectAttempts with a fatal error', () async {
      final r = _Rig(maxReconnectAttempts: 2);
      await r.connect();
      r.server.connectErrorCode = 'server_error';
      await r.ws.drop();
      await waitUntil(() => r.of<BackendError>().any((e) => e.fatal));
      expect(r.of<BackendError>().last.code, 'reconnect_failed');
      await r.dispose();
    });
  });

  group('screenshot tiers', () {
    test('sendImage names the item; replaceImage swaps it in place between responses', () async {
      final r = _Rig();
      await r.connect();
      r.userTurn('u1', 'look');
      final id = r.backend.sendImage(Uint8List.fromList(List.filled(32, 1)), note: 'shot')!;
      expect(id, startsWith('woi_img_'));
      r.userTurn('u2', 'next');
      await _pump();
      expect(r.backend.serverItemIds, ['u1', id, 'u2']);
      r.respond('r1');
      final small = r.backend.replaceImage(id, png: Uint8List.fromList(List.filled(8, 2)), text: '1/5 size');
      await _pump();
      expect(r.ws.ofType('conversation.item.delete'), isEmpty, reason: 'waits for the response to finish');
      r.done('r1');
      final newId = await small;
      expect(newId, isNot(id));
      final create = r.ws.ofType('conversation.item.create').last;
      expect(create['previous_item_id'], id);
      expect(jsonEncode(create), contains('input_image'));
      expect(r.ws.ofType('conversation.item.delete').single['item_id'], id);
      expect(r.backend.serverItemIds, ['u1', newId, 'u2']);
      // Then to a description: a system note, so it is not taken for a user turn.
      final described = await r.backend.replaceImage(newId!, text: 'A terminal.');
      final note = r.ws.ofType('conversation.item.create').last;
      expect((note['item'] as Map)['role'], 'system');
      expect(jsonEncode(note), isNot(contains('input_image')));
      expect(r.backend.serverItemIds, ['u1', described, 'u2']);
      expect(r.backend.imagesReplaced, 2);
      expect(await r.backend.replaceImage('gone'), isNull);
      await r.dispose();
    });
  });

  group('applySummary', () {
    Future<_Rig> conversation({int keepRecentTurns = 2}) async {
      final r = _Rig(keepRecentTurns: keepRecentTurns);
      await r.connect();
      for (var i = 1; i <= 4; i++) {
        r.userTurn('u$i', 'turn $i');
        r.respond('r$i');
        r.audioItem('r$i', 'a$i', 10);
        r.done('r$i');
      }
      await _pump();
      return r;
    }

    test('inserts a system summary before the kept turns and deletes older items', () async {
      final r = await conversation();
      r.advance(10000);
      expect(r.backend.serverItemIds, ['u1', 'a1', 'u2', 'a2', 'u3', 'a3', 'u4', 'a4']);
      final res = await r.backend.applySummary('Facts: user is Alice.');
      expect(res.method, ContextApplyMethod.deletedItems);
      expect(res.removedItems, 4);
      final create = r.ws.ofType('conversation.item.create').last;
      expect(create['previous_item_id'], 'a2');
      expect((create['item'] as Map)['role'], 'system');
      expect(r.ws.ofType('conversation.item.delete').map((e) => e['item_id']), ['u1', 'a1', 'u2', 'a2']);
      expect(r.backend.serverItemIds.skip(1), ['u3', 'a3', 'u4', 'a4']);
      expect(r.backend.serverItemIds.first, startsWith('woi_ctx_'));
      expect(r.ws.items, r.backend.serverItemIds);
      expect(r.backend.appliedSummary, 'Facts: user is Alice.');
      await r.dispose();
    });

    test('rule: by default the last 3 user turns stay on the server verbatim', () async {
      expect(RealtimeWsBackend(credentialsProvider: () async => _creds).keepRecentTurns, 3);
      final r = await conversation(keepRecentTurns: 3);
      final res = await r.backend.applySummary('S');
      expect(res.method, ContextApplyMethod.deletedItems);
      expect(r.ws.ofType('conversation.item.delete').map((e) => e['item_id']), ['u1', 'a1']);
      expect(r.backend.serverItemIds.skip(1), ['u2', 'a2', 'u3', 'a3', 'u4', 'a4']);
      await r.dispose();
    });

    test('waits for the active response to finish', () async {
      final r = await conversation();
      r.respond('r5');
      final fut = r.backend.applySummary('S');
      await _pump();
      expect(r.ws.ofType('conversation.item.delete'), isEmpty);
      r.done('r5');
      final res = await fut;
      expect(res.method, ContextApplyMethod.deletedItems);
      await r.dispose();
    });

    test('keeps a function_call with its output', () async {
      final r = _Rig(keepRecentTurns: 1);
      await r.connect();
      r.userTurn('u1', 'list files');
      r.respond('r1');
      final fc = {'id': 'fc', 'type': 'function_call', 'call_id': 'c1', 'name': 'run_bash', 'arguments': '{}'};
      r.ws.addItem(fc);
      r.done('r1', output: [fc]);
      await _pump();
      // The user speaks while the tool runs: the output lands after their turn.
      r.userTurn('u2', 'thanks');
      r.backend.sendToolResult('c1', '{}');
      await _pump();
      r.respond('r2');
      r.done('r2');
      await _pump();
      expect(r.backend.serverItemIds.take(3), ['u1', 'fc', 'u2']);
      final res = await r.backend.applySummary('S');
      expect(res.method, ContextApplyMethod.deletedItems);
      expect(r.ws.ofType('conversation.item.delete').map((e) => e['item_id']), ['u1']);
      await r.dispose();
    });

    test('falls back to reconnecting with the summary when delete fails', () async {
      final r = await conversation();
      r.server.failDeletes = true;
      final res = await r.backend.applySummary('Facts: user is Alice.');
      expect(res.method, ContextApplyMethod.reconnected);
      expect(r.server.sockets, hasLength(2));
      final ctx = jsonEncode(r.ws.ofType('conversation.item.create').single);
      expect(ctx, contains('user is Alice'));
      expect(ctx, contains('turn 4'));
      expect(ctx, isNot(contains('turn 1')));
      await r.dispose();
    });
  });
}

Future<void> waitUntil(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
