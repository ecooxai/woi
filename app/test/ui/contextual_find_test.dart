import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/core/terminal/term_process.dart';
import 'package:woi/core/terminal/terminal_hub.dart';
import 'package:woi/ui/notes/note_editor.dart';
import 'package:woi/ui/terminal/terminal_panel.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/chat_transcript.dart';
import 'package:woi/ui/widgets/contextual_find.dart';
import 'package:xterm/xterm.dart';

class _Process implements TermProcess {
  _Process(this.pid);
  @override
  final int pid;
  final out = StreamController<Uint8List>();
  final exit = Completer<int>();
  final input = StringBuffer();
  @override
  Stream<Uint8List> get output => out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) => input.write(utf8.decode(data));
  @override
  void resize(int rows, int columns) {}
  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(0);
    unawaited(out.close());
  }
}

Future<void> _host(
  WidgetTester tester, {
  required ContextualFindController controller,
  required Widget child,
  String label = 'note',
  Size size = const Size(720, 800),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildWoiTheme(),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const Spacer(),
                  ContextualFindButton(find: controller, label: label, size: 48),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _query(WidgetTester tester, String query) async {
  final input = find.byKey(const ValueKey('contextual-find-input'));
  if (input.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('contextual-find-button')));
    await tester.pump();
  }
  await tester.enterText(input, query);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

bool _inputFocused(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: find.byKey(const ValueKey('contextual-find-input')), matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

void main() {
  test('literal search keeps original Unicode offsets and ignores empty queries', () {
    const text = '界🙂 [a.b] and [A.B]';
    final matches = findTextRanges(text, '[a.b]');
    expect(matches, hasLength(2));
    expect(matches.map((range) => text.substring(range.start, range.end)), ['[a.b]', '[A.B]']);
    expect(findTextRanges(text, '  '), isEmpty);
    expect(findTextRanges(text, 'a.*b'), isEmpty);
  });

  test('terminal matches join wrapped rows and map wide characters to cells', () {
    final wrapped = Terminal(maxLines: 100)..resize(8, 3);
    wrapped.write('abc界defneedle');
    final wrappedMatches = findTerminalMatches(wrapped, 'defneedle');
    expect(wrappedMatches, hasLength(1));
    expect(wrappedMatches.single.start, const CellOffset(5, 0));
    expect(wrappedMatches.single.end.y, greaterThan(0));

    final unicode = Terminal()..resize(20, 3);
    unicode.write('界 abc');
    final match = findTerminalMatches(unicode, 'ABC').single;
    expect(match.start, const CellOffset(3, 0));
    expect(match.end, const CellOffset(6, 0));
    expect(findTerminalMatches(unicode, ''), isEmpty);
  });

  for (final width in [320.0, 600.0, 1200.0]) {
    testWidgets('floating input is anchored and navigable at width $width', (tester) async {
      final controller = ContextualFindController();
      addTearDown(controller.dispose);
      final owner = Object();
      final selected = <int>[];
      controller.attach(
        owner,
        onQuery: () => controller.setMatches(findTextRanges('needle and NEEDLE', controller.query).length),
        onNavigate: selected.add,
      );
      await _host(tester, controller: controller, child: const SizedBox(), size: Size(width, 700));
      await _query(tester, 'needle');
      final button = tester.getRect(find.byKey(const ValueKey('contextual-find-button')));
      final popup = tester.getRect(find.byKey(const ValueKey('contextual-find-popover')));
      expect(popup.top, greaterThanOrEqualTo(button.bottom));
      expect(popup.left, greaterThanOrEqualTo(0));
      expect(popup.right, lessThanOrEqualTo(width));
      expect(controller.matchCount, 2);
      expect(_inputFocused(tester), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.currentMatch, 1, reason: 'Enter advances exactly once.');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(controller.currentMatch, 0);
      await tester.tap(find.byKey(const ValueKey('contextual-find-next')));
      await tester.pump();
      expect(controller.currentMatch, 1);
      expect(_inputFocused(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('contextual-find-clear')));
      await tester.pump();
      expect(controller.query, isEmpty);
      expect(controller.matchCount, 0);
      expect(_inputFocused(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('contextual-find-popover')), findsNothing);
      expect(selected, containsAllInOrder([0, 1, 0, 1]));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('note search selects exact text, scrolls, preserves focus, and restores preview', (tester) async {
    final dir = Directory.systemTemp.createTempSync('woi_find_note_');
    final notes = NoteController(store: NoteStore(dir.path), autosaveDelay: const Duration(days: 1));
    final controller = ContextualFindController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(notes.flush);
      notes.dispose();
      controller.dispose();
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() => notes.open('find-note'));
    final text = '# Plan\nneedle first\n${List.filled(70, 'ordinary line').join('\n')}\nNEEDLE last';
    notes.setText(text);
    await _host(
      tester,
      controller: controller,
      child: NoteEditor(notes: notes, find: controller, initialMode: NoteViewMode.preview),
    );
    await _query(tester, 'needle');
    final editor = tester.state<NoteEditorState>(find.byType(NoteEditor));
    expect(controller.matchCount, 2);
    expect(editor.mode, NoteViewMode.edit);
    expect(editor.textController.selection.textInside(text), 'needle');
    expect(_inputFocused(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('contextual-find-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(editor.textController.selection.textInside(text), 'NEEDLE');
    final field = tester.widget<TextField>(find.byKey(const ValueKey('note-editor-field')));
    expect(field.scrollController!.offset, greaterThan(0));
    expect(_inputFocused(tester), isTrue);
    expect(notes.text, text, reason: 'Finding must never change the note text.');

    await _query(tester, 'not-present-anywhere');
    expect(controller.matchCount, 0);
    expect(editor.textController.selection.isCollapsed, isTrue);
    await tester.tap(find.byKey(const ValueKey('contextual-find-clear')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(editor.mode, NoteViewMode.preview);
    expect(notes.text, text);
    expect(tester.takeException(), isNull);
    await tester.runAsync(notes.flush);
  });

  testWidgets('terminal search reveals scrollback, keeps input out of the shell, and clears stale results', (
    tester,
  ) async {
    final processes = <_Process>[];
    final hub = TerminalHub(
      starter: (exe, args, {workingDirectory, environment, rows = 24, columns = 80}) {
        final process = _Process(1000 + processes.length);
        processes.add(process);
        return process;
      },
      shell: '/bin/sh',
      workingDirectory: () => '/tmp',
      codexDir: null,
    );
    final controller = ContextualFindController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      controller.dispose();
      await tester.pump(const Duration(seconds: 1));
    });
    await _host(
      tester,
      controller: controller,
      label: 'terminal',
      child: TerminalPanel(hub: hub, find: controller, hardwareKeyboardOnly: true),
    );
    await tester.pump();
    final first = hub.active!;
    first.terminal.write('needle first\r\n${List.filled(150, 'ordinary output').join('\r\n')}\r\nlast NEEDLE\r\n');
    await tester.pump();
    await _query(tester, 'needle');
    expect(controller.matchCount, 2);
    expect(first.controller.highlights, hasLength(1));
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    final scroll = terminal.scrollController!;
    final firstOffset = scroll.offset;
    expect(firstOffset, lessThan(scroll.position.maxScrollExtent));
    expect(_inputFocused(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.currentMatch, 1);
    expect(scroll.offset, greaterThan(firstOffset));
    expect(processes.first.input.toString(), isEmpty);
    expect(_inputFocused(tester), isTrue);
    await _query(tester, 'missing-from-buffer');
    expect(controller.matchCount, 0);
    expect(first.controller.highlights, isEmpty);

    await _query(tester, 'needle');
    hub.newShell();
    await tester.pump();
    expect(controller.matchCount, 0);
    expect(first.controller.highlights, isEmpty);
    expect(hub.active!.controller.highlights, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('message search reaches old occurrences, follows streamed text, and restores the normal window', (
    tester,
  ) async {
    final messages = [
      for (var i = 0; i < 260; i++)
        Message(id: 'm$i', kind: MessageKind.user, text: 'message $i', createdAt: DateTime(2026, 1, 1)),
    ];
    messages.first.text = 'old needle and NEEDLE';
    messages.last.text = 'latest Needle';
    final changes = ValueNotifier(0);
    final controller = ContextualFindController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      changes.dispose();
      controller.dispose();
    });
    await _host(
      tester,
      controller: controller,
      label: 'messages',
      child: ChatTranscript(
        conversationId: 'c',
        messages: messages,
        find: controller,
        textChanges: changes,
        tileBuilder: (_, message, _) => SizedBox(height: 48, child: Text(message.text)),
      ),
    );
    expect(find.text('old needle and NEEDLE'), findsNothing);
    await _query(tester, 'needle');
    expect(controller.matchCount, 3);
    expect(find.text('old needle and NEEDLE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('contextual-find-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.currentMatch, 1);
    final current = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey('chat-find-current')), matching: find.byType(Text)),
    );
    expect(current.textSpan!.toPlainText(), contains('old needle and NEEDLE'));
    expect(_inputFocused(tester), isTrue);

    messages.last.text = 'latest text changed';
    changes.value++;
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(controller.matchCount, 2);
    await _query(tester, 'no matching message');
    expect(controller.matchCount, 0);
    expect(find.byKey(const ValueKey('chat-find-empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('contextual-find-clear')));
    await tester.pump();
    expect(tester.state<ChatTranscriptState>(find.byType(ChatTranscript)).renderedCount, kTranscriptInitialWindow);
    expect(find.text('old needle and NEEDLE'), findsNothing);
    expect(find.text('latest text changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
