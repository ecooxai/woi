import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/notes/note_tabs.dart';

import 'fakes/fakes.dart';

void main() {
  late FakePlatform platform;
  late AppController controller;

  setUp(() async {
    platform = await FakePlatform.create();
    controller = AppController(
      platform: platform.services,
      confirmations: FakeConfirmations(),
      backendFactory: () => ScriptedBackend(),
      authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
    );
    await controller.init();
    expect(controller.initError, isNull);
  });

  tearDown(() async {
    await controller.shutdown();
    await platform.dispose();
  });

  Future<void> saveNote(String markdown) async {
    controller.notes.setText(markdown);
    await controller.notes.flush();
    await controller.history.flush(controller.pipeline.conversation);
  }

  test('system-only history takes its title from the saved note and follows heading edits', () async {
    final conversation = controller.pipeline.conversation;
    conversation
      ..add(Message(kind: MessageKind.system, text: 'Connection lost. Reconnecting.'))
      ..add(Message(kind: MessageKind.system, text: 'Reconnected.'));

    await saveNote('# Woi QA Nov10\n\nKeep this body exactly.');
    expect(conversation.title, 'Woi QA Nov10');
    expect(currentNoteTitle(controller), 'Woi QA Nov10');
    expect((await controller.history.list()).single.title, 'Woi QA Nov10');

    await saveNote('# Updated note heading\n\nKeep this body exactly.');
    expect(conversation.title, 'Updated note heading');
    expect(currentNoteTitle(controller), 'Updated note heading');
    expect((await controller.history.load(conversation.id))!.title, 'Updated note heading');
    expect(conversation.messages.map((message) => message.kind), everyElement(MessageKind.system));
  });

  for (final kind in [MessageKind.user, MessageKind.assistant, MessageKind.tool]) {
    test('a $kind conversation keeps its meaningful title when the note changes', () async {
      final conversation = controller.pipeline.conversation;
      conversation
        ..title = 'Meaningful chat title'
        ..add(Message(kind: kind, text: 'Conversation content'));
      await saveNote('# A different note heading');
      expect(conversation.title, 'Meaningful chat title');
      expect(currentNoteTitle(controller), 'Meaningful chat title');
      expect((await controller.history.load(conversation.id))!.title, 'Meaningful chat title');
    });
  }

  test('a custom note title is preserved and shown even without chat messages', () async {
    final conversation = controller.pipeline.conversation;
    await controller.renameConversation(conversation.id, 'My custom note name');
    await saveNote('# A different heading');
    expect(conversation.messages, isEmpty);
    expect(conversation.title, 'My custom note name');
    expect(currentNoteTitle(controller), 'My custom note name');
    expect((await controller.history.list()).single.title, 'My custom note name');
  });

  test('a compacted conversation summary preserves its meaningful title', () async {
    final conversation = controller.pipeline.conversation;
    conversation
      ..title = 'Earlier discussion'
      ..summary = 'A retained summary of meaningful user and assistant turns.'
      ..add(Message(kind: MessageKind.system, text: 'Reconnected.'));
    await saveNote('# Unrelated note heading');
    expect(conversation.title, 'Earlier discussion');
    expect(currentNoteTitle(controller), 'Earlier discussion');
  });

  test('deleting an inactive note retains current note data and removes both persisted files', () async {
    await saveNote('# Survivor\n\nExact surviving body.');
    final survivor = controller.pipeline.conversation.id;
    await controller.newConversation();
    await saveNote('# Temporary note');
    final temporary = controller.pipeline.conversation.id;
    await controller.openConversation(survivor);
    controller.notes.rememberSelection(2, 10);
    await controller.deleteConversation(temporary);
    expect(controller.pipeline.conversation.id, survivor);
    expect(controller.notes.text, '# Survivor\n\nExact surviving body.');
    expect((controller.notes.selectionStart, controller.notes.selectionEnd), (2, 10));
    expect(await controller.history.load(temporary), isNull);
    expect(await File('${platform.services.paths.dataDir}/notes/$temporary.json').exists(), isFalse);
  });
}
