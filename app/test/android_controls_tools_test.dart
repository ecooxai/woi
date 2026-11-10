import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_input_control.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/clipboard_tool.dart';
import 'package:woi/tools/pointer_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _UnusedDelegate implements DelegateBackend {
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async =>
      throw StateError('These input tests must not delegate unrelated work');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late FakePlatform base;
  late PlatformServices platform;
  late AndroidInputControl input;
  late ToolEnvironment env;
  late ToolRegistry tools;

  setUp(() async {
    calls.clear();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      if (call.method == 'scroll') {
        final args = call.arguments as Map;
        return {
          'direction': args['direction'],
          'completed_amount': args['amount'],
          'delivery': 'dispatched',
          'backend': 'android_accessibility_gesture',
          'scroll_event_observed': false,
        };
      }
      if (call.method == 'showKeyboard') {
        return {
          'requested': true,
          'visible': true,
          'focus_changed': false,
          'backend': 'woi_touch_keyboard',
          'text_target': false,
          'text_input_available': false,
          'input_connection': false,
        };
      }
      if (call.method == 'hideKeyboard') return {'hidden': true, 'visible': false};
      return null;
    });
    base = await FakePlatform.create();
    final p = base.services;
    input = AndroidInputControl();
    platform = PlatformServices(
      paths: p.paths,
      audio: p.audio,
      screen: p.screen,
      input: input,
      showKeyboard: input.showKeyboard,
      shell: p.shell,
      files: p.files,
      viewer: p.viewer,
      isMobile: true,
    );
    env = ToolEnvironment(
      platform: platform,
      confirmations: FakeConfirmations(),
      delegate: _UnusedDelegate(),
      settings: () => const AppSettings(),
      onScreenshot: (_, _) async {},
    );
    tools = ToolRegistry()
      ..registerAll(builtinTools(env))
      ..register(showKeyboardTool(input.showKeyboard));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
    await base.dispose();
  });

  test('production tool maps screenshot anchors once and passes bounded viewport intent', () async {
    env.lastScreenshot = Screenshot(
      png: Uint8List(0),
      width: 540,
      height: 1080,
      originalWidth: 1080,
      originalHeight: 2160,
      originX: 16,
      originY: 48,
    );
    final result = await tools.dispatch(
      'scroll_screen',
      '{"direction":"up","amount":0.5,"x":100,"y":200,"strategy":"gesture"}',
    );
    expect(result.ok, isTrue, reason: result.json);
    expect(calls.single.method, 'scroll');
    expect(calls.single.arguments, {'direction': 'up', 'amount': 0.5, 'x': 216, 'y': 448, 'strategy': 'gesture'});
    final receipt = jsonDecode(result.json) as Map;
    expect(receipt['screen_xy'], [216, 448]);
    expect(receipt['scroll_event_observed'], false);
    expect(receipt['delivery'], 'dispatched');
  });

  test('viewport default needs no screenshot and invalid anchors emit no input', () async {
    expect((await tools.dispatch('scroll_screen', '{"direction":"down"}')).ok, true);
    expect(calls.single.arguments, {'direction': 'down', 'amount': 1.0, 'strategy': 'auto'});
    calls.clear();
    for (final args in [
      '{"direction":"down","x":20}',
      '{"direction":"down","x":20,"y":30}',
      '{"direction":"up","amount":0}',
      '{"direction":"up","amount":6}',
    ]) {
      expect((await tools.dispatch('scroll_screen', args)).ok, false, reason: args);
    }
    expect(calls, isEmpty);
  });

  test('unambiguous scroll and keyboard requests use production tools with Luna still enabled', () async {
    final executor = DelegationExecutor(
      model: FakeDelegationModel(const []),
      tools: tools.specs,
      runTool: (_, name, args) async => (await tools.dispatch(name, args)).json,
    );
    final scroll = await executor.execute('Please scroll down two pages');
    expect(scroll.model, 'fast-path');
    expect(scroll.tools.map((t) => t.name), ['scroll_screen']);
    expect(calls.last.method, 'scroll');
    expect((calls.last.arguments as Map)['amount'], 2.0);
    final show = await executor.execute('show the keyboard');
    expect(show.tools.single.name, 'show_keyboard');
    expect(show.tools.single.ok, true);
    final hide = await executor.execute('dismiss the keyboard');
    expect(hide.tools.single.name, 'hide_keyboard');
    expect(hide.tools.single.ok, true);
  });

  test('scroll parser leaves mixed, conditional and targeted requests to the planner', () {
    expect(scrollAction('scroll up half a page'), {'direction': 'up', 'amount': 0.5});
    expect(scrollAction('scroll down a little'), {'direction': 'down', 'amount': 0.25});
    for (final text in [
      'scroll down then click Save',
      'scroll down if the page loads',
      'scroll down in the left pane',
      'scroll down 99 pages',
      'do not scroll down',
    ]) {
      expect(scrollAction(text), isNull, reason: text);
    }
    expect(pointerAction('scroll down'), isNull);
  });

  for (final mode in BackendMode.values) {
    test('$mode publishes Android controls to live and delegated inventories', () async {
      final backends = <ScriptedBackend>[];
      final controller = AppController(
        platform: platform,
        confirmations: FakeConfirmations(),
        backendFactory: () {
          final b = ScriptedBackend();
          backends.add(b);
          return b;
        },
        authManager: CodexAuthManager(path: '${base.root.path}/no-auth.json'),
      );
      final realtime = RealtimeWsBackend();
      try {
        await controller.init();
        await controller.updateSettings(controller.settings.copyWith(backendMode: mode, autoScreenshot: false));
        if (backends.isEmpty) await controller.pipeline.connect();
        const expected = ['scroll_screen', 'show_keyboard', 'hide_keyboard', 'send_keys', 'control_pointer'];
        expect(controller.tools.specs.map((t) => t.name), containsAll(expected));
        expect(backends.last.config!.tools.map((t) => t.name), containsAll(expected));
        final session = realtime.sessionUpdate(backends.last.config!)['session'] as Map;
        expect((session['tools'] as List).map((t) => t['name']), containsAll(expected));
        expect(controller.settings.useLunaPointer, true);
        final result = await controller.tools.dispatch('scroll_screen', '{"direction":"down"}');
        expect(result.ok, true, reason: result.json);
        expect(calls.last.method, 'scroll');
      } finally {
        await realtime.close();
        await controller.shutdown();
      }
    });
  }
}
