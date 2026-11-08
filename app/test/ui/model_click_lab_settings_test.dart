import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/lab/model_click_lab.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/screens/settings_screen.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/contextual_find.dart';

import '../fakes/fakes.dart';

class _Lab implements ModelClickLab {
  late AppSettings Function() settings;
  final launches = <Completer<Uri>>[];
  final observedSettings = <AppSettings>[];

  @override
  ModelClickLabBackend get backend =>
      throw StateError('The UI fake does not expose a provider backend.');

  @override
  Future<Uri> open() {
    observedSettings.add(settings());
    final launch = Completer<Uri>();
    launches.add(launch);
    return launch.future;
  }

  @override
  Future<void> close() async {}
}

class _Controller extends AppController {
  _Controller(FakePlatform platform)
    : super(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(
          path: '${platform.root.path}/no-auth.json',
        ),
      ) {
    lab.settings = () => settings;
  }

  final lab = _Lab();
  @override
  ModelClickLab get modelClickLab => lab;
}

Future<void> _stop(
  WidgetTester tester,
  _Controller controller,
  FakePlatform platform,
) async {
  await tester.pumpWidget(const SizedBox());
  // File persistence runs in real time but may resume in the widget fake zone.
  // Drain both while shutdown waits for any in-flight Settings autosave.
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
      fail('Settings controller did not finish shutdown.');
    }
    await tester.runAsync(
      () => Future.any<void>([
        stopping,
        Future<void>.delayed(const Duration(milliseconds: 15)),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  await tester.runAsync(platform.dispose);
  await tester.pump(const Duration(seconds: 5));
}

Future<void> _show(WidgetTester tester, Finder target) async {
  final list = find
      .descendant(
        of: find.byKey(const ValueKey('settings-list')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(list).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(target, 200, scrollable: list);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump();
}

void main() {
  testWidgets(
    'Advanced and search expose the lab; launch flushes drafts and can recover from browser failure',
    (tester) async {
      late FakePlatform platform;
      late _Controller controller;
      await tester.runAsync(() async {
        platform = await FakePlatform.create();
        await SettingsStore(platform.services.paths.settingsFile).save(
          const AppSettings(
            backendMode: BackendMode.apiKey,
            apiKey: 'qa-old-key',
            micMode: MicMode.muted,
          ),
        );
        controller = _Controller(platform);
        await controller.init();
      });
      expect(controller.initError, isNull);
      addTearDown(() => _stop(tester, controller, platform));
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final search = ContextualFindController();
      addTearDown(search.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: SettingsView(controller: controller, find: search),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final launch = find.byKey(const ValueKey('open-model-click-lab'));
      final advanced = find.byKey(const ValueKey('advanced-settings'));
      expect(launch, findsNothing);
      await _show(tester, advanced);
      await tester.tap(advanced);
      await tester.pump();
      await _show(tester, launch);
      expect(launch.hitTestable(), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'The Advanced launcher fits a phone-width screen.',
      );

      search.setQuery('API key');
      await tester.pump();
      final key = find.byKey(const ValueKey('setting-api-key'));
      await _show(tester, key);
      await tester.enterText(key, '  qa-new-key  ');
      search.setQuery('Model Click Lab');
      await tester.pump();
      await _show(tester, launch);
      expect(
        controller.settings.apiKey,
        'qa-old-key',
        reason: 'This edit is still inside the autosave debounce.',
      );
      await tester.tap(launch);
      await tester.pump();
      expect(controller.lab.launches, hasLength(1));
      expect(controller.lab.observedSettings.single.apiKey, 'qa-new-key');
      expect(controller.settings.apiKey, 'qa-new-key');
      expect(find.text('Opening…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(launch).onPressed, isNull);
      await tester.tap(launch);
      await tester.pump();
      expect(
        controller.lab.launches,
        hasLength(1),
        reason: 'An in-flight launch cannot be submitted twice.',
      );

      controller.lab.launches.first.completeError(
        const ModelClickLabException(
          'browser_unavailable',
          'The test browser is unavailable.',
          status: 503,
        ),
      );
      await tester.pump();
      expect(find.text('The test browser is unavailable.'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(launch).onPressed, isNotNull);
      await tester.tap(launch);
      await tester.pump();
      expect(controller.lab.launches, hasLength(2));
      expect(find.text('The test browser is unavailable.'), findsNothing);
      controller.lab.launches.last.complete(
        Uri.parse('http://127.0.0.1:4242/'),
      );
      await tester.pump();
      expect(find.text('Open Model Click Lab'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(launch).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
