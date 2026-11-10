import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/ui/notes/note_editor.dart';
import 'package:woi/ui/notes/note_image_preview.dart';
import 'package:woi/ui/theme.dart';

class _Clipboard implements ClipboardAccess, RichClipboardAccess {
  ClipboardContent? content;
  String? copied;
  bool denied = false;
  Completer<ClipboardContent?>? delayedRead;
  @override
  Future<String?> readText() async => content?.text;
  @override
  Future<void> writeText(String text) async {
    if (denied) throw StateError('Synthetic clipboard denial');
    copied = text;
  }

  @override
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async =>
      delayedRead == null ? content : await delayedRead!.future;
  @override
  Future<void> writeContent(ClipboardContent value) async => content = value;
}

void main() {
  late Directory directory;
  late NoteController notes;
  late _Clipboard clipboard;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('woi_note_clipboard_');
    notes = NoteController(store: NoteStore(directory.path), autosaveDelay: const Duration(days: 1));
    clipboard = _Clipboard();
  });
  tearDown(() {
    notes.dispose();
    directory.deleteSync(recursive: true);
  });
  Future<NoteEditorState> pump(WidgetTester tester, {Future<String> Function(ClipboardImage)? onPasteImage}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          body: NoteEditor(
            notes: notes,
            clipboard: clipboard,
            onPasteImage: onPasteImage,
            initialMode: NoteViewMode.edit,
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<NoteEditorState>(find.byType(NoteEditor));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.runAsync(notes.flush);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('Android long press selects the current word and Copy uses the native adapter', (tester) async {
    notes.setText('alpha **bravo** charlie');
    final state = await pump(tester);
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final render = editable.renderEditable;
    final point = render.localToGlobal(render.getLocalRectForCaret(const TextPosition(offset: 10)).center);
    await tester.longPressAt(point);
    await tester.pumpAndSettle();
    expect(state.textController.selection.textInside(notes.text), 'bravo');
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AdaptiveTextSelectionToolbar), matching: find.text('Copy')));
    await tester.pump();
    expect(clipboard.copied, 'bravo');
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('image-only clipboard still offers Paste in a blank Android note', (tester) async {
    clipboard.content = ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1, 2, 3])));
    final state = await pump(tester, onPasteImage: (_) async => '![test](file:///synthetic/test.png)');
    await tester.longPressAt(tester.getTopLeft(find.byKey(const ValueKey('note-editor-field'))) + const Offset(55, 40));
    await tester.pumpAndSettle();
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    expect(notes.text, '![test](file:///synthetic/test.png)');
    expect(state.textController.selection.isCollapsed, isTrue);
    await finish(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('paste replaces only the saved range, is undoable, and survives tab remount', (tester) async {
    notes.setText('alpha bravo charlie');
    notes.breakUndoGroup();
    final state = await pump(tester);
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    await finish(tester);
    expect((notes.selectionStart, notes.selectionEnd), (6, 11));
    notes.replaceSelection('雪');
    expect(notes.text, 'alpha 雪 charlie');
    final next = await pump(tester);
    expect(next.textController.selection, const TextSelection.collapsed(offset: 7));
    notes.undo();
    expect(notes.text, 'alpha bravo charlie');
    await finish(tester);
  });

  testWidgets('image paste keeps the surrounding text and places the caret after its editable link', (tester) async {
    notes.setText('alpha bravo charlie');
    final state = await pump(tester, onPasteImage: (_) async => '![tiny](file:///synthetic/tiny.png)');
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    await state.pasteContent(ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1]))));
    await tester.pump();
    expect(notes.text, 'alpha ![tiny](file:///synthetic/tiny.png) charlie');
    expect(state.textController.selection.extentOffset, notes.text.indexOf(' charlie'));
    expect(find.byKey(const ValueKey('note-source-image-previews')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('clipboard focus handoff pastes into the original selection', (tester) async {
    notes.setText('alpha bravo charlie');
    final state = await pump(tester);
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    clipboard.delayedRead = Completer<ClipboardContent?>();
    final paste = state.paste();
    state.textController.selection = const TextSelection.collapsed(offset: 0);
    clipboard.delayedRead!.complete(const ClipboardContent(text: 'snow'));
    await paste;
    expect(notes.text, 'alpha snow charlie');
    expect(state.textController.selection.extentOffset, 10);
    await finish(tester);
  });

  testWidgets('image preparation preserves its original paste range after caret movement', (tester) async {
    notes.setText('alpha bravo charlie');
    final save = Completer<String>();
    final state = await pump(tester, onPasteImage: (_) => save.future);
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    final paste = state.pasteContent(ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1]))));
    state.textController.selection = const TextSelection.collapsed(offset: 0);
    save.complete('![tiny](file:///synthetic/tiny.png)');
    await paste;
    expect(notes.text, 'alpha ![tiny](file:///synthetic/tiny.png) charlie');
    await finish(tester);
  });

  testWidgets('an edit during image preparation rejects the delayed paste without changing text', (tester) async {
    notes.setText('alpha bravo charlie');
    final save = Completer<String>();
    final state = await pump(tester, onPasteImage: (_) => save.future);
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    final paste = state.pasteContent(ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1]))));
    final rejected = expectLater(paste, throwsStateError);
    state.textController.value = const TextEditingValue(
      text: 'User kept typing',
      selection: TextSelection.collapsed(offset: 16),
    );
    save.complete('![tiny](file:///synthetic/tiny.png)');
    await rejected;
    expect(notes.text, 'User kept typing');
    await finish(tester);
  });

  testWidgets('failed cut retains selected text and reports the clipboard failure', (tester) async {
    notes.setText('alpha bravo');
    final state = await pump(tester);
    state.textController.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    clipboard.denied = true;
    await state.copySelection(cut: true);
    await tester.pump();
    expect(notes.text, 'alpha bravo');
    expect(state.copyLabel, contains('Copy failed'));
    await finish(tester);
  });

  test('image links with query strings are recognized and code fences are ignored', () {
    expect(
      noteImageTargets(
        '![a](file:///tmp/a.png)\n[x](https://example.test/p.jpg?version=2#x)\n```\nhttps://example.test/hidden.png\n```',
      ),
      ['file:///tmp/a.png', 'https://example.test/p.jpg?version=2#x'],
    );
  });
}
