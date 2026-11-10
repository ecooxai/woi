import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/clipboard/clipboard_history.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/ui/clipboard/clipboard_panel.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/contextual_find.dart';

class _Clipboard implements ClipboardAccess, RichClipboardAccess {
  ClipboardContent? value;
  int writes = 0;
  @override
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async => value;
  @override
  Future<void> writeContent(ClipboardContent content) async {
    writes++;
    value = content;
  }

  @override
  Future<String?> readText() async => value?.text;
  @override
  Future<void> writeText(String text) => writeContent(ClipboardContent(text: text));
}

class _BackgroundClipboard extends _Clipboard implements ClipboardChangeEvents {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  bool get supportsBackgroundCapture => true;
}

class _UiHistory extends ClipboardHistoryController {
  _UiHistory({required super.clipboard, required super.directory});

  // Storage and reordering are covered by clipboard_history_test. Keep the UI
  // action test independent of real disk callbacks inside Flutter's fake clock.
  @override
  Future<void> copy(ClipboardHistoryEntry entry) => clipboard.writeContent(entry.content);
}

void main() {
  late Directory root;
  late _Clipboard clipboard;
  late ClipboardHistoryController history;
  late ClipboardHistoryEntry textEntry;
  late ClipboardHistoryEntry imageEntry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('woi-clipboard-ui-');
    clipboard = _Clipboard();
    history = _UiHistory(clipboard: clipboard, directory: root);
    textEntry = await history.remember(const ClipboardContent(text: 'Selected text with a second line\nkept exactly'));
    imageEntry = await history.remember(
      ClipboardContent(
        image: ClipboardImage(
          bytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5VEAAAAASUVORK5CYII=',
          ),
          name: 'sample.png',
        ),
      ),
    );
  });
  tearDown(() async {
    history.dispose();
    await history.flush();
    await root.delete(recursive: true);
  });

  Future<void> pumpPanel(
    WidgetTester t, {
    ContextualFindController? findController,
    double? height,
    String pasteLabel = 'Paste into chat',
    Future<void> Function(ClipboardHistoryEntry)? onPaste,
    Future<void> Function(ClipboardHistoryEntry)? onSend,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: height,
              child: ClipboardPanel(
                history: history,
                find: findController,
                pasteLabel: pasteLabel,
                onPaste: onPaste ?? (_) async {},
                onSendToAi: onSend ?? (_) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('narrow panel shows text and real image previews with destination-labelled actions', (t) async {
    final pasted = <ClipboardHistoryEntry>[];
    final sent = <ClipboardHistoryEntry>[];
    await pumpPanel(t, onPaste: (entry) async => pasted.add(entry), onSend: (entry) async => sent.add(entry));
    expect(find.byKey(ValueKey('clipboard-image-${imageEntry.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('clipboard-text-${textEntry.id}')), findsOneWidget);
    expect(find.textContaining('50 items'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('clipboard-menu-${imageEntry.id}')));
    await t.pumpAndSettle();
    expect(find.text('Paste into chat'), findsOneWidget);
    await t.tap(find.text('Send to AI'));
    await t.pumpAndSettle();
    expect(sent.single.id, imageEntry.id);
    expect(sent.single.content.image!.bytes, imageEntry.content.image!.bytes);
    expect(pasted, isEmpty);
    expect(clipboard.writes, 0, reason: 'Staging for AI does not change the clipboard.');
    await t.tap(find.byKey(ValueKey('clipboard-menu-${textEntry.id}')));
    await t.pumpAndSettle();
    await t.tap(find.text('Paste into chat'));
    await t.pumpAndSettle();
    expect(pasted.single.id, textEntry.id);
    expect(t.takeException(), isNull);
  });

  testWidgets('an open history menu keeps the destination callback represented by its label', (t) async {
    final destinations = <String>[];
    await pumpPanel(t, pasteLabel: 'Paste into note', onPaste: (_) async => destinations.add('note'));
    await t.tap(find.byKey(ValueKey('clipboard-menu-${textEntry.id}')));
    await t.pumpAndSettle();
    expect(find.text('Paste into note'), findsOneWidget);
    await pumpPanel(t, pasteLabel: 'Paste into chat', onPaste: (_) async => destinations.add('chat'));
    expect(
      find.text('Paste into note'),
      findsOneWidget,
      reason: 'The visible popup still represents its original destination.',
    );
    await t.tap(find.text('Paste into note'));
    await t.pumpAndSettle();
    expect(destinations, ['note']);
    expect(t.takeException(), isNull);
  });

  testWidgets('copy uses the selected historical entry, and search filters all saved items', (t) async {
    final findController = ContextualFindController();
    await pumpPanel(t, findController: findController);
    clipboard.value = const ClipboardContent(text: 'Unrelated newer clipboard');
    await t.tap(find.byKey(ValueKey('clipboard-menu-${textEntry.id}')));
    await t.pumpAndSettle();
    await t.tap(find.text('Copy'));
    for (var frame = 0; frame < 20; frame++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
    await t.pumpAndSettle();
    expect(clipboard.value!.text, textEntry.content.text);
    findController.setQuery('sample');
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('clipboard-image-${imageEntry.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('clipboard-text-${textEntry.id}')), findsNothing);
    expect(findController.matchCount, 1);
    await t.pumpWidget(const SizedBox.shrink());
    findController.dispose();
  });

  testWidgets('clear history requires confirmation and cancellation preserves every item', (t) async {
    await pumpPanel(t);
    await t.tap(find.byTooltip('Clipboard options'));
    await t.pumpAndSettle();
    await t.tap(find.text('Clear history…'));
    await t.pumpAndSettle();
    expect(find.text('Clear clipboard history?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(history.entries.length, 2);
    expect(clipboard.writes, 0);
  });

  testWidgets('short panel keeps populated actions, search results, empty guidance and footer reachable', (t) async {
    final findController = ContextualFindController();
    await pumpPanel(t, findController: findController, height: 220);
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
    expect(find.textContaining('Keeps the latest 50 items').hitTestable(), findsOneWidget);
    await t.tap(find.byKey(ValueKey('clipboard-menu-${imageEntry.id}')));
    await t.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Send to AI'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    findController.setQuery('no-such-saved-item');
    await t.pumpAndSettle();
    expect(findController.matchCount, 0);
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -250));
    await t.pumpAndSettle();
    expect(find.text('Try a different word or image filename.').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
    expect(find.textContaining('Keeps the latest 50 items').hitTestable(), findsOneWidget);
    findController.clear();
    await t.runAsync(history.clear);
    await t.pumpAndSettle();
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -250));
    await t.pumpAndSettle();
    final guidance = find.textContaining('Saved items stay here after restarting Woi.');
    expect(guidance, findsOneWidget);
    // A long paragraph can be taller than this viewport. Its final line must
    // be readable after scrolling while the fixed capture/footer stay visible.
    final viewport = t.getRect(find.byType(SingleChildScrollView));
    final guidanceRect = t.getRect(guidance);
    expect(guidanceRect.bottom, greaterThan(viewport.top));
    expect(guidanceRect.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
    expect(find.textContaining('Keeps the latest 50 items').hitTestable(), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    findController.dispose();
  });

  testWidgets('capture guidance follows the adapter background capability', (t) async {
    await pumpPanel(t);
    expect(find.textContaining('Captures only while Woi is focused.'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    history.dispose();
    await t.runAsync(() async {
      await history.flush();
      history = _UiHistory(clipboard: _BackgroundClipboard(), directory: root);
      await history.load();
      await history.clear();
    });
    await pumpPanel(t);
    expect(find.textContaining('Captures in the background while Woi is running.'), findsOneWidget);
    expect(find.textContaining('Copy text or an image while Woi is running'), findsOneWidget);
    expect(find.textContaining('Captures only while Woi is focused.'), findsNothing);
  });
}
