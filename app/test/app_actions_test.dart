import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_actions.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';

import 'fakes/fakes.dart';

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
    a = c.actions;
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

  test('views: show, by name, split', () {
    a.showViewNamed('chat');
    expect(a.view.value, HomeView.chat);
    a.showViewNamed('side by side');
    expect(a.split.value, isTrue);
    a.showViewNamed('note');
    expect(a.view.value, HomeView.note);
    a.splitAvailable = false;
    expect(() => a.showViewNamed('split'), throwsA(isA<AppActionError>()));
    expect(() => a.showViewNamed('kitchen'), throwsA(isA<AppActionError>()));
  });

  test('settings by voice', () async {
    expect(await a.setSetting('theme', 'dark'), 'theme dark');
    expect(c.settings.theme, AppTheme.dark);
    await a.setSetting('mic mode', 'push to talk');
    expect(c.settings.micMode, MicMode.pushToTalk);
    await a.setSetting('compaction_threshold', '80k');
    expect(c.settings.compressionThreshold, 80000);
    await a.setSetting('edit_apply_delay', 'require approval');
    expect(c.settings.editApplyDelay, kRequireApproval);
    expect(() => a.setSetting('theme', 'purple'), throwsA(isA<AppActionError>()));
    expect(() => a.setSetting('bogus', '1'), throwsA(isA<AppActionError>()));
  });

  test('note text edits, then "undo that"', () async {
    await a.appendToNote('- buy milk');
    expect(c.notes.text, contains('- buy milk'));
    await a.insertInNote('- eggs', after: 'milk');
    expect(c.notes.text, contains('- buy milk\n- eggs'));
    await a.replaceInNote('eggs', 'bread');
    await a.deleteFromNote('buy milk');
    expect(c.notes.text, isNot(contains('milk')));
    expect(await a.undoLastEdit(), contains('note'));
    expect(c.notes.text, contains('milk'));
    expect(() => a.replaceInNote('nothing here', 'x'), throwsA(isA<AppActionError>()));
  });

  test('countdown edit is applied by the local "apply" command', () async {
    await c.updateSettings(c.settings.copyWith(editApplyDelay: 10));
    final f = a.appendToNote('- later');
    await Future<void>.delayed(Duration.zero);
    expect(c.review.hasPending, isTrue);
    expect(c.notes.text, isNot(contains('later')));
    c.pipeline.sendText('apply');
    expect(await f, isNotEmpty);
    expect(c.notes.text, contains('- later'));
    // A rejected one throws back to the tool as denied.
    final g = a.appendToNote('- nope');
    await Future<void>.delayed(Duration.zero);
    c.pipeline.sendText('reject');
    await expectLater(g, throwsA(isA<AppActionError>()));
    expect(c.notes.text, isNot(contains('nope')));
  });

  test('note_control / app_control tools', () async {
    expect((await tool('note_control', {'action': 'append', 'text': '- tool item'}))['ok'], isTrue);
    expect(c.notes.text, contains('- tool item'));
    await tool('app_control', {'action': 'show_view', 'view': 'chat'});
    expect(a.view.value, HomeView.chat);
    await tool('app_control', {'action': 'set_setting', 'key': 'theme', 'value': 'light'});
    expect(c.settings.theme, AppTheme.light);
    await tool('note_control', {'action': 'rename', 'title': 'Groceries'});
    expect(c.pipeline.conversation.title, 'Groceries');
    final undo = await tool('app_control', {'action': 'undo_edit'});
    expect(undo['ok'], isTrue);
    expect(c.notes.text, isNot(contains('tool item')));
    final none = await tool('app_control', {'action': 'apply_edit'});
    expect('$none', contains('no edit is waiting'));
  });

  test('notes: new, find, switch, delete with approval', () async {
    await a.appendToNote('# Alpha plans');
    final first = c.pipeline.conversation.id;
    await a.renameNote('Alpha plans');
    c.pipeline.sendText('hello'); // something to keep the conversation
    await a.newNote();
    expect(c.pipeline.conversation.id, isNot(first));
    await a.appendToNote('# Beta');
    expect((await a.findNote('alpha')).id, first);
    expect(await a.switchNote('previous'), 'Alpha plans');
    expect(c.pipeline.conversation.id, first);
    final del = a.deleteNote();
    await Future<void>.delayed(Duration.zero);
    expect(c.review.current?.requireApproval, isTrue);
    c.review.reject();
    await expectLater(del, throwsA(isA<AppActionError>()));
    expect((await c.listConversations()).any((s) => s.id == first), isTrue);
  });

  test('file edits go through the review and can be undone', () async {
    final f = File('${fp.root.path}/w.txt')..writeAsStringSync('v1\n');
    final r = await tool('write_file', {'path': f.path, 'content': 'v2\n'});
    expect(r['ok'] ?? r['written'], isNotNull);
    expect(f.readAsStringSync(), 'v2\n');
    await a.undoLastEdit();
    expect(f.readAsStringSync(), 'v1\n');
  });

  group('delegation fast paths', () {
    List<(String, Map<String, Object?>)>? fp(String s) => DelegationExecutor.appFastPath(s);
    test('app control phrases', () {
      expect(fp('undo that')!.single.$2['action'], 'undo_edit');
      expect(fp('Switch to terminal.')!.single.$2, {'action': 'show_view', 'view': 'terminal'});
      expect(fp('go back to the chat')!.single.$2['view'], 'chat');
      expect(fp('change theme to dark')!.single.$2, {'action': 'set_setting', 'key': 'theme', 'value': 'dark'});
      expect(fp('switch to light mode')!.single.$2['value'], 'light');
      expect(fp('please apply the edit')!.single.$2['action'], 'apply_edit');
      expect(fp('reject it')!.single.$2['action'], 'reject_edit');
      expect(fp('mute the mic')!.single.$2['value'], 'muted');
      expect(fp('new note')!.single.$1, 'note_control');
      expect(fp("add 'buy milk' to my note")!.single.$2, {'action': 'append', 'text': '- buy milk'});
    });
    test('leaves real requests to the model', () {
      expect(fp('add that to my note'), isNull);
      expect(fp('open the note about taxes'), isNull);
      expect(fp('dark'), isNull);
      expect(fp('undo the last git commit'), isNull);
      expect(fp('copy that'), isNull);
      expect(DelegationExecutor.keysFastPath('undo that'), isNull);
    });
  });
}
