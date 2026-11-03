import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/notes/note.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_ops.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/core/notes/pinned_note.dart';
import 'package:woi/tools/note_tools.dart';
import 'package:woi/tools/tool_registry.dart';

const _doc = '''# Launch

## Decisions
- Ship on Friday

## Todos
- [ ] Record the demo video
- [ ] Publish release notes

## Facts
- Notes: ~/work/RELEASE.md
''';

void main() {
  group('Note model', () {
    test('json round trip, empty, words and title', () {
      final n = Note(conversationId: 'c1', markdown: '# Hello world\n\n- [ ] one `two`');
      final back = Note.fromJson(jsonDecode(jsonEncode(n.toJson())) as Map<String, Object?>);
      expect(back.conversationId, 'c1');
      expect(back.markdown, n.markdown);
      expect(back.updatedAt.toIso8601String(), n.updatedAt.toIso8601String());
      expect(Note(conversationId: 'x', markdown: ' \n ').isEmpty, isTrue);
      expect(noteWordCount('# Hello world\n\n- [ ] one `two`'), 4);
      expect(noteWordCount(''), 0);
      expect(noteTitle('\n# Plan for Q3\nbody'), 'Plan for Q3');
    });

    test('store saves atomically, skips empty new notes, deletes', () async {
      final dir = await Directory.systemTemp.createTemp('woi_notes');
      addTearDown(() => dir.delete(recursive: true));
      final store = NoteStore(dir.path);
      await store.save(Note(conversationId: 'empty'));
      expect(File('${dir.path}/notes/empty.json').existsSync(), isFalse);
      await store.save(Note(conversationId: 'c1', markdown: 'hi'));
      expect((await store.load('c1')).markdown, 'hi');
      expect((await store.load('missing')).markdown, '');
      await store.delete('c1');
      expect((await store.load('c1')).markdown, '');
    });
  });

  group('update_note modes', () {
    test('append adds a block; list items join without a blank line', () {
      var r = applyNoteEdit('', NoteEditMode.append, text: '# Notes');
      expect(r.text, '# Notes\n');
      r = applyNoteEdit(r.text, NoteEditMode.append, text: 'The meeting is at 3pm.');
      expect(r.text, '# Notes\n\nThe meeting is at 3pm.\n');
      r = applyNoteEdit('- a', NoteEditMode.append, text: '- b');
      expect(r.text, '- a\n- b\n');
      expect(r.text.substring(r.start, r.end), '- b');
    });

    test('replace_section replaces only that section and creates missing ones', () {
      final r = applyNoteEdit(_doc, NoteEditMode.replaceSection, heading: 'Decisions', text: '- Ship on Monday');
      expect(r.text, contains('## Decisions\n\n- Ship on Monday\n\n## Todos'));
      expect(r.text, isNot(contains('Friday')));
      expect(r.text, contains('- [ ] Publish release notes'));

      // Fuzzy heading match ("decisions" / "## Decisions:").
      final f = applyNoteEdit(_doc, NoteEditMode.replaceSection, heading: 'decisions', text: '- X');
      expect(f.text, contains('## Decisions\n\n- X'));

      final c = applyNoteEdit(_doc, NoteEditMode.replaceSection, heading: 'Meetings', text: '- 3pm sync');
      expect(c.text.trimRight(), endsWith('## Meetings\n\n- 3pm sync'));
    });

    test('replace_all and check_item (exact, substring, uncheck); misses fail', () {
      expect(applyNoteEdit(_doc, NoteEditMode.replaceAll, text: 'new').text, 'new\n');
      final c = applyNoteEdit(_doc, NoteEditMode.checkItem, item: 'demo video');
      expect(c.text, contains('- [x] Record the demo video'));
      final u = applyNoteEdit(c.text, NoteEditMode.checkItem, item: 'Record the demo video', checked: false);
      expect(u.text, contains('- [ ] Record the demo video'));
      expect(
        () => applyNoteEdit(_doc, NoteEditMode.checkItem, item: 'water the plants'),
        throwsA(isA<NoteEditException>()),
      );
      expect(NoteEditMode.parse('replace_section'), NoteEditMode.replaceSection);
      expect(NoteEditMode.parse('nope'), isNull);
    });

    test('toggleChecklistLine flips one line and ignores others', () {
      const t = '- [ ] a\n- b\n  - [x] c';
      expect(toggleChecklistLine(t, 0), '- [x] a\n- b\n  - [x] c');
      expect(toggleChecklistLine(t, 2), '- [ ] a\n- b\n  - [ ] c');
      expect(toggleChecklistLine(t, 1), isNull);
    });
  });

  group('NoteController', () {
    late Directory dir;
    late NoteController notes;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('woi_notes');
      notes = NoteController(store: NoteStore(dir.path), autosaveDelay: Duration.zero, typingGroup: Duration.zero);
      await notes.open('c1');
    });
    tearDown(() async {
      notes.dispose();
      await dir.delete(recursive: true);
    });

    test('typing, undo/redo and autosave', () async {
      notes.setText('a');
      notes.setText('ab');
      expect(notes.canUndo, isTrue);
      notes.undo();
      expect(notes.text, 'a');
      notes.redo();
      expect(notes.text, 'ab');
      await notes.flush();
      expect((await NoteStore(dir.path).load('c1')).markdown, 'ab');
    });

    test('AI edits are highlighted, tracked through user edits and undoable', () async {
      notes.setText('# Plan\n');
      final r = notes.applyEdit(NoteEditMode.append, text: '- Meeting at 3pm');
      final ai = notes.lastAiEdit!;
      expect(notes.text.substring(ai.start, ai.end), '- Meeting at 3pm');
      expect(ai.summary, r.summary);

      // The user types before the highlight: the range shifts along.
      notes.setText('Hi\n${notes.text}');
      expect(notes.text.substring(notes.lastAiEdit!.start, notes.lastAiEdit!.end), '- Meeting at 3pm');

      notes.undoAiEdit();
      expect(notes.text, '# Plan\n');
      expect(notes.lastAiEdit, isNull);
      // The revert itself can be undone.
      notes.undo();
      expect(notes.text, contains('Meeting at 3pm'));
    });

    test('switching conversations loads that note and flushes the current one', () async {
      notes.setText('first');
      await notes.open('c2');
      expect(notes.text, '');
      expect(notes.canUndo, isFalse);
      await notes.open('c1');
      expect(notes.text, 'first');
    });

    test('read_note / update_note tools edit without confirmation', () async {
      final reg = ToolRegistry()..registerAll(noteTools(notes));
      expect(reg.specs.map((s) => s.name), containsAll(['read_note', 'update_note']));
      Future<Map<String, Object?>> run(String name, Map<String, Object?> args) async =>
          jsonDecode((await reg.dispatch(name, jsonEncode(args), callId: 'call_1')).json) as Map<String, Object?>;

      expect((await run('read_note', {}))['empty'], isTrue);
      var out = await run('update_note', {'mode': 'append', 'text': '## Todos\n- [ ] Book the room'});
      expect(out['ok'], isTrue);
      out = await run('update_note', {'mode': 'check_item', 'item': 'book the room'});
      expect(out['ok'], isTrue);
      expect(notes.text, contains('- [x] Book the room'));
      out = await run('update_note', {'mode': 'replace_section', 'heading': 'Facts', 'text': '- Meeting at 3pm'});
      expect(notes.text, contains('## Facts\n\n- Meeting at 3pm'));
      out = await run('update_note', {'mode': 'check_item', 'item': 'nonexistent thing'});
      expect(out['ok'], isFalse);
      out = await run('update_note', {'mode': 'bogus'});
      expect(out['ok'], isFalse);
      final read = await run('read_note', {});
      expect(read['markdown'], notes.text);
      // Every AI edit is undoable.
      notes.undo();
      expect(notes.text, isNot(contains('Meeting at 3pm')));
    });
  });

  test('pinned note block', () {
    expect(pinnedNoteBlock(''), contains('(empty: nothing recorded yet)'));
    final b = withPinnedNote('Be brief.', '- meeting at 3pm');
    expect(b, startsWith('Be brief.\n\n# Conversation note'));
    expect(b, contains('<note>\n- meeting at 3pm\n</note>'));
    final long = 'x' * (kMaxPinnedNoteChars + 10);
    expect(pinnedNoteBlock(long), contains('call read_note for the rest'));
    expect(pinnedNoteTokens('abc'), greaterThan(0));
  });
}
