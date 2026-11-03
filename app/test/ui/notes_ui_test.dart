import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_ops.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/ui/notes/markdown_syntax.dart';
import 'package:woi/ui/notes/markdown_view.dart';
import 'package:woi/ui/notes/note_editor.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/theme.dart';

import '../fakes/fakes.dart';

Future<void> _ctrl(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(k);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

void main() {
  group('markdown', () {
    test('parseMarkdown block kinds, checklists and source lines', () {
      final b = parseMarkdown(
        '# T\n\n- [ ] a\n  - [x] b\n1. one\n> q\n```dart\nx\n```\n---\n| a | b |\n|---|---|\n| 1 | 2 |',
      );
      final kinds = b.where((x) => x.kind != MdBlockKind.blank).map((x) => x.kind).toList();
      expect(kinds, [
        MdBlockKind.heading,
        MdBlockKind.listItem,
        MdBlockKind.listItem,
        MdBlockKind.listItem,
        MdBlockKind.quote,
        MdBlockKind.code,
        MdBlockKind.rule,
        MdBlockKind.table,
      ]);
      final items = b.where((x) => x.kind == MdBlockKind.listItem).toList();
      expect([for (final i in items) i.checked], [false, true, null]);
      expect(items[1].level, greaterThan(items[0].level));
      expect(items[1].line, 3);
      expect(items[2].ordered, isNotNull);
      expect(b.firstWhere((x) => x.kind == MdBlockKind.code).lang, 'dart');
      expect(b.firstWhere((x) => x.kind == MdBlockKind.table).rows, hasLength(2));
    });

    test('inline links: urls, ~/ and absolute paths are tappable', () {
      final hits = <String>[];
      final spans = parseInline(
        'see ~/work/RELEASE.md, /tmp/demo.mp4 and https://x.dev/a',
        const TextStyle(),
        onLink: hits.add,
      );
      final tappable = spans.whereType<TextSpan>().where((s) => s.recognizer != null).map((s) => s.text).toList();
      expect(tappable, ['~/work/RELEASE.md', '/tmp/demo.mp4', 'https://x.dev/a']);
    });

    test('editor highlighting covers every character once; checkbox hit test', () {
      const src = '# H\n- [ ] **a** `b`\ntext';
      final runs = highlightMarkdown(src);
      var pos = 0;
      for (final r in runs) {
        expect(r.start, pos);
        pos = r.end;
      }
      expect(pos, src.length);
      expect(checkboxLineAt(src, src.indexOf('[ ]') + 1), 1);
      expect(checkboxLineAt(src, src.indexOf('text')), isNull);
    });
  });

  group('NoteEditor', () {
    late Directory dir;
    late NoteController notes;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('woi_ed');
      notes = NoteController(store: NoteStore(dir.path), autosaveDelay: const Duration(days: 1));
    });
    Future<void> done(WidgetTester t) async {
      await t.runAsync(notes.flush);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    }

    tearDown(() {
      notes.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<NoteEditorState> pump(WidgetTester t, {double width = 1100, NoteViewMode? mode}) async {
      await t.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: NoteEditor(notes: notes, initialMode: mode),
          ),
        ),
      );
      await t.pump();
      return t.state<NoteEditorState>(find.byType(NoteEditor));
    }

    testWidgets('typing goes to the note; word count; modes; dense pane drops split', (t) async {
      await t.runAsync(() => notes.open('c1'));
      final s = await pump(t);
      await t.enterText(find.byKey(const ValueKey('note-editor-field')), '# Plan\n\nmeeting at 3pm');
      await t.pump();
      expect(notes.text, '# Plan\n\nmeeting at 3pm');
      expect(find.textContaining('4 words'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('note-mode-preview')));
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(s.mode, NoteViewMode.preview);
      expect(find.byKey(const ValueKey('note-preview')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('note-mode-split')));
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(find.byKey(const ValueKey('note-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('note-editor-field')), findsOneWidget);

      await pump(t, width: 500);
      expect(s.mode, NoteViewMode.edit, reason: 'no side-by-side preview in a narrow pane');
      expect(find.byKey(const ValueKey('note-mode-split')), findsNothing);
      await done(t);
    });

    testWidgets('preview checkbox toggles the source line', (t) async {
      await t.runAsync(() => notes.open('c1'));
      notes.setText('## Todos\n- [ ] Book the room\n- [ ] Order food');
      await pump(t, mode: NoteViewMode.preview);
      await t.tap(find.byKey(const ValueKey('md-check-2')));
      await t.pump();
      expect(notes.text, '## Todos\n- [ ] Book the room\n- [x] Order food');
      await done(t);
    });

    testWidgets('AI edit shows the chip with undo; external edits reach the field', (t) async {
      await t.runAsync(() => notes.open('c1'));
      notes.setText('# Plan\n');
      final s = await pump(t);
      notes.applyEdit(NoteEditMode.append, text: '- Meeting at 3pm');
      await t.pump();
      expect(s.textController.text, contains('Meeting at 3pm'));
      expect(s.textController.aiRange, isNotNull);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(ValueKey('ai-chip-${notes.lastAiEdit!.seq}')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ai-undo')));
      await t.pump();
      expect(notes.text, '# Plan\n');
      expect(s.textController.text, '# Plan\n');
      await done(t);
    });
  });

  group('HomeScreen views', () {
    testWidgets('new chat opens the note; Ctrl+1/Ctrl+2 switch; split on wide windows', (t) async {
      late FakePlatform fp;
      late AppController c;
      await t.runAsync(() async {
        fp = await FakePlatform.create();
        c = AppController(
          platform: fp.services,
          confirmations: FakeConfirmations(),
          backendFactory: () => ScriptedBackend(),
          authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
        );
        await c.init();
      });
      expect(c.initError, isNull);
      await t.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: HomeScreen(controller: c),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));

      HomeView view() => (t.state(find.byType(HomeScreen)) as dynamic).view as HomeView;

      expect(view(), HomeView.note, reason: 'an empty conversation opens the note');
      expect(find.byKey(const ValueKey('note-panel')), findsOneWidget);

      await _ctrl(t, LogicalKeyboardKey.digit2);
      await t.pump(const Duration(milliseconds: 500));
      expect(view(), HomeView.chat);
      expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);

      await _ctrl(t, LogicalKeyboardKey.digit1);
      await t.pump(const Duration(milliseconds: 500));
      expect(view(), HomeView.note);

      await t.tap(find.byKey(const ValueKey('view-chat')));
      await t.pump(const Duration(milliseconds: 500));
      expect(view(), HomeView.chat);

      // Wide window: split shows both.
      await t.tap(find.byKey(const ValueKey('split-toggle')));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('note-editor-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);

      // AI note edits from the chat badge the note tab when it is hidden.
      await _ctrl(t, LogicalKeyboardKey.backslash);
      await t.pump(const Duration(milliseconds: 500));
      await _ctrl(t, LogicalKeyboardKey.digit2);
      c.notes.applyEdit(NoteEditMode.append, text: '- meeting at 3pm');
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('note-badge')), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await c.shutdown();
        await fp.dispose();
      });
      await t.pump(const Duration(seconds: 5));
    });
  });
}
