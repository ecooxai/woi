import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/playback_tracker.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/notes/pinned_note.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/fake_realtime.dart';
import 'fakes/live_fakes.dart';

const _creds = Credentials(mode: AuthMode.codex, bearerToken: 'tok', accountId: 'acct');

Future<void> _pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _NoCompressor implements Compressor {
  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async =>
      const CompressionResult(summary: 'S', tokensAfter: 1);
}

void main() {
  group('direct mode (Realtime WS): the note refreshes via session.update', () {
    late FakeRealtimeServer server;
    late RealtimeWsBackend backend;

    setUp(() async {
      server = FakeRealtimeServer();
      backend = RealtimeWsBackend(
        connector: server.connect,
        credentialsProvider: () async => _creds,
        playback: PlaybackTracker(outputLatency: Duration.zero),
        reconnectBaseDelay: const Duration(milliseconds: 1),
        connectTimeout: const Duration(seconds: 2),
      );
      await backend.connect(
        const SessionConfig(model: 'gpt-realtime', voice: 'marin', instructions: 'Be brief.', pinnedNote: '# Plan'),
      );
      await _pump();
    });
    tearDown(() => backend.close());

    String instructionsOf(Map<String, Object?> ev) => (ev['session'] as Map)['instructions'] as String;

    test('the handshake carries the note in the instructions', () {
      final upd = server.last.ofType('session.update').single;
      expect(instructionsOf(upd), withPinnedNote('Be brief.', '# Plan'));
    });

    test('idle edit: session.update right away, before the next response.create', () async {
      backend.setPinnedNote('# Plan\n- meeting at 3pm');
      expect(backend.pinnedRefreshes, 1);
      expect(instructionsOf(server.last.ofType('session.update').last), contains('- meeting at 3pm'));
      backend.setPinnedNote('# Plan\n- meeting at 3pm'); // unchanged: no traffic
      expect(backend.pinnedRefreshes, 1);
      backend.sendText('when is the meeting?');
      final t = server.last.types;
      expect(t.lastIndexOf('session.update'), lessThan(t.lastIndexOf('response.create')));
    });

    test('edit during a response is deferred until response.done, then precedes response.create', () async {
      final ws = server.last;
      ws.push({
        'type': 'response.created',
        'response': {'id': 'r1', 'status': 'in_progress'},
      });
      await _pump();
      backend.setPinnedNote('# Plan\n- [x] book room');
      expect(backend.pinnedRefreshes, 0, reason: 'never changes instructions mid-response');
      ws.push({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed', 'output': <Object?>[]},
      });
      await _pump();
      expect(backend.pinnedRefreshes, 1);
      expect(instructionsOf(ws.ofType('session.update').last), contains('- [x] book room'));
    });
  });

  group('gpt-live', () {
    test('startup/reconnect instructions put the note after the base, before the summary', () {
      final s = LiveWebRtcBackend.composeInstructions('Base.', 'old stuff', 'user: hi', note: '- meeting at 3pm');
      expect(s, startsWith(withPinnedNote('Base.', '- meeting at 3pm')));
      expect(s.indexOf('<note>'), lessThan(s.indexOf('old stuff')));
      expect(s, contains('user: hi'));
      expect(LiveWebRtcBackend.composeInstructions('Base.', null, null), 'Base.');
    });

    test('delegation input carries the current pinned note on every request', () async {
      var note = '- meeting at 3pm';
      final m = FakeDelegationModel([]);
      final ex = DelegationExecutor(
        model: m,
        tools: const [
          ToolSpec(name: 'list_dir', description: 'ls', parameters: {'type': 'object'}),
        ],
        runTool: (id, name, args) async => '{"ok":true}',
        latestScreenshot: () => DelegationImage(png: Uint8List(4), capturedAt: DateTime.now(), note: 'x'),
        pinnedNote: () => note,
      );
      await ex.execute('when is the meeting?', id: 'd1');
      note = '- meeting moved to 4pm';
      await ex.execute('and now?', id: 'd2');
      String firstText(int i) => ((m.requests[i].input.first['content'] as List).first as Map)['text'] as String;
      expect(firstText(0), pinnedNoteBlock('- meeting at 3pm'));
      expect(firstText(1), contains('moved to 4pm'));
    });
  });

  group('context meter: pinned segment', () {
    late ContextManager cm;
    late Conversation conv;
    setUp(() {
      cm = ContextManager(compressor: _NoCompressor(), threshold: 100000, minInterval: Duration.zero);
      conv = Conversation()..add(Message(kind: MessageKind.user, text: 'a' * 1000)); // 254
      cm.attach(conv);
    });
    tearDown(() => cm.dispose());

    test('estimate and breakdown include the note', () {
      cm.pinnedTokens = 100;
      expect(cm.estimatedTokens, 354);
      expect(cm.parts().pinned, 100);
      expect(cm.parts().estimated, 354);
    });

    test('usage-anchored: the note is not scaled and later note edits move the total 1:1', () {
      cm
        ..configure(accounting: ContextAccounting.usage, overheadTokens: 50)
        ..pinnedTokens = 100;
      cm.onUsage(50 + 100 + 2 * 254); // messages cost twice the heuristic
      expect(cm.estimatedTokens, 658);
      expect(cm.parts().text, 508, reason: 'scale excludes the pinned note');
      cm.pinnedTokens = 160;
      expect(cm.estimatedTokens, 718);
    });
  });
}
