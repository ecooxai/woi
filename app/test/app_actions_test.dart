import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_actions.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/notes/note_copy.dart';
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
    expect(a.splitActive, isTrue);
    // Settings and Terminal are full-size tabs; Note / Chat restore the split.
    expect(a.showViewNamed('settings'), 'settings');
    expect(a.view.value, HomeView.settings);
    expect(a.splitActive, isFalse);
    a.closeSettings();
    expect(a.view.value, HomeView.note);
    expect(a.splitActive, isTrue);
    a.showViewNamed('preferences');
    expect(a.view.value, HomeView.settings);
    a.showViewNamed('chat');
    expect(a.splitActive, isTrue);
    a.showViewNamed('settings');
    a.toggleSplit();
    expect(a.view.value, HomeView.settings, reason: 'turning split off stays on the tab');
    a.toggleSplit();
    expect(a.view.value, HomeView.note, reason: 'turning split on shows the note and the chat');
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
    expect(await a.setSetting('echo cancellation', 'off'), 'echo cancellation off');
    expect(c.settings.echoCancellation, isFalse);
    expect(fp.audio.echoCancellation, isFalse, reason: 'applied to the platform audio');
    expect(await a.setSetting('aec', 'on'), 'echo cancellation on');
    expect(fp.audio.echoCancellation, isTrue);
    expect(() => a.setSetting('echo_cancellation', 'maybe'), throwsA(isA<AppActionError>()));
    await a.setSetting('audio_route', 'media');
    expect(c.settings.androidAudioRoute, AndroidAudioRoute.media);
    await a.setSetting('audio_route', 'phone');
    expect(c.settings.androidAudioRoute, AndroidAudioRoute.phone);
    expect(() => a.setSetting('audio_route', 'tin can'), throwsA(isA<AppActionError>()));
    if (fp.audio.mic != null) expect(fp.audio.micOpens.last, isTrue, reason: 'mic reopened with the canceller');
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

  test('typing syncs the pinned note once after a pause, not per keystroke', () async {
    var changes = 0;
    c.contextManager.addListener(() => changes++);
    final before = c.contextManager.pinnedTokens;
    for (final ch in 'a fairly long line typed one key at a time'.split('')) {
      c.notes.setText(c.notes.text + ch);
    }
    expect(changes, 0, reason: 'no meter update per keystroke');
    await Future<void>.delayed(AppController.pinnedNoteDebounce + const Duration(milliseconds: 100));
    expect(changes, 1);
    expect(c.contextManager.pinnedTokens, greaterThan(before));
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

  test('copy: note, line, paragraph, H1 section at the cursor (note_control copy)', () async {
    final clip = <String>[];
    a.writeClipboard = (t) async => clip.add(t);
    c.notes.setText('# A\npara one\nstill one\n\npara two\n# B\nlast');
    c.notes.cursor = c.notes.text.indexOf('still');
    expect(await a.copyNote(NoteCopyScope.line), 'Copied line');
    expect(clip.last, 'still one');
    expect(a.copied.value!.label, 'Copied line');
    var r = await tool('note_control', {'action': 'copy', 'what': 'paragraph'});
    expect(r['ok'], isTrue);
    expect(clip.last, '# A\npara one\nstill one');
    r = await tool('note_control', {'action': 'copy', 'what': 'section'});
    expect(clip.last, '# A\npara one\nstill one\n\npara two');
    r = await tool('note_control', {'action': 'copy'});
    expect(clip.last, c.notes.text);
    // Unknown cursor: the end of the note.
    c.notes.cursor = -1;
    await tool('note_control', {'action': 'copy', 'what': 'section'});
    expect(clip.last, '# B\nlast');
    final seq = a.copied.value!.seq;
    c.notes.setText('');
    r = await tool('note_control', {'action': 'copy'});
    expect(r['ok'], isNot(true));
    expect(a.copied.value!.seq, seq, reason: 'nothing copied, no confirmation');
  });

  group('delegation fast paths', () {
    List<(String, Map<String, Object?>)>? fp(String s) => DelegationExecutor.appFastPath(s);
    test('app control phrases', () {
      expect(fp('undo that')!.single.$2['action'], 'undo_edit');
      expect(fp('Switch to terminal.')!.single.$2, {'action': 'show_view', 'view': 'terminal'});
      expect(fp('go back to the chat')!.single.$2['view'], 'chat');
      expect(fp('open settings')!.single.$2, {'action': 'show_view', 'view': 'settings'});
      expect(fp('show the chat')!.single.$2['view'], 'chat');
      expect(fp('go to settings')!.single.$2['view'], 'settings');
      expect(fp('change theme to dark')!.single.$2, {'action': 'set_setting', 'key': 'theme', 'value': 'dark'});
      expect(fp('switch to light mode')!.single.$2['value'], 'light');
      expect(fp('please apply the edit')!.single.$2['action'], 'apply_edit');
      expect(fp('reject it')!.single.$2['action'], 'reject_edit');
      expect(fp('mute the mic')!.single.$2['value'], 'muted');
      expect(fp('new note')!.single.$1, 'note_control');
      expect(fp("add 'buy milk' to my note")!.single.$2, {'action': 'append', 'text': '- buy milk'});
      expect(fp('copy this paragraph')!.single.$2, {'action': 'copy', 'what': 'paragraph'});
      expect(fp('Please copy the current line.')!.single.$2['what'], 'line');
      expect(fp('copy the whole note')!.single.$2['what'], 'note');
      expect(fp('copy this heading section to the clipboard')!.single.$2['what'], 'section');
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
