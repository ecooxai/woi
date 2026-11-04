import 'dart:io';

import 'package:flutter/gestures.dart';
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

    testWidgets('typing goes to the note; word count; no mode icons; preview via the Format menu', (t) async {
      await t.runAsync(() => notes.open('c1'));
      final s = await pump(t);
      await t.enterText(find.byKey(const ValueKey('note-editor-field')), '# Plan\n\nmeeting at 3pm');
      await t.pump();
      expect(notes.text, '# Plan\n\nmeeting at 3pm');
      expect(find.textContaining('4 words'), findsOneWidget);
      // No edit/preview icon toggle in the top bar.
      for (final k in ['note-mode-edit', 'note-mode-split', 'note-mode-preview']) {
        expect(find.byKey(ValueKey(k)), findsNothing);
      }

      await t.tap(find.byKey(const ValueKey('note-format')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('fmt-preview')));
      await t.pumpAndSettle();
      expect(s.mode, NoteViewMode.preview);
      expect(find.byKey(const ValueKey('note-preview')), findsOneWidget);
      // Esc goes back to the source.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(s.mode, NoteViewMode.edit);
      expect(find.byKey(const ValueKey('note-editor-field')), findsOneWidget);
      // Ctrl+Shift+P toggles it from the editor.
      await t.tap(find.byKey(const ValueKey('note-editor-field')));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyP);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(s.mode, NoteViewMode.preview);
      await t.tap(find.byKey(const ValueKey('note-preview-close')));
      await t.pumpAndSettle();
      expect(s.mode, NoteViewMode.edit);
      await done(t);
    });

    testWidgets('Format: one dropdown with every format and its shortcut', (t) async {
      await t.runAsync(() => notes.open('c1'));
      notes.setText('todo\nmilk');
      final s = await pump(t);
      s.textController.selection = const TextSelection(baseOffset: 0, extentOffset: 9);
      await t.tap(find.byKey(const ValueKey('note-format')));
      await t.pumpAndSettle();
      for (final f in NoteFormat.values) {
        expect(find.byKey(ValueKey('fmt-${f.name}')), findsOneWidget, reason: f.name);
      }
      expect(find.text('Ctrl+B'), findsOneWidget);
      expect(find.text('Ctrl+Shift+X'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('fmt-check')));
      await t.pumpAndSettle();
      expect(notes.text, '- [ ] todo\n- [ ] milk');
      // Only the Format button holds formats: no separate format icons.
      expect(find.byIcon(Icons.format_bold_rounded), findsNothing);

      s.textController.selection = const TextSelection.collapsed(offset: 3);
      await t.tap(find.byKey(const ValueKey('note-format')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('fmt-h2')));
      await t.pumpAndSettle();
      expect(notes.text, '## - [ ] todo\n- [ ] milk');
      // Shortcut: Ctrl+Alt+2 again turns the heading off.
      await t.tap(find.byKey(const ValueKey('note-editor-field')));
      s.textController.selection = const TextSelection.collapsed(offset: 4);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.digit2);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(notes.text, '- [ ] todo\n- [ ] milk');
      await done(t);
    });

    testWidgets('Copy: click copies the note; right-click / long-press menu copies line, paragraph, section', (t) async {
      final clip = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await t.runAsync(() => notes.open('c1'));
      const text = '# A\none\ntwo\n\nthree\n# B\nfour';
      notes.setText(text);
      final s = await pump(t);
      s.textController.selection = const TextSelection.collapsed(offset: 5); // "one"

      await t.tap(find.byKey(const ValueKey('note-copy')));
      await t.pump();
      expect(clip.last, text);
      expect(find.byKey(const ValueKey('note-copied')), findsOneWidget);
      expect(find.text('Copied'), findsOneWidget, reason: 'the button confirms');

      await t.tap(find.byKey(const ValueKey('note-copy')), buttons: kSecondaryButton);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('copy-line')));
      await t.pumpAndSettle();
      expect(clip.last, 'one');

      await t.longPress(find.byKey(const ValueKey('note-copy')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('copy-paragraph')));
      await t.pump();
      expect(clip.last, '# A\none\ntwo');
      expect(s.copyLabel, 'Copied paragraph (3 lines)');

      await t.longPress(find.byKey(const ValueKey('note-copy')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('copy-section')));
      await t.pump();
      expect(clip.last, '# A\none\ntwo\n\nthree');
      await t.pump(const Duration(seconds: 2));
      expect(s.copyLabel, isNull, reason: 'the confirmation is brief');
      await done(t);
    });

    testWidgets('toolbar fits a 360 px phone pane', (t) async {
      await t.runAsync(() => notes.open('c1'));
      await t.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: NoteEditor(notes: notes, compact: true, onRun: (_) {}),
          ),
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      for (final k in ['note-format', 'tb-undo', 'note-copy', 'note-run']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
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
