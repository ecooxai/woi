import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/agents/agent_runs.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/ui/agents/agents_panel.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/contextual_find.dart';
import 'package:woi/ui/widgets/tab_strip.dart';

import '../fakes/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!const bool.fromEnvironment('WOI_AGENTS_SCREENSHOTS')) return;
    for (final font in const {
      'Inter': 'assets/fonts/Inter-Variable.ttf',
      'JetBrainsMono': 'assets/fonts/JetBrainsMono-Regular.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(font.key)..addFont(rootBundle.load(font.value));
      await loader.load();
    }
  });
  late AgentRunStore store;

  setUp(() => store = AgentRunStore());
  tearDown(() => store.dispose());

  Widget host({AgentRunStore? source, ContextualFindController? find}) => RepaintBoundary(
    key: const ValueKey('agents-capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildWoiTheme(),
      home: Scaffold(
        body: AgentsPanel(store: source ?? store, find: find),
      ),
    ),
  );

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('WOI_AGENTS_SCREENSHOTS')) return;
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('agents-capture')));
    await tester.runAsync(() async {
      final raster = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/qa/agents');
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        raster.dispose();
      }
    });
  }

  AgentRun completed(String task, String result) {
    final run = store.create(task: task, toolName: 'run_bash', model: 'gpt-6-luna');
    store.markRunning(run);
    store.finish(run, status: AgentRunStatus.completed, result: result);
    return run;
  }

  Future<void> open(WidgetTester tester, AgentRun run) async {
    final card = find.byKey(ValueKey('agent-run-${run.id}'));
    await tester.scrollUntilVisible(
      card,
      160,
      scrollable: find.descendant(of: find.byKey(const ValueKey('agent-runs-list')), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    expect(card.hitTestable(), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
  }

  testWidgets('empty Agents view has no invented runs or progress', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('No agent runs yet'), findsOneWidget);
    expect(find.text('0 loaded runs · 0 active'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.text('Cancel run'), findsNothing);
  });

  testWidgets('actual run transitions update list status and the complete result', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final run = store.create(task: 'Inspect the selected project', toolName: 'run_bash', model: 'gpt-6-luna');
    await tester.pumpWidget(host());
    expect(find.text('Queued'), findsOneWidget);
    store.markRunning(run);
    await tester.pump();
    expect(find.text('Running'), findsOneWidget);
    await open(tester, run);
    expect(find.text('gpt-6-luna'), findsOneWidget);
    store.finish(
      run,
      status: AgentRunStatus.completed,
      result: '{"stdout":"complete output","stderr":"","exit_code":0}',
    );
    await tester.pump();
    expect(find.text('Completed'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && (widget.data?.contains('"stdout": "complete output"') ?? false),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && (widget.data?.contains('"exit_code": 0') ?? false),
      ),
      findsOneWidget,
    );
  });

  testWidgets('failure details retain exact error and real tool arguments and output', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final run = store.create(task: 'Check a failed command', toolName: 'run_bash');
    store.markRunning(run);
    final step = store.beginStep(run, 'run_bash', '{"command":"test-command"}');
    store.finishStep(run, step, '{"stderr":"Exact command failure","exit_code":2}');
    store.finish(run, status: AgentRunStatus.failed, error: 'Exact provider error', result: '{"exit_code":2}');
    await tester.pumpWidget(host());
    await open(tester, run);
    expect(find.text('Exact provider error'), findsOneWidget);
    final heading = find.text('1. run_bash');
    await tester.ensureVisible(heading);
    await tester.pumpAndSettle();
    await tester.tap(heading);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && (widget.data?.contains('"command": "test-command"') ?? false),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && (widget.data?.contains('Exact command failure') ?? false),
      ),
      findsOneWidget,
    );
  });

  testWidgets('cancel only invokes the actual registered cancellation callback', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final run = store.create(task: 'A cancellable task', toolName: 'run_bash');
    store.markRunning(run);
    var cancellations = 0;
    store.setCancellation(run, () => cancellations++);
    await tester.pumpWidget(host());
    await open(tester, run);
    await tester.tap(find.byKey(ValueKey('agent-cancel-${run.id}')));
    await tester.pump();
    expect(cancellations, 1);
    expect(run.cancellationRequested, isTrue);
    final button = find.byKey(ValueKey('agent-cancel-${run.id}'));
    if (button.evaluate().isNotEmpty) expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    store.finish(run, status: AgentRunStatus.cancelled);
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancel run'), findsNothing);
  });

  testWidgets('large results are lazy and can be expanded without truncation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final output = '${'Retained output line.\n' * 500}FINAL_OUTPUT_MARKER';
    final run = completed('Read a large result', output);
    await tester.pumpWidget(host());
    await open(tester, run);
    final complete = find.byWidgetPredicate((widget) => widget is SelectableText && widget.data == output);
    expect(complete, findsNothing);
    final expand = find.textContaining('Show complete result');
    await tester.ensureVisible(expand);
    await tester.pumpAndSettle();
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(complete, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters and contextual find use real task result text', (tester) async {
    final run = completed('An earlier task', '{"result":"needle in a real result"}');
    final active = store.create(task: 'Current work', toolName: 'python');
    store.markRunning(active);
    final search = ContextualFindController();
    addTearDown(search.dispose);
    await tester.pumpWidget(host(find: search));
    await tester.tap(find.byKey(const ValueKey('agent-filter-active')));
    await tester.pump();
    expect(find.byKey(ValueKey('agent-run-${active.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('agent-run-${run.id}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-filter-all')));
    search.setQuery('needle');
    await tester.pump();
    expect(find.byKey(ValueKey('agent-run-${run.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('agent-run-${active.id}')), findsNothing);
    expect(search.matchCount, 1);
  });

  testWidgets('older persisted runs remain reachable through Load older', (tester) async {
    late Directory directory;
    late AgentRunStore restored;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('woi-agents-panel-');
      final writer = AgentRunStore(path: '${directory.path}/history', pageSize: 2);
      for (var i = 0; i < 5; i++) {
        final run = writer.create(task: 'Archived task $i', toolName: 'python');
        writer.finish(run, status: AgentRunStatus.completed, result: '{"value":$i}');
      }
      await writer.flush();
      writer.dispose();
      restored = AgentRunStore(path: '${directory.path}/history', pageSize: 2);
      await restored.restore();
    });
    addTearDown(() async {
      restored.dispose();
      await directory.delete(recursive: true);
    });
    expect(restored.runs.length, 2);
    expect(restored.hasMore, isTrue);
    await tester.pumpWidget(host(source: restored));
    final older = find.byKey(const ValueKey('agents-load-older'));
    await tester.scrollUntilVisible(
      older,
      160,
      scrollable: find.descendant(of: find.byKey(const ValueKey('agent-runs-list')), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    expect(older.hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(older);
      for (var attempt = 0; attempt < 40 && restored.runs.length == 2; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(restored.runs.length, 4);
    expect(find.text('4 loaded runs · 0 active'), findsOneWidget);
    await tester.scrollUntilVisible(
      older,
      160,
      scrollable: find.descendant(of: find.byKey(const ValueKey('agent-runs-list')), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    expect(older.hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(older);
      for (var attempt = 0; attempt < 40 && restored.runs.length == 4; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(restored.runs.length, 5);
    expect(restored.hasMore, isFalse);
    expect(restored.runs.any((run) => run.task == 'Archived task 0'), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(320, 640), Size(400, 860), Size(1280, 800)]) {
    testWidgets('Agents at $size show a usable list and detail without overflow', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final active = store.create(task: 'Analyze the project structure', toolName: 'python', model: 'gpt-6-luna');
      store.markRunning(active);
      final failed = store.create(task: 'Read an unavailable fixture file', toolName: 'read_file', model: 'gpt-6-luna');
      store.finish(failed, status: AgentRunStatus.failed, error: 'Synthetic fixture: file not found.');
      final run = completed(
        'Inspect the project build configuration',
        '{"stdout":"Synthetic fixture output: build configuration parsed.","stderr":"","exit_code":0}',
      );
      await tester.pumpWidget(host());
      await capture(tester, '${size.width.toInt()}-agents-list');
      if (size.width < 760) await open(tester, run);
      expect(find.byKey(ValueKey('agent-detail-${run.id}')), findsOneWidget);
      await capture(tester, '${size.width.toInt()}-agents-detail');
      expect(tester.takeException(), isNull);
      if (size.width < 760) {
        await tester.tap(find.byKey(const ValueKey('agents-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('agent-run-${run.id}')), findsOneWidget);
      }
    });
  }

  testWidgets('Agents top tab has a touch target and real active count', (tester) async {
    HomeView? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HomeTabs(
              view: HomeView.agents,
              onChanged: (view) => selected = view,
              compact: true,
              height: kTouchTarget,
              agentBadge: 2,
            ),
          ),
        ),
      ),
    );
    final tab = find.byKey(const ValueKey('view-agents'));
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    expect(tester.getSize(tab).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(tab).width, greaterThanOrEqualTo(48));
    await tester.tap(tab);
    expect(selected, HomeView.agents);
    expect(find.byKey(const ValueKey('agents-badge')), findsOneWidget);
  });

  testWidgets('top Agents tab opens the controller store while keeping the wide chat', (tester) async {
    late FakePlatform platform;
    late AppController controller;
    await tester.runAsync(() async {
      platform = await FakePlatform.create();
      controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      await controller.init();
    });
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late AgentRun run;
    // Persist the fixture in the real async zone; shutdown waits for this chain.
    await tester.runAsync(() async {
      run = controller.agents.create(task: 'A task from the real controller store', toolName: 'run_bash');
      await controller.agents.flush();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('agents-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildWoiTheme(),
          home: HomeScreen(controller: controller),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final tab = find.byKey(const ValueKey('view-agents'));
    await tester.ensureVisible(tab);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(tab);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('agents-view')), findsOneWidget);
    expect(find.byKey(ValueKey('agent-run-${run.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
    expect(controller.actions.showViewNamed('agents'), 'agents');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('attach-files')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-button')).hitTestable(), findsOneWidget);
    await capture(tester, '1600-agents-with-composer');
    await tester.binding.setSurfaceSize(const Size(400, 860));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('agents-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('attach-files')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('mic-button')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, '400-agents-with-composer');
    await tester.pumpWidget(const SizedBox.shrink());
    // UI activity may start autosave work in the widget zone. Drain real I/O
    // and fake-clock continuations together, as the other HomeScreen tests do.
    var stopped = false;
    Object? shutdownError;
    StackTrace? shutdownStack;
    late Future<void> stopping;
    await tester.runAsync(() async {
      stopping = controller.shutdown().then<void>(
        (_) => stopped = true,
        onError: (Object error, StackTrace stack) {
          shutdownError = error;
          shutdownStack = stack;
          stopped = true;
        },
      );
    });
    final watch = Stopwatch()..start();
    while (!stopped && watch.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future.any<void>([stopping, Future<void>.delayed(const Duration(milliseconds: 15))]));
    }
    expect(stopped, isTrue, reason: 'Controller shutdown must finish after draining pending file I/O.');
    if (shutdownError != null) Error.throwWithStackTrace(shutdownError!, shutdownStack!);
    await tester.runAsync(() => platform.dispose());
    await tester.pump(const Duration(seconds: 5));
  });
}
