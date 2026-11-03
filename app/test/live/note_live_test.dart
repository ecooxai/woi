// REAL direct-mode (Realtime WS) test of the pinned conversation note.
//
//   WOI_LIVE=1 flutter test --tags live test/live/note_live_test.dart
//
// 1. "Remember the meeting is at 3pm": the model records it with update_note
//    (no confirmation) and the backend refreshes the pinned note with a live
//    session.update.
// 2. "When is the meeting?" in the same session is answered.
// 3. A brand-new session with NO conversation history, whose note is pinned
//    via session.update after connecting, still answers 3pm: the answer comes
//    from the note.
@Tags(['live'])
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart' show kAssistantInstructions;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/note_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import '../fakes/fakes.dart';

final _live = Platform.environment['WOI_LIVE'] == '1';
final _model = Platform.environment['WOI_REALTIME_MODEL'] ?? 'gpt-realtime-2';

class _Session {
  _Session(this.notes, this.auth) {
    tools.registerAll(noteTools(notes));
    backend = RealtimeWsBackend(credentialsProvider: auth.credentials, log: (_) {})..recordSent = true;
    sub = backend.events.listen(_onEvent);
  }

  final NoteController notes;
  final CodexAuthManager auth;
  final tools = ToolRegistry();
  late final RealtimeWsBackend backend;
  late final StreamSubscription<BackendEvent> sub;
  final events = <BackendEvent>[];
  final calls = <String>[];
  int _pending = 0;

  void _onEvent(BackendEvent e) {
    events.add(e);
    if (e is ToolCall) {
      _pending++;
      calls.add('${e.name} ${e.argsJson}');
      unawaited(
        tools.dispatch(e.name, e.argsJson, callId: e.callId).then((o) {
          _pending--;
          backend.sendToolResult(e.callId, o.json);
        }),
      );
    }
  }

  /// Mirrors AppController: every note change goes to the backend.
  void followNote() => notes.addListener(() => backend.setPinnedNote(notes.text));

  Future<void> connect({required String? note}) => backend.connect(
    SessionConfig(
      model: _model,
      voice: 'marin',
      instructions: kAssistantInstructions,
      tools: tools.specs,
      pinnedNote: note,
    ),
  );

  /// Sends [text] and waits until the turn (including tool rounds) is over.
  Future<String> turn(String text) async {
    final n = events.whereType<AssistantTranscriptDone>().length;
    backend.sendText(text);
    var quietSince = DateTime.now();
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final busy = backend.responseActive || _pending > 0;
      if (busy) quietSince = DateTime.now();
      final answered = events.whereType<ResponseDone>().isNotEmpty;
      if (answered && !busy && DateTime.now().difference(quietSince) > const Duration(milliseconds: 2500)) break;
    }
    return events.whereType<AssistantTranscriptDone>().skip(n).map((e) => e.text).join(' ');
  }

  List<String> get errors => [for (final e in events.whereType<BackendError>()) '${e.code}: ${e.message}'];

  Future<void> dispose() async {
    await sub.cancel();
    await backend.close();
  }
}

bool _mentions3pm(String s) {
  final t = s.toLowerCase();
  return RegExp(r'\b3\s*(?::00)?\s*(p\.?m\.?)?\b|three|15:00').hasMatch(t);
}

void main() {
  final skip = _live ? false : 'set WOI_LIVE=1 to run against OpenAI';
  late FakePlatform fp;
  late NoteController notes;
  late CodexAuthManager auth;

  setUpAll(() async {
    fp = await FakePlatform.create();
    notes = NoteController(store: NoteStore(fp.services.paths.dataDir), autosaveDelay: Duration.zero);
    await notes.open('live_conv');
    auth = CodexAuthManager();
  });
  tearDownAll(() async {
    notes.dispose();
    await fp.dispose();
  });

  test('remember → note → recall (direct mode, live session.update)', skip: skip, () async {
    final s = _Session(notes, auth)..followNote();
    try {
      await s.connect(note: notes.text);
      final a1 = await s.turn('Remember the meeting is at 3pm.');
      print('TURN1 answer="$a1" calls=${s.calls} refreshes=${s.backend.pinnedRefreshes}\nNOTE:\n${notes.text}');
      expect(s.calls.any((c) => c.startsWith('update_note')), isTrue, reason: 'should record it in the note');
      expect(_mentions3pm(notes.text), isTrue, reason: 'note lacks the meeting time');
      expect(s.backend.pinnedRefreshes, greaterThan(0), reason: 'note change must refresh via session.update');
      final updates = s.backend.sentLog.where((e) => e['type'] == 'session.update').length;
      expect(updates, greaterThanOrEqualTo(2), reason: 'handshake + at least one note refresh');

      final a2 = await s.turn('When is the meeting?');
      print('TURN2 answer="$a2"');
      expect(_mentions3pm(a2), isTrue);
      expect(s.errors, isEmpty);
    } finally {
      await s.dispose();
    }
  });

  test('fresh session without history answers from the pinned note only', skip: skip, () async {
    expect(_mentions3pm(notes.text), isTrue, reason: 'depends on the first test');
    final s = _Session(notes, auth);
    try {
      await s.connect(note: ''); // starts empty...
      await Future<void>.delayed(const Duration(milliseconds: 500));
      s.backend.setPinnedNote(notes.text); // ...the note arrives via a live session.update
      expect(s.backend.pinnedRefreshes, 1);
      final a = await s.turn('When is the meeting? Answer in one short sentence.');
      print('FRESH answer="$a" calls=${s.calls}');
      expect(_mentions3pm(a), isTrue, reason: 'answer must come from the pinned note');
      expect(s.errors, isEmpty);
    } finally {
      await s.dispose();
    }
  });
}
