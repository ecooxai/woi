import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_actions.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';

import 'fakes/fakes.dart';

/// The voice-control ops added to app_control / note_control
/// (docs/VOICE_CONTROL.md), called through the tool registry.
void main() {
  late FakePlatform fp;
  late AppController c;
  late AppActions a;

  setUp(() async {
    fp = await FakePlatform.create();
    c = AppController(
      platform: fp.services,
      confirmations: FakeConfirmations(),
      backendFactory: () => ScriptedBackend(),
      authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
    );
    await c.init();
    a = c.actions
      ..replyStartGrace = Duration.zero
      ..replyPoll = const Duration(milliseconds: 5)
      ..replyMaxWait = const Duration(milliseconds: 200)
      ..reconnectDelay = Duration.zero;
    await c.updateSettings(c.settings.copyWith(editApplyDelay: 0));
  });
  tearDown(() async {
    await c.shutdown();
    await fp.dispose();
  });

  Future<Map<String, Object?>> tool(String name, Map<String, Object?> args) async {
    final r = await c.tools.dispatch(name, jsonEncode(args));
    return jsonDecode(r.json) as Map<String, Object?>;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  test('note_control new with a title creates and names the note', () async {
    c.pipeline.sendText('hello');
    final before = c.pipeline.conversation.id;
    final r = await tool('note_control', {'action': 'new', 'title': 'Ideas'});
    expect(r['ok'], isTrue);
    expect(r['done'], 'created note "Ideas"');
    expect(c.pipeline.conversation.id, isNot(before));
    expect(c.pipeline.conversation.title, 'Ideas');
    expect(c.pipeline.conversation.customTitle, isTrue);
    expect(a.view.value, HomeView.note);
    final plain = await tool('note_control', {'action': 'new'});
    expect(plain['done'], 'created a new note');
  });

  test('note_control rename confirms the new title', () async {
    final r = await tool('note_control', {'action': 'rename', 'title': 'Shopping list'});
    expect(r['renamed_to'], 'Shopping list');
    expect(c.pipeline.conversation.title, 'Shopping list');
  });

  test('disconnect waits for the reply, then stays offline; reconnect connects', () async {
    await settle();
    expect(c.pipeline.status, SessionStatus.connected);
    final r = await tool('app_control', {'action': 'disconnect'});
    expect(r['ok'], isTrue);
    expect('${r['done']}', contains('after this reply'));
    expect('${r['say']}', contains('Retry'));
    expect(c.pipeline.status, SessionStatus.connected, reason: 'not cut off mid-reply');
    await settle();
    expect(c.pipeline.status, SessionStatus.disconnected);
    expect(c.pipeline.suspended, isTrue);
    expect('${await tool('app_control', {'action': 'disconnect'})}', contains('already disconnected'));
    expect((await tool('app_control', {'action': 'reconnect'}))['ok'], isTrue);
    await settle();
    expect(c.pipeline.status, SessionStatus.connected);
  });

  test('afterReply runs once Woi is idle, bounded by replyMaxWait', () async {
    var ran = false;
    final sw = Stopwatch()..start();
    await a.afterReply(() async => ran = true);
    expect(ran, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('clear_chat asks first; approved it clears messages and keeps note and title', () async {
    c.pipeline.sendText('first message');
    await a.appendToNote('- keep me');
    await a.renameNote('Trip');
    expect(c.pipeline.conversation.messages, isNotEmpty);
    // Rejected: nothing changes.
    var f = tool('app_control', {'action': 'clear_chat'});
    await settle();
    expect(c.review.current?.requireApproval, isTrue);
    c.review.reject();
    expect('${await f}', contains('kept the chat'));
    expect(c.pipeline.conversation.messages, isNotEmpty);
    // Approved.
    f = tool('app_control', {'action': 'clear_chat'});
    await settle();
    c.review.apply();
    final r = await f;
    expect(r['ok'], isTrue);
    expect('${r['done']}', startsWith('cleared'));
    expect(c.pipeline.conversation.messages, isEmpty);
    expect(c.notes.text, contains('- keep me'));
    expect(c.pipeline.conversation.title, 'Trip');
    expect((await tool('app_control', {'action': 'clear_chat'}))['done'], 'the chat is already empty');
  });

  test('compact needs a conversation', () async {
    expect('${await tool('app_control', {'action': 'compact'})}', contains('nothing to compact'));
    c.pipeline.sendText('something');
    final r = await tool('app_control', {'action': 'compact'});
    expect(r['ok'], isTrue);
    expect('${r['done']}', contains('compact'));
  });

  test('terminal_switch and terminal_rename', () async {
    await tool('app_control', {'action': 'terminal_new'});
    await tool('app_control', {'action': 'terminal_new'});
    final n = c.terminals.sessions.length;
    var r = await tool('app_control', {'action': 'terminal_switch', 'tab': '1'});
    expect(r['ok'], isTrue);
    expect(c.terminals.active, c.terminals.sessions.first);
    expect(a.view.value, HomeView.terminal);
    r = await tool('app_control', {'action': 'terminal_rename', 'tab': '$n', 'title': 'Build'});
    expect(r['renamed_to'], 'Build');
    expect(c.terminals.sessions[n - 1].title, 'Build');
    expect('${await tool('app_control', {'action': 'terminal_rename', 'tab': '1'})}', contains('needs "title"'));
  });

  test('new settings by voice', () async {
    Future<String> set(String k, String v) async {
      final r = await tool('app_control', {'action': 'set_setting', 'key': k, 'value': v});
      expect(r['ok'], isTrue, reason: '$k=$v: $r');
      return '${r['done']}';
    }

    expect(await set('auto_screenshot', 'off'), 'auto screenshot off');
    expect(c.settings.autoScreenshot, isFalse);
    expect(await set('screenshot_delay', '1.5'), 'screenshot delay 1.5 s');
    expect(c.settings.screenshotDelayMs, 1500);
    await set('camera_replaces_screenshot', 'on');
    expect(c.settings.cameraReplacesScreenshot, isTrue);
    await set('thinking chime', 'off');
    expect(c.settings.thinkingEarcon, isFalse);
    await set('confirm_commands', 'on');
    expect(c.settings.confirmBeforeBash, isTrue);
    await set('fallback_to_direct', 'off');
    expect(c.settings.fallbackToDirectOnLimit, isFalse);
    await set('delegate_model', 'luna');
    expect(c.settings.delegateModel, 'gpt-6-luna');
    await set('compression_model', 'gpt-6-luna');
    expect(c.settings.compressionModel, 'gpt-6-luna');
    expect(await set('chat_pane', '50%'), 'chat pane 50% of the width');
    expect(c.settings.chatPaneFraction, 0.5);
    await set('chat_pane', '90');
    expect(c.settings.chatPaneFraction, kChatPaneMaxFraction);
    await set('chat_pane', 'default');
    expect(c.settings.chatPaneFraction, kDefaultChatPaneFraction);
    await set('workspace', fp.root.path);
    expect(c.settings.workspaceDir, fp.root.path);
    expect(
      '${await tool('app_control', {'action': 'set_setting', 'key': 'workspace', 'value': '/no/such/dir'})}',
      contains('not found'),
    );
    expect(await set('backend', 'direct'), contains('Direct realtime'));
    // Session changes apply after the reply (reconnectDelay), asynchronously.
    for (var i = 0; i < 100 && c.settings.backendMode != BackendMode.direct; i++) {
      await settle();
    }
    expect(c.settings.backendMode, BackendMode.direct);
    expect(
      '${await tool('app_control', {'action': 'set_setting', 'key': 'thinking_chime', 'value': 'maybe'})}',
      contains('on or off'),
    );
  });
}
