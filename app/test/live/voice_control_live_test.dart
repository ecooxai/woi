// REAL direct-mode (gpt-realtime-2.1) check that typed requests map to the
// voice-control ops (docs/VOICE_CONTROL.md). The tools run for real against
// an AppController on the fake platform.
//
//   WOI_LIVE=1 flutter test --tags live test/live/voice_control_live_test.dart
@Tags(['live'])
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import '../fakes/fakes.dart';

final _live = Platform.environment['WOI_LIVE'] == '1';
const _model = 'gpt-realtime-2.1';

void main() {
  final skip = _live ? false : 'set WOI_LIVE=1 to run against OpenAI';

  test('rename / new note by typed request (direct, $_model)', skip: skip, () async {
    final fp = await FakePlatform.create();
    final c = AppController(
      platform: fp.services,
      confirmations: FakeConfirmations(),
      backendFactory: () => ScriptedBackend(),
      authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
    );
    await c.init();
    await c.updateSettings(c.settings.copyWith(editApplyDelay: 0));
    final auth = CodexAuthManager();
    final backend = RealtimeWsBackend(credentialsProvider: auth.credentials, log: (_) {});
    final events = <BackendEvent>[];
    final calls = <String>[];
    var pending = 0;
    final sub = backend.events.listen((e) {
      events.add(e);
      if (e is ToolCall) {
        pending++;
        calls.add('${e.name} ${e.argsJson}');
        unawaited(
          c.tools.dispatch(e.name, e.argsJson, callId: e.callId).then((o) {
            pending--;
            print('RESULT ${e.name}: ${o.json}');
            backend.sendToolResult(e.callId, o.json);
          }),
        );
      }
    });

    Future<String> turn(String text) async {
      final n = events.whereType<AssistantTranscriptDone>().length;
      backend.sendText(text);
      var quietSince = DateTime.now();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final busy = backend.responseActive || pending > 0;
        if (busy) quietSince = DateTime.now();
        if (events.whereType<ResponseDone>().isNotEmpty && !busy &&
            DateTime.now().difference(quietSince) > const Duration(milliseconds: 2500)) {
          break;
        }
      }
      return events.whereType<AssistantTranscriptDone>().skip(n).map((e) => e.text).join(' ');
    }

    try {
      await backend.connect(
        SessionConfig(model: _model, voice: 'marin', instructions: kAssistantInstructions, tools: c.tools.specs),
      );
      final a1 = await turn('Rename this note to Shopping list.');
      print('TURN1 "$a1" calls=$calls title=${c.pipeline.conversation.title}');
      expect(calls.any((x) => x.contains('rename') && x.contains('Shopping list')), isTrue);
      expect(c.pipeline.conversation.title, 'Shopping list');

      c.pipeline.sendText('hello'); // the current note is not empty any more
      calls.clear();
      final a2 = await turn('Create a new note called Ideas.');
      print('TURN2 "$a2" calls=$calls title=${c.pipeline.conversation.title}');
      expect(calls.any((x) => x.contains('"new"')), isTrue);
      expect(c.pipeline.conversation.title, 'Ideas');
    } finally {
      await sub.cancel();
      await backend.close();
      await c.shutdown();
      await fp.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
