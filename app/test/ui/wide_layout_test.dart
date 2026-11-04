import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/theme.dart';

import '../fakes/fakes.dart';

/// Wide windows dock the chat on the right; narrow ones keep the tabs.
void main() {
  late FakePlatform fp;
  late AppController c;

  Future<void> settle(WidgetTester t, [int n = 20]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> start(WidgetTester t, Size size) async {
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
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.runAsync(() async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: HomeScreen(controller: c),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(t);
  }

  Future<void> stop(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await c.shutdown();
      await fp.dispose();
    });
    await t.pump(const Duration(seconds: 5));
  }

  Future<void> tapIo(WidgetTester t, String key) async {
    await t.runAsync(() async {
      await t.tap(find.byKey(ValueKey(key)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(t, 30);
  }

  testWidgets('wide: note and chat side by side; chat stays when switching to Settings and Terminal', (t) async {
    await start(t, const Size(1400, 860));
    expect(find.byKey(const ValueKey('note-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('input-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('view-chat')), findsNothing, reason: 'the chat is always shown');
    // The chat pane (with the composer) is on the right.
    final chat = t.getRect(find.byKey(const ValueKey('chat-pane')));
    expect(chat.left, greaterThan(700));
    expect(chat.contains(t.getCenter(find.byKey(const ValueKey('input-bar')))), isTrue);

    await tapIo(t, 'view-settings');
    expect(find.byKey(const ValueKey('settings-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-panel')), findsNothing);

    await tapIo(t, 'view-terminal');
    expect(find.byKey(const ValueKey('terminal-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);

    // Voice / Ctrl+2 "chat" keeps the left pane and just focuses the input.
    c.actions.showView(HomeView.chat);
    await settle(t);
    expect(find.byKey(const ValueKey('terminal-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    await stop(t);
  });

  testWidgets('narrow: tabs as before, one view at a time', (t) async {
    await start(t, const Size(420, 860));
    expect(find.byKey(const ValueKey('view-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-divider')), findsNothing);
    expect(find.byKey(const ValueKey('note-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsNothing);
    await tapIo(t, 'view-chat');
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-panel')), findsNothing);
    await tapIo(t, 'view-settings');
    expect(find.byKey(const ValueKey('settings-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsNothing);
    await stop(t);
  });

  testWidgets('divider drag updates and persists the chat fraction; double-click resets', (t) async {
    await start(t, const Size(1400, 860));
    final before = t.getSize(find.byKey(const ValueKey('chat-pane'))).width;
    expect(before, closeTo(1400 * kDefaultChatPaneFraction, 2));
    await t.runAsync(() async {
      await t.drag(find.byKey(const ValueKey('pane-divider')), const Offset(-140, 0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(t);
    final after = t.getSize(find.byKey(const ValueKey('chat-pane'))).width;
    expect(after, greaterThan(before + 100));
    expect(c.settings.chatPaneFraction, closeTo(after / 1400, 0.01));

    // Clamped at the maximum.
    await t.runAsync(() async {
      await t.drag(find.byKey(const ValueKey('pane-divider')), const Offset(-1000, 0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(t);
    expect(c.settings.chatPaneFraction, closeTo(kChatPaneMaxFraction, 0.001));

    // Double-click resets.
    final div = find.byKey(const ValueKey('pane-divider'));
    await t.tap(div);
    await t.pump(const Duration(milliseconds: 50));
    await t.runAsync(() async {
      await t.tap(div);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(t);
    expect(c.settings.chatPaneFraction, closeTo(kDefaultChatPaneFraction, 0.001));
    await stop(t);
  });

  testWidgets('resizing wide <-> narrow keeps the editor and composer state', (t) async {
    await start(t, const Size(1400, 860));
    final editor = find.byKey(const ValueKey('note-editor-field'));
    await t.enterText(editor, '# Kept\n\nhello');
    await t.enterText(find.byKey(const ValueKey('composer-field')), 'draft');
    await t.pump();
    final editorState = t.state(find.byKey(const ValueKey('note-editor')));

    await t.binding.setSurfaceSize(const Size(600, 860));
    await settle(t);
    expect(find.byKey(const ValueKey('pane-divider')), findsNothing);
    expect(t.state(find.byKey(const ValueKey('note-editor'))), same(editorState), reason: 'reparented, not rebuilt');
    expect(find.text('draft'), findsOneWidget);

    await t.binding.setSurfaceSize(const Size(1400, 860));
    await settle(t);
    expect(t.state(find.byKey(const ValueKey('note-editor'))), same(editorState));
    expect(find.text('draft'), findsOneWidget);
    await stop(t);
  });
}
