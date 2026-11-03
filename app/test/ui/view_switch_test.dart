import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/theme.dart';

import '../fakes/fakes.dart';

void main() {
  testWidgets('view switch and split still work after settings and a fatal backend error', (t) async {
    late FakePlatform fp;
    late AppController c;
    ScriptedBackend? backend;
    await t.runAsync(() async {
      fp = await FakePlatform.create();
      c = AppController(
        platform: fp.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => backend = ScriptedBackend(),
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
      );
      await c.init();
    });
    await t.binding.setSurfaceSize(const Size(1600, 900));
    await t.runAsync(() async {
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: HomeScreen(controller: c),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.tap(find.byKey(const ValueKey('view-chat')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('open-settings')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.tap(find.byIcon(Icons.arrow_back_rounded).first);
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 20));
    }
    backend!.emit(const BackendError('gpt-live session ended (1006 )', fatal: true));
    for (var i = 0; i < 20; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.tap(find.byKey(const ValueKey('view-note')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('note-panel')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('split-toggle')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await c.shutdown();
      await fp.dispose();
    });
    await t.pump(const Duration(seconds: 5));
  });
}
