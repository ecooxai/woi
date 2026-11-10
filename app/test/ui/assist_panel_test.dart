import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/ui/assist/assist_panel.dart';
import 'package:woi/ui/screens/history_drawer.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/input_bar.dart';
import 'package:woi/ui/widgets/controls.dart';

import '../fakes/fakes.dart';

const _screen = Size(400, 800);

class _Env {
  late FakePlatform fp;
  late AppController c;
  final dismissed = <int>[];
  final opened = <int>[];
  final fractions = <double>[];
  Completer<void>? reconnectGate;

  Future<void> start(WidgetTester t, {bool mobile = false}) async {
    await t.runAsync(() async {
      fp = await FakePlatform.create();
      final s = fp.services;
      c = AppController(
        platform: mobile
            ? PlatformServices(
                paths: s.paths,
                audio: s.audio,
                screen: s.screen,
                input: s.input,
                shell: s.shell,
                files: s.files,
                viewer: s.viewer,
                isMobile: true,
              )
            : s,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend()..connectGate = reconnectGate,
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
      );
      await c.init();
    });
  }

  Widget panel({double fraction = kAssistPanelDefault}) => AssistPanel(
    controller: c,
    initialFraction: fraction,
    onDismiss: () => dismissed.add(1),
    onOpenApp: () => opened.add(1),
    onFractionChanged: fractions.add,
  );

  Future<void> pump(WidgetTester t, {double fraction = kAssistPanelDefault}) async {
    await t.binding.setSurfaceSize(_screen);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: panel(fraction: fraction),
        ),
      ),
    );
    await t.pump();
  }

  Future<void> stop(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await c.shutdown();
      await fp.dispose();
    });
    await t.pump(const Duration(seconds: 5));
  }
}

/// Alternates real time (IO) and fake time (timers, microtasks).
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 20));
  }
}

double _panelHeight(WidgetTester t) => t.getSize(find.byKey(const ValueKey('assist-panel'))).height;

void main() {
  testWidgets('panel takes 60% of the screen by default, bottom-anchored, with the compact UI', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);

    expect(_panelHeight(t), closeTo(_screen.height * 0.6, 0.5));
    final rect = t.getRect(find.byKey(const ValueKey('assist-panel')));
    expect(rect.bottom, _screen.height);
    expect(find.byType(InputBar), findsOneWidget);
    // No close button or screenshot thumbnail; history and open-in-app sit
    // in the dropdown at the right of the tab row.
    expect(find.byKey(const ValueKey('more-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('assist-close')), findsNothing);
    expect(find.byKey(const ValueKey('assist-thumbnail')), findsNothing);
    expect(find.byKey(const ValueKey('assist-open-app')), findsNothing);
    // The main app's tab UI, on the Chat tab.
    expect(find.byType(WoiTabs), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    await env.stop(t);
  });

  testWidgets('hosts all five main tabs with stable shortcuts; the app tab is untouched', (t) async {
    final env = _Env();
    await env.start(t);
    final appView = env.c.actions.view.value;
    final seen = <HomeView>[];
    await t.binding.setSurfaceSize(_screen);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: AssistPanel(controller: env.c, onDismiss: () {}, onOpenApp: () {}, onViewChanged: seen.add),
        ),
      ),
    );
    await t.pump();
    for (final (label, shortcut) in [('Note', 1), ('Chat', 2), ('Terminal', 3), ('Clipboard', 5), ('Settings', 4)]) {
      expect(find.byTooltip('$label (Ctrl+$shortcut)'), findsOneWidget);
    }
    final tabs = find.byKey(const ValueKey('assist-tabs'));
    await t.tap(find.descendant(of: tabs, matching: find.byTooltip('Note (Ctrl+1)')));
    await t.pump();
    expect(find.byKey(const ValueKey('note-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsNothing);

    await t.runAsync(() async {
      await t.tap(find.descendant(of: tabs, matching: find.byTooltip('Terminal (Ctrl+3)')));
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    expect(find.byKey(const ValueKey('terminal-view')), findsOneWidget);

    final clipboardTab = find.descendant(of: tabs, matching: find.byKey(const ValueKey('view-clipboard')));
    await t.ensureVisible(clipboardTab);
    await t.pump();
    await t.tap(clipboardTab);
    await t.pump();
    expect(find.byKey(const ValueKey('clipboard-view')), findsOneWidget);
    expect(find.textContaining('Keeps the latest 50 items').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('contextual-find-button')));
    await t.pump();
    expect(find.byKey(const ValueKey('contextual-find-input')).hitTestable(), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('contextual-find-input')), 'missing clipboard item');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(t.takeException(), isNull);

    final settingsTab = find.descendant(of: tabs, matching: find.byKey(const ValueKey('view-settings')));
    await t.ensureVisible(settingsTab);
    await t.pump();
    await t.tap(settingsTab);
    await t.pump();
    expect(find.byKey(const ValueKey('settings-view')), findsOneWidget);
    expect(seen, [HomeView.note, HomeView.terminal, HomeView.clipboard, HomeView.settings]);
    // The full app's selected tab is kept apart.
    expect(env.c.actions.view.value, appView);

    // Voice still switches the panel's tab.
    env.c.actions.showView(appView == HomeView.chat ? HomeView.note : HomeView.chat);
    await t.pump();
    expect(seen.last, env.c.actions.view.value);
    await env.stop(t);
  });

  testWidgets('starts on the remembered tab; dragging the tab strip row resizes too', (t) async {
    final env = _Env();
    await env.start(t);
    await t.binding.setSurfaceSize(_screen);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: AssistPanel(
            controller: env.c,
            initialView: HomeView.note,
            onDismiss: () {},
            onOpenApp: () {},
            onFractionChanged: env.fractions.add,
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('note-editor')), findsOneWidget);
    await t.drag(find.byKey(const ValueKey('more-menu')), const Offset(0, -600));
    await t.pumpAndSettle();
    expect(_panelHeight(t), closeTo(_screen.height * kAssistPanelMax, 0.5));
    await env.stop(t);
  });

  testWidgets('soft keyboard: the panel moves up above it and keeps its UI', (t) async {
    final env = _Env();
    await env.start(t);
    await t.binding.setSurfaceSize(_screen);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              backgroundColor: Colors.transparent,
              body: AssistPanel(controller: env.c, initialView: HomeView.note, onDismiss: () {}, onOpenApp: () {}),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final rect = t.getRect(find.byKey(const ValueKey('assist-panel')));
    expect(rect.bottom, _screen.height - 300);
    expect(find.byKey(const ValueKey('note-editor')), findsOneWidget);
    expect(find.byType(InputBar), findsOneWidget);
    expect(t.takeException(), isNull);
    await env.stop(t);
  });

  for (final (size, keyboard) in [(const Size(400, 800), 300.0), (const Size(393, 572), 260.0)]) {
    testWidgets('keyboard with three attachments keeps assistant actions reachable at ${size.width}x${size.height}', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final image = Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3)));
      var picks = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('woi/files'),
        (call) async {
          expect(call.method, 'pickFiles');
          picks++;
          return [
            {'bytes': image, 'name': 'selected.png', 'mimeType': 'image/png'},
            {'bytes': Uint8List.fromList(utf8.encode('Synthetic note')), 'name': 'notes.txt', 'mimeType': 'text/plain'},
            {'bytes': Uint8List.fromList(utf8.encode('{}')), 'name': 'data.json', 'mimeType': 'application/json'},
          ];
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('woi/files'),
          null,
        ),
      );
      final insets = ValueNotifier<double>(keyboard);
      addTearDown(insets.dispose);
      final env = _Env();
      await env.start(t, mobile: true);
      Future<void>? connecting;
      try {
        await t.binding.setSurfaceSize(size);
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(
          MaterialApp(
            theme: buildWoiTheme(),
            home: ValueListenableBuilder<double>(
              valueListenable: insets,
              builder: (context, inset, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
                child: Scaffold(
                  resizeToAvoidBottomInset: false,
                  backgroundColor: Colors.transparent,
                  body: AssistPanel(controller: env.c, initialView: HomeView.note, onDismiss: () {}, onOpenApp: () {}),
                ),
              ),
            ),
          ),
        );
        await _settle(t);
        final draft = t.widget<InputBar>(find.byType(InputBar)).draft!;
        draft.insertText('Review these three files');
        await t.pump();
        await t.tap(find.byKey(const ValueKey('attach-files')));
        await _settle(t);
        expect(picks, 1);
        expect(draft.attachments, hasLength(3));
        expect(t.takeException(), isNull, reason: 'The populated composer must fit above the keyboard.');
        final composerState = t.state(find.byType(Composer));
        final focus = t.widget<InputBar>(find.byType(InputBar)).focusNode!;
        final selected = draft.text.selection;

        Future<void> choose(String view, {TextSelection? keepSelection}) async {
          final tab = find.byKey(ValueKey('view-$view'));
          await t.ensureVisible(tab);
          await t.tap(tab);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: 'The $view pane must remain usable with keyboard and attachments.');
          expect(draft.text.selection, keepSelection ?? selected);
          if (view == 'clipboard') {
            expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
          } else {
            expect(find.byKey(const ValueKey('note-editor-field')).hitTestable(), findsOneWidget);
          }
        }

        void expectActions({bool pending = false}) {
          final panel = t.getRect(find.byKey(const ValueKey('assist-panel')));
          for (final key in ['attach-files', 'camera-toggle', pending ? 'stop' : 'send']) {
            final button = find.byKey(ValueKey(key));
            expect(button.hitTestable(), findsOneWidget, reason: '$key is reachable above the keyboard.');
            final rect = t.getRect(button);
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.top, greaterThanOrEqualTo(panel.top));
            expect(rect.bottom, lessThanOrEqualTo(panel.bottom + 0.5));
          }
        }

        await choose('clipboard');
        final scrollbar = find.byKey(const ValueKey('narrow-content-scrollbar'));
        final bar = t.widget<Scrollbar>(scrollbar);
        expect(bar.thumbVisibility, isTrue);
        expect(bar.interactive, isTrue);
        final scroll = bar.controller!;
        expect(
          scroll.position.pixels,
          closeTo(0, 0.5),
          reason: 'A selected pane must stay in view after focus settles.',
        );
        final headerTop = t.getRect(find.byKey(const ValueKey('view-clipboard'))).top;
        final scrollRect = t.getRect(scrollbar);
        await t.dragFrom(Offset(scrollRect.right - 3, scrollRect.top + 10), Offset(0, scrollRect.height - 20));
        await t.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0), reason: 'The visible thumb accepts a real touch drag.');
        expectActions();
        expect(t.getRect(find.byKey(const ValueKey('view-clipboard'))).top, headerTop);

        await choose('note');
        await choose('clipboard');
        final beforeSwipe = scroll.position.pixels;
        expect(find.text('3 attachments').hitTestable(), findsOneWidget);
        await t.drag(find.text('3 attachments'), const Offset(0, -320));
        await t.pumpAndSettle();
        expect(
          scroll.position.pixels,
          greaterThan(beforeSwipe),
          reason: 'An ordinary visible region scrolls the outer content.',
        );
        expectActions();

        final tray = find.byKey(const ValueKey('chat-attachments-scroll'));
        await t.ensureVisible(tray);
        await t.pumpAndSettle();
        await t.drag(tray, const Offset(-500, 0));
        await t.pumpAndSettle();
        final remove = find.byKey(const ValueKey('remove-chat-attachment-2'));
        expect(remove.hitTestable(), findsOneWidget);
        expect(t.getSize(remove).width, greaterThanOrEqualTo(48));
        await t.tap(remove);
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('2 attachments'));
        await t.pumpAndSettle();
        expect(find.text('2 attachments').hitTestable(), findsOneWidget);
        expect(draft.attachments, hasLength(2));

        await choose('note');
        await choose('clipboard');
        await t.tap(find.byKey(const ValueKey('contextual-find-button')));
        await t.pump();
        await t.enterText(find.byKey(const ValueKey('contextual-find-input')), 'missing clipboard item');
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: 'Search chrome must leave the Clipboard pane its usable height.');
        expect(find.byKey(const ValueKey('clipboard-capture')).hitTestable(), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('contextual-find-input')), '');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        await choose('note');

        final field = find.byKey(const ValueKey('composer-field'));
        await t.ensureVisible(field);
        await t.tap(field);
        draft.text.selection = const TextSelection(baseOffset: 7, extentOffset: 12);
        await t.pumpAndSettle();
        final selection = draft.text.selection;
        expect(focus.hasFocus, isTrue);
        expect(field.hitTestable(), findsOneWidget);

        Future<void> resize(bool large) async {
          await t.binding.setSurfaceSize(large ? Size(size.width, 1100) : size);
          insets.value = large ? 0 : keyboard;
          await _settle(t);
          expect(t.takeException(), isNull);
          expect(identical(t.state(find.byType(Composer)), composerState), isTrue);
          expect(identical(t.widget<InputBar>(find.byType(InputBar)).draft, draft), isTrue);
          expect(draft.text.text, 'Review these three files');
          expect(draft.text.selection, selection);
          expect(draft.attachments, hasLength(2));
          expect(find.byKey(const PageStorageKey('narrow-content-scroll')), large ? findsNothing : findsOneWidget);
        }

        // Reset the outer offset while focus stays held, so the return from
        // the large viewport cannot pass merely by restoring an old offset.
        scroll.jumpTo(0);
        await t.pumpAndSettle();
        expect(scroll.offset, closeTo(0, 0.5));
        await resize(true);
        expect(focus.hasFocus, isTrue);
        expect(field.hitTestable(), findsOneWidget);
        await resize(false);
        expect(focus.hasFocus, isTrue);
        expect(field.hitTestable(), findsOneWidget, reason: 'Focused input reveals itself after the inset round-trip.');
        final revealed = t.getRect(field);
        final usable = t.getRect(scrollbar);
        expect(revealed.top, greaterThanOrEqualTo(usable.top - 0.5));
        expect(revealed.bottom, lessThanOrEqualTo(usable.bottom + 0.5));

        env.reconnectGate = Completer<void>();
        connecting = env.c.pipeline.connect();
        await _settle(t);
        await t.ensureVisible(find.byKey(const ValueKey('send')));
        await t.tap(find.byKey(const ValueKey('send')));
        await _settle(t);
        expect(draft.sending, isTrue);
        expectActions(pending: true);
        final pendingFocus = focus.hasFocus;
        await resize(true);
        expect(draft.sending, isTrue);
        expect(focus.hasFocus, pendingFocus);
        expectActions(pending: true);
        await resize(false);
        expect(draft.sending, isTrue);
        expect(focus.hasFocus, pendingFocus);
        expectActions(pending: true);
        await t.tap(find.byKey(const ValueKey('stop')));
        await _settle(t);
        expect(draft.sending, isFalse);
        expect(draft.text.selection, selection);
        expect(draft.attachments, hasLength(2));
        final backend = env.c.pipeline.backend! as ScriptedBackend;
        expect(backend.texts, isEmpty);
        expect(backend.images, isEmpty);
        env.reconnectGate!.complete();
        await _settle(t);
        await t.runAsync(() => connecting!);
        expect(backend.texts, isEmpty, reason: 'A cancelled pending send must not replay after resize.');
        expect(backend.images, isEmpty);

        focus.requestFocus();
        await t.pumpAndSettle();
        draft.text.selection = selection;
        for (var remaining = 2; remaining > 0; remaining--) {
          final removeFirst = find.byKey(const ValueKey('remove-chat-attachment-0'));
          await t.ensureVisible(removeFirst);
          await t.pumpAndSettle();
          await t.tap(removeFirst);
          await t.pumpAndSettle();
          expect(draft.attachments, hasLength(remaining - 1));
        }
        expect(identical(t.state(find.byType(Composer)), composerState), isTrue);
        expect(draft.text.text, 'Review these three files');
        expect(draft.text.selection, selection);
        expect(focus.hasFocus, isTrue);
        expect(find.byKey(const PageStorageKey('narrow-content-scroll')), findsNothing);
        expectActions();
        await choose('clipboard', keepSelection: selection);
        final finalBar = find.byKey(const ValueKey('narrow-content-scrollbar'));
        if (finalBar.evaluate().isNotEmpty) {
          final rect = t.getRect(finalBar);
          await t.dragFrom(Offset(rect.right - 3, rect.top + 10), Offset(0, rect.height - 20));
          await t.pumpAndSettle();
        }
        expectActions();
      } finally {
        if (env.reconnectGate case final gate? when !gate.isCompleted) gate.complete();
        if (connecting != null) {
          await _settle(t);
          await t.runAsync(() => connecting!);
        }
        await env.stop(t);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('drag handle resizes up to 95% and down to 35%, and reports the size', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);

    final handle = find.byKey(const ValueKey('assist-handle'));
    await t.drag(handle, const Offset(0, -600));
    await t.pumpAndSettle();
    expect(_panelHeight(t), closeTo(_screen.height * kAssistPanelMax, 0.5));
    expect(env.fractions.last, closeTo(kAssistPanelMax, 1e-9));

    // Down to just above the minimum: clamps, no dismiss.
    await t.timedDrag(handle, const Offset(0, 500), const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(env.dismissed, isEmpty);
    expect(_panelHeight(t), closeTo(_screen.height * kAssistPanelMin, 0.5));
    expect(env.fractions.last, closeTo(kAssistPanelMin, 1e-9));
    await env.stop(t);
  });

  testWidgets('remembered size is used; out-of-range sizes are clamped', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t, fraction: 0.8);
    expect(_panelHeight(t), closeTo(_screen.height * 0.8, 0.5));
    await env.pump(t, fraction: 2);
    await env.stop(t);
  });

  testWidgets('swipe down on the handle dismisses', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);
    await t.fling(find.byKey(const ValueKey('assist-handle')), const Offset(0, 300), 2000);
    await t.pumpAndSettle();
    expect(env.dismissed, [1]);
    await env.stop(t);
  });

  testWidgets('dragging well below the minimum dismisses', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t, fraction: kAssistPanelMin);
    await t.timedDrag(find.byKey(const ValueKey('assist-handle')), const Offset(0, 120), const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(env.dismissed, [1]);
    await env.stop(t);
  });

  testWidgets('tap above the panel dismisses; taps in the panel do not', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);
    await t.tapAt(const Offset(200, 500));
    await t.pump();
    expect(env.dismissed, isEmpty);
    await t.tapAt(const Offset(200, 100));
    await t.pump();
    expect(env.dismissed, [1]);
    // Only once, even if tapped again before the host takes it down.
    await t.tapAt(const Offset(200, 100));
    await t.pump();
    expect(env.dismissed, [1]);
    await env.stop(t);
  });

  testWidgets('dropdown menu: open in app and all conversations', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);
    await t.tap(find.byKey(const ValueKey('more-menu')));
    await t.pumpAndSettle();
    expect(find.text('All conversations'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('assist-open-app')));
    await t.pumpAndSettle();
    expect(env.opened, [1]);
    expect(env.dismissed, isEmpty);
    await t.tap(find.byKey(const ValueKey('more-menu')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('open-history')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(HistoryDrawer), findsOneWidget);
    await env.stop(t);
  });

  testWidgets('shows the transcript; latestScreenshot finds the assist image', (t) async {
    final env = _Env();
    await env.start(t);
    final shot = Message(kind: MessageKind.system, text: 'Assist screenshot from com.android.settings')
      ..image = const ImageAttachment(
        path: '/nonexistent/assist.png',
        width: 360,
        height: 760,
        originalWidth: 1080,
        originalHeight: 2248,
      );
    env.c.pipeline.conversation
      ..add(shot)
      ..add(Message(kind: MessageKind.user, text: 'What is on my screen?'))
      ..add(Message(kind: MessageKind.assistant, text: 'The Settings app.'));
    await env.pump(t);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    expect(find.text('The Settings app.'), findsWidgets);
    expect(latestScreenshot(env.c.pipeline.conversation.messages)?.path, '/nonexistent/assist.png');
    await env.stop(t);
  });

  testWidgets('presenter pushes an opaque panel route while visible and removes it after', (t) async {
    final key = GlobalKey<NavigatorState>();
    final visible = ValueNotifier(false);
    var shown = 0;
    final p = AssistPanelPresenter(
      navigatorKey: key,
      visible: visible,
      onShown: () => shown++,
      builder: (_) => const Text('panel'),
    );
    await t.pumpWidget(MaterialApp(navigatorKey: key, home: const Text('home')));
    p.start();
    expect(p.showing, isFalse);

    visible.value = true;
    await t.pump();
    await t.pump();
    expect(p.showing, isTrue);
    expect(find.text('panel'), findsOneWidget);
    // Opaque: the full app below is not painted (the window shows the app
    // underneath).
    expect(find.text('home'), findsNothing);
    expect(shown, 1);

    visible.value = false;
    await t.pump();
    expect(p.showing, isFalse);
    expect(find.text('panel'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    p.dispose();
  });

  test('overlay and assist events parse; the bridge tracks the panel and keeps early events', () {
    final on = AndroidEvent.parse({'type': 'overlay', 'on': true, 'fraction': 0.72});
    expect(on, isA<OverlayEvent>());
    expect((on! as OverlayEvent).fraction, 0.72);
    final a = AndroidEvent.parse({'type': 'assist', 'png': '/x.png', 'overlay': true}) as AssistEvent;
    expect(a.overlay, isTrue);
    expect((AndroidEvent.parse({'type': 'assist'}) as AssistEvent).overlay, isFalse);

    final b = AndroidBridge.instance;
    b.onEvent(on);
    expect(b.overlayVisible.value, isTrue);
    expect(b.overlayFraction, 0.72);
    b.onEvent(a);
    expect(b.claimEarly(), [a]);
    // Claimed once; later events go to the live listener only.
    b.onEvent(a);
    expect(b.claimEarly(), isEmpty);
    b.onEvent(const OverlayEvent(on: false));
    expect(b.overlayVisible.value, isFalse);
  });

  testWidgets('dismissing the assistant interrupts and suspends the voice session once in the background', (t) async {
    final env = _Env();
    await env.start(t, mobile: true);
    env.c.assistantKeepAliveOverride = const Duration(milliseconds: 50);
    await t.runAsync(() async {
      await env.c.pipeline.connect();
    });
    env.c.onLifecycle(AppLifecycleState.paused);
    env.c.assistantDismissed();
    await t.pump(const Duration(milliseconds: 100));
    await _settle(t);
    expect(env.c.pipeline.suspended, isTrue);
    expect(env.c.pipeline.status, isNot(SessionStatus.connected));

    // Shown again before the delay: kept.
    env.c.onLifecycle(AppLifecycleState.resumed);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    env.c.onLifecycle(AppLifecycleState.paused);
    env.c.assistantDismissed();
    env.c.onLifecycle(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 100));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(env.c.pipeline.suspended, isFalse);
    await env.stop(t);
  });

  testWidgets('showing the assistant reconnects a suspended session and unmutes, without a lifecycle event', (t) async {
    final env = _Env();
    await env.start(t, mobile: true);
    await t.runAsync(() async {
      await env.c.pipeline.connect();
      await env.c.setMicMode(MicMode.muted);
      await env.c.pipeline.suspend();
    });
    expect(env.c.pipeline.suspended, isTrue);
    // The engine never left "resumed" (no lifecycle event): the panel's
    // show signal alone reconnects, with the mic on.
    await t.runAsync(() => env.c.assistantShown());
    await _settle(t);
    expect(env.c.pipeline.suspended, isFalse);
    expect(env.c.settings.micMode, MicMode.handsFree);
    expect(env.c.pipeline.status, isNot(SessionStatus.disconnected));
    // A pending dismissal suspend is cancelled by showing again.
    env.c.assistantKeepAliveOverride = const Duration(milliseconds: 50);
    env.c.onLifecycle(AppLifecycleState.paused);
    env.c.assistantDismissed();
    await t.runAsync(() => env.c.assistantShown());
    await t.pump(const Duration(milliseconds: 100));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(env.c.pipeline.suspended, isFalse);
    await env.stop(t);
  });

  group('warm keep-alive after dismissal', () {
    testWidgets('the mic closes at once; the session stays connected and is reused without a handshake', (t) async {
      final env = _Env();
      await env.start(t, mobile: true);
      env.c.assistantKeepAliveOverride = const Duration(seconds: 30);
      await t.runAsync(() => env.c.pipeline.connect());
      final backend = env.c.pipeline.backend! as ScriptedBackend;
      final mic = env.fp.audio.mic!;
      final opens = env.fp.audio.micOpens.length;
      env.c.onLifecycle(AppLifecycleState.paused);
      env.c.assistantDismissed();
      await _settle(t);
      expect(mic.closed, isTrue, reason: 'mic closed immediately (privacy, CPU)');
      expect(env.c.pipeline.idleWarm, isTrue);
      expect(env.c.pipeline.suspended, isFalse);
      expect(env.c.pipeline.status, SessionStatus.connected);
      expect(backend.closed, isFalse);
      expect(backend.idles, [true]);
      final sent = backend.audioBytes;
      // Nothing is sent while warm and dismissed.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(backend.audioBytes, sent);

      await t.runAsync(() => env.c.assistantShown());
      await _settle(t);
      expect(env.c.pipeline.idleWarm, isFalse);
      expect(identical(env.c.pipeline.backend, backend), isTrue, reason: 'same session, no reconnect');
      expect(backend.idles, [true, false]);
      expect(env.fp.audio.micOpens.length, opens + 1);
      final mic2 = env.fp.audio.mic!;
      expect(mic2.closed, isFalse);
      mic2.push(pcm(20, amplitude: 3000));
      expect(backend.audioBytes, greaterThan(sent), reason: 'live audio streams directly');
      await env.stop(t);
    });

    testWidgets('the keep-alive expires, then the session suspends', (t) async {
      final env = _Env();
      await env.start(t, mobile: true);
      env.c.assistantKeepAliveOverride = const Duration(milliseconds: 150);
      await t.runAsync(() => env.c.pipeline.connect());
      final backend = env.c.pipeline.backend! as ScriptedBackend;
      env.c.onLifecycle(AppLifecycleState.paused);
      env.c.assistantDismissed();
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(env.c.pipeline.suspended, isFalse);
      expect(env.c.pipeline.idleWarm, isTrue);
      await t.pump(const Duration(milliseconds: 200));
      await _settle(t);
      expect(env.c.pipeline.suspended, isTrue);
      expect(backend.closed, isTrue);
      expect(env.fp.audio.mic!.closed, isTrue);
      // The next activation reconnects as before.
      await t.runAsync(() => env.c.assistantShown());
      await _settle(t);
      expect(env.c.pipeline.suspended, isFalse);
      expect(env.c.pipeline.idleWarm, isFalse);
      expect(env.c.pipeline.status, SessionStatus.connected);
      expect(identical(env.c.pipeline.backend, backend), isFalse);
      expect(env.fp.audio.mic!.closed, isFalse);
      await env.stop(t);
    });

    testWidgets('a warm session the server drops is not reconnected while dismissed; the next activation connects', (
      t,
    ) async {
      final env = _Env();
      await env.start(t, mobile: true);
      env.c.assistantKeepAliveOverride = const Duration(seconds: 30);
      await t.runAsync(() => env.c.pipeline.connect());
      final backend = env.c.pipeline.backend! as ScriptedBackend;
      env.c.onLifecycle(AppLifecycleState.paused);
      env.c.assistantDismissed();
      await _settle(t);
      backend.emit(const BackendError('Voice connection lost while idle', code: kIdleClosedCode, fatal: true));
      await _settle(t);
      expect(env.c.pipeline.status, SessionStatus.disconnected);
      expect(env.c.pipeline.backend, isNull);
      expect(backend.closed, isTrue);
      expect(env.c.pipeline.conversation.messages.where((m) => m.meta['type'] == 'error'), isEmpty);
      await t.runAsync(() => env.c.assistantShown());
      await _settle(t);
      expect(env.c.pipeline.status, SessionStatus.connected);
      expect(env.c.pipeline.backend, isNotNull);
      expect(identical(env.c.pipeline.backend, backend), isFalse);
      expect(env.fp.audio.mic!.closed, isFalse);
      await env.stop(t);
    });

    testWidgets('opening the app while warm reopens the mic', (t) async {
      final env = _Env();
      await env.start(t, mobile: true);
      env.c.assistantKeepAliveOverride = const Duration(seconds: 30);
      await t.runAsync(() => env.c.pipeline.connect());
      env.c.onLifecycle(AppLifecycleState.paused);
      env.c.assistantDismissed();
      await _settle(t);
      expect(env.fp.audio.mic!.closed, isTrue);
      env.c.onLifecycle(AppLifecycleState.resumed);
      await _settle(t);
      expect(env.c.pipeline.idleWarm, isFalse);
      expect(env.fp.audio.mic!.closed, isFalse);
      await env.stop(t);
    });

    test('the keep-alive setting round-trips and defaults to 2 minutes', () {
      expect(const AppSettings().assistantKeepAliveSeconds, 120);
      final s = const AppSettings().copyWith(assistantKeepAliveSeconds: 30);
      expect(AppSettings.fromJson(s.toJson()).assistantKeepAliveSeconds, 30);
    });
  });
}
