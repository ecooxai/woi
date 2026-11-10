import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/screens/settings_screen.dart';
import 'package:woi/ui/theme.dart';

import '../fakes/fakes.dart';

class _SettingsFixture {
  late FakePlatform platform;
  late AppController controller;

  Future<void> start(WidgetTester tester, {AppSettings? settings}) async {
    await tester.runAsync(() async {
      platform = await FakePlatform.create();
      await SettingsStore(platform.services.paths.settingsFile)
          .save(settings ?? const AppSettings(backendMode: BackendMode.direct, micMode: MicMode.muted));
      controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      await controller.init();
    });
    expect(controller.initError, isNull);
    addTearDown(() => stop(tester));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<void> pump(WidgetTester tester, Size size, {double textScale = 1}) async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SettingsView(key: ValueKey(size.width), controller: controller),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var stopped = false;
    Object? failure;
    StackTrace? failureStack;
    late Future<void> stopping;
    await tester.runAsync(() async {
      stopping = controller.shutdown().then<void>(
        (_) => stopped = true,
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
          stopped = true;
        },
      );
    });
    final watch = Stopwatch()..start();
    while (!stopped) {
      if (watch.elapsed >= const Duration(seconds: 15)) {
        fail('Settings shutdown did not finish while draining autosave.');
      }
      await tester.runAsync(() => Future.any<void>([stopping, Future<void>.delayed(const Duration(milliseconds: 15))]));
      await tester.pump(const Duration(milliseconds: 20));
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    await tester.runAsync(platform.dispose);
    await tester.pump(const Duration(seconds: 5));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _settingsScroll() =>
    find.descendant(of: find.byKey(const ValueKey('settings-list')), matching: find.byType(Scrollable)).first;

Future<void> _show(WidgetTester tester, Finder target) async {
  final scroll = _settingsScroll();
  tester.state<ScrollableState>(scroll).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(target, 200, scrollable: scroll);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump();
}

Future<void> _choose(WidgetTester tester, String id, String label) async {
  final field = find.byKey(ValueKey('select-$id'));
  await _show(tester, field);
  await tester.tap(field);
  await _settle(tester);
  await tester.tap(find.text(label).hitTestable().last);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, asset) in [
      ('Inter', 'assets/fonts/Inter-Variable.ttf'),
      ('SpaceGrotesk', 'assets/fonts/SpaceGrotesk-Variable.ttf'),
      ('JetBrainsMono', 'assets/fonts/JetBrainsMono-Regular.ttf'),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });

  testWidgets('Settings fits desktop and narrow widths with models, voices, and expanded Advanced', (tester) async {
    final fixture = _SettingsFixture();
    await fixture.start(tester);
    fixture.controller.codexAuth = const CodexAuthInfo(
      path: 'test-auth.json',
      accessToken: 'test-token',
      accountId: 'private-account-id-123456',
      email: 'alex.long.account.name@example.com',
    );
    for (final size in [const Size(1280, 900), const Size(400, 900), const Size(320, 740)]) {
      await fixture.pump(tester, size);
      expect(find.text('Signed in as alex.long.account.name@example.com'), findsOneWidget);
      expect(find.text('Codex account'), findsNothing);
      expect(find.textContaining('private-account-id'), findsNothing);
      expect(find.byKey(const ValueKey('select-image-model')), findsNothing);

      final model = find.byKey(const ValueKey('settings-text-model-field'));
      final thinking = find.byKey(const ValueKey('settings-thinking-level-field'));
      await _show(tester, thinking);
      final modelRect = tester.getRect(model);
      final thinkingRect = tester.getRect(thinking);
      expect(modelRect.width, closeTo(thinkingRect.width, 0.5));
      if (size.width >= 600) {
        expect(modelRect.top, closeTo(thinkingRect.top, 0.5));
        expect(thinkingRect.left, greaterThan(modelRect.right));
      } else {
        expect(thinkingRect.left, closeTo(modelRect.left, 0.5));
        expect(thinkingRect.top, greaterThan(modelRect.bottom));
      }
      final more = find.byKey(const ValueKey('select-voice'));
      final echo = find.byKey(const ValueKey('radio-voice-echo'));
      await _show(tester, more);
      if (size.width >= 400) {
        expect(tester.getRect(more).left, greaterThan(tester.getRect(echo).right));
        expect(tester.getCenter(more).dy, closeTo(tester.getCenter(echo).dy, 1));
      }
      await _show(tester, find.text('Echo cancellation'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-group-voice')),
          matching: find.text('Echo cancellation'),
        ),
        findsOneWidget,
      );
      expect(find.text('Image model'), findsNothing);
      final advanced = find.byKey(const ValueKey('advanced-settings'));
      await _show(tester, advanced);
      await tester.tap(advanced);
      await tester.pump();
      await _show(tester, find.byKey(const ValueKey('select-image-model')));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-group-images')),
          matching: find.byKey(const ValueKey('select-image-model')),
        ),
        findsOneWidget,
      );

      final position = tester.state<ScrollableState>(_settingsScroll()).position;
      position.jumpTo(0);
      await tester.pump();
      for (var page = 0; page < 30; page++) {
        expect(tester.takeException(), isNull, reason: 'Settings at ${size.width}px, page $page');
        if (position.pixels >= position.maxScrollExtent) break;
        position.jumpTo((position.pixels + size.height * 0.7).clamp(0, position.maxScrollExtent));
        await tester.pump();
      }
      // A lazy ListView refines its estimated extent as each group mounts.
      // Settle at the final extent and prove the actual footer is reachable.
      for (var settle = 0; settle < 3; settle++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(position.extentAfter, closeTo(0, 0.5));
      expect(find.text('Changes save automatically').hitTestable(), findsOneWidget);
    }
  });

  testWidgets('large text keeps every Settings group and the footer reachable at narrow widths', (tester) async {
    final fixture = _SettingsFixture();
    await fixture.start(tester);
    for (final (size, scale) in [(const Size(320, 740), 1.5), (const Size(360, 740), 2.0)]) {
      await fixture.pump(tester, size, textScale: scale);
      final backendLabel = find.text('Backend');
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: backendLabel, matching: find.byType(RichText)),
      );
      expect(
        paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 7)),
        hasLength(1),
        reason: 'Backend must not split midword.',
      );
      final advanced = find.byKey(const ValueKey('advanced-settings'));
      await _show(tester, advanced);
      await tester.tap(advanced);
      await tester.pump();
      final position = tester.state<ScrollableState>(_settingsScroll()).position;
      position.jumpTo(0);
      await tester.pump();
      for (var page = 0; page < 70; page++) {
        expect(tester.takeException(), isNull, reason: 'Settings at ${size.width}px and ${scale}x text, page $page');
        if (position.pixels >= position.maxScrollExtent) break;
        position.jumpTo((position.pixels + size.height * 0.65).clamp(0, position.maxScrollExtent));
        await tester.pump();
      }
      for (var settle = 0; settle < 3; settle++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Changes save automatically').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('More models keeps its hint compact while large-text menu choices remain keyboard accessible', (
    tester,
  ) async {
    final fixture = _SettingsFixture();
    await fixture.start(tester);
    for (final scale in [1.0, 2.0]) {
      await fixture.pump(tester, const Size(320, 740), textScale: scale);
      final models = find.byKey(const ValueKey('select-audio-model'));
      await _show(tester, models);
      expect(
        tester.getSize(models).height,
        lessThanOrEqualTo(80),
        reason: 'Hidden unavailable-model descriptions must not size the closed hint.',
      );
      final before = fixture.controller.settings.audioModel;
      await tester.tap(models);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final labels = tester.widget<DropdownButton<(AudioModelFamily, String)>>(models).items!;
      expect(labels.length, greaterThan(1));
      final firstEnabled = labels.firstWhere((item) => item.enabled).value!;
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(fixture.controller.settings.audioModel, firstEnabled.$2);
      expect(tester.widget<DropdownButton<(AudioModelFamily, String)>>(models).value, firstEnabled);
      expect(models.hitTestable(), findsOneWidget);
      await tester.tap(models);
      await tester.pumpAndSettle();
      final last = find.text(labels.last.value!.$2).hitTestable();
      for (var step = 0; step < labels.length + 2 && last.evaluate().isEmpty; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Disabled choices remain present with their reason even though keyboard
      // traversal skips selecting them; the open menu can still be scrolled.
      final menuList = find.byType(ListView).last;
      await tester.drag(menuList, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(last, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => fixture.controller.updateSettings(fixture.controller.settings.copyWith(realtimeModel: before)),
      );
      await _settle(tester);
    }
  });

  testWidgets('keyboard traversal reaches model menus and Advanced without activating unrelated settings', (
    tester,
  ) async {
    final fixture = _SettingsFixture();
    await fixture.start(tester);
    await fixture.pump(tester, const Size(320, 740), textScale: 1.5);

    bool focusedWithin(Finder finder) {
      final targets = finder.evaluate().toSet();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null || targets.isEmpty) return false;
      var found = targets.contains(context);
      context.visitAncestorElements((element) {
        found = found || targets.contains(element);
        return !found;
      });
      return found;
    }

    Future<void> tabTo(Finder finder) async {
      for (var step = 0; step < 80 && !focusedWithin(finder); step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(focusedWithin(finder), isTrue, reason: 'Normal Tab traversal must reach this settings control.');
      expect(finder.hitTestable(), findsOneWidget, reason: 'The focused control must scroll into view.');
    }

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final thinking = find.byKey(const ValueKey('select-text-reasoning-effort'));
    await tabTo(thinking);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('High').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fixture.controller.settings.textReasoningEffort, 'medium');

    final advanced = find.byKey(const ValueKey('advanced-settings'));
    await tabTo(advanced);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.descendant(of: advanced, matching: find.byIcon(Icons.expand_less_rounded)), findsOneWidget);
    await tabTo(find.byKey(const ValueKey('select-image-model')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final custom = find.text('Custom model…').hitTestable();
    for (var step = 0; step < 20 && custom.evaluate().isEmpty; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(custom, findsOneWidget, reason: 'Keyboard navigation must reveal the final menu option.');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Thinking level saves and resets to a supported effort when the text model changes', (tester) async {
    final fixture = _SettingsFixture();
    await fixture.start(tester);
    await fixture.pump(tester, const Size(1280, 900));
    final thinking = find.byKey(const ValueKey('select-text-reasoning-effort'));
    await _show(tester, thinking);
    expect(tester.widget<DropdownButton<String>>(thinking).value, 'medium');
    await _choose(tester, 'text-reasoning-effort', 'High');
    expect(fixture.controller.settings.textReasoningEffort, 'high');
    final saved = await tester.runAsync(() => SettingsStore(fixture.platform.services.paths.settingsFile).load());
    expect(saved!.textReasoningEffort, 'high');
    await _choose(tester, 'text-reasoning-effort', 'None');
    await _choose(tester, 'delegate-model', 'gpt-6.1-sol');
    expect(fixture.controller.settings.textReasoningEffort, 'medium');
    expect(tester.widget<DropdownButton<String>>(thinking).value, 'medium');
    await tester.runAsync(
      () => fixture.controller.updateSettings(
        fixture.controller.settings.copyWith(delegateModel: 'custom-unverified-model'),
      ),
    );
    await _settle(tester);
    expect(tester.widget<DropdownButton<String>>(thinking).onChanged, isNull);
    expect(find.text('Not configurable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Live settings expose standby and never substitute an account ID for a missing email', (tester) async {
    final fixture = _SettingsFixture();
    await fixture.start(
      tester,
      settings: const AppSettings(backendMode: BackendMode.gptLive, micMode: MicMode.muted),
    );
    fixture.controller.codexAuth = const CodexAuthInfo(
      path: 'test-auth.json',
      accessToken: 'test-token',
      accountId: 'private-account-id-123456',
    );
    await fixture.pump(tester, const Size(400, 900));
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.textContaining('private-account-id'), findsNothing);
    final advanced = find.byKey(const ValueKey('advanced-settings'));
    await _show(tester, advanced);
    await tester.tap(advanced);
    await tester.pump();
    await _show(tester, find.text('Idle standby'));
    expect(find.text('Idle standby'), findsOneWidget);
    expect(find.text('Reply delay'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
