import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/ui/assist/assist_panel.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/input_bar.dart';

import '../fakes/fakes.dart';

const _screen = Size(400, 800);

class _Env {
  late FakePlatform fp;
  late AppController c;
  final dismissed = <int>[];
  final opened = <int>[];
  final fractions = <double>[];

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
        backendFactory: ScriptedBackend.new,
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
        home: Scaffold(backgroundColor: Colors.transparent, body: panel(fraction: fraction)),
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
    expect(find.byKey(const ValueKey('assist-open-app')), findsOneWidget);
    expect(find.text('Ask about this screen, or anything else.'), findsOneWidget);
    await env.stop(t);
  });

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

  testWidgets('open full app and close buttons', (t) async {
    final env = _Env();
    await env.start(t);
    await env.pump(t);
    await t.tap(find.byKey(const ValueKey('assist-open-app')));
    await t.tap(find.byKey(const ValueKey('assist-close')));
    await t.pump();
    expect(env.opened, [1]);
    expect(env.dismissed, [1]);
    await env.stop(t);
  });

  testWidgets('shows the transcript and the attached screenshot thumbnail', (t) async {
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
    expect(find.byKey(const ValueKey('assist-thumbnail')), findsOneWidget);
    expect(find.byKey(const ValueKey('assist-transcript')), findsOneWidget);
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

  testWidgets('dismissing the assistant interrupts and suspends the voice session once in the background', (
    t,
  ) async {
    final env = _Env();
    await env.start(t, mobile: true);
    env.c.assistantIdleDelay = const Duration(milliseconds: 50);
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
}
