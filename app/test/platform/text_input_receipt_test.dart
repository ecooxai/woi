import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_input_control.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/platform/platform_services.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import '../fakes/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late FakePlatform fake;
  String? nativeReply;

  setUp(() async {
    fake = await FakePlatform.create();
    calls.clear();
    nativeReply = 'ime_dispatched';
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return nativeReply;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
    await fake.dispose();
  });

  ToolRegistry registryFor(InputControl input) {
    final base = fake.services;
    final platform = PlatformServices(
      paths: base.paths,
      audio: base.audio,
      screen: base.screen,
      input: input,
      shell: base.shell,
      files: base.files,
      viewer: base.viewer,
    );
    return ToolRegistry()..registerAll(
      builtinTools(
        ToolEnvironment(
          platform: platform,
          confirmations: FakeConfirmations(),
          delegate: StubDelegateBackend(),
          settings: () => const AppSettings(),
          onScreenshot: (_, _) async {},
        ),
      ),
    );
  }

  Map<String, dynamic> decode(ToolOutcome result) =>
      jsonDecode(result.json) as Map<String, dynamic>;

  for (final (reply, delivery, backend) in [
    ('ime_dispatched', 'dispatched', 'android_accessibility_input_connection'),
    ('set_text', 'applied', 'android_accessibility_action'),
  ]) {
    test(
      'type_text preserves Android $reply receipt and sends literal text once',
      () async {
        nativeReply = reply;
        const text = '  A + B\n雪🙂  ';
        final result = await registryFor(AndroidInputControl())
            .dispatch('type_text', jsonEncode({'text': text}));
        expect(result.ok, isTrue);
        expect(decode(result), {
          'ok': true,
          'chars': text.length,
          'delivery': delivery,
          'backend': backend,
        });
        expect(calls.single.method, 'typeText');
        expect(calls.single.arguments, {'text': text});
      },
    );
  }

  test('unacknowledged Android insertion fails once and never invents a delivery receipt', () async {
    final tools = registryFor(AndroidInputControl());
    for (final reply in <String?>[null, '', 'empty', 'unknown']) {
      calls.clear();
      nativeReply = reply;
      final result = await tools.dispatch('type_text', '{"text":"x"}');
      expect(result.ok, isFalse);
      expect(decode(result)['ok'], isFalse);
      expect(decode(result)['delivery'], isNull);
      expect(
        decode(result)['error'],
        contains('did not acknowledge text insertion'),
      );
      expect(calls, hasLength(1));
    }
  });

  test('empty Android typing is explicitly a no-op and never reaches the native editor', () async {
    final result = await registryFor(AndroidInputControl())
        .dispatch('type_text', '{"text":""}');
    expect(decode(result), {
      'ok': true,
      'chars': 0,
      'delivery': 'noop',
      'backend': 'android_accessibility',
    });
    expect(calls, isEmpty);
  });

  test('legacy input implementations remain compatible and conservatively acknowledge dispatch', () async {
    final result = await registryFor(fake.input)
        .dispatch('type_text', '{"text":"hello"}');
    expect(decode(result), {
      'ok': true,
      'chars': 5,
      'delivery': 'dispatched',
      'backend': 'platform_input',
    });
    expect(fake.input.log, ['type hello']);
    expect(calls, isEmpty);
  });

  test('the compatible Android Future<void> API uses one acknowledged native dispatch', () async {
    final InputControl input = AndroidInputControl();
    await input.typeText('hello');
    expect(calls.single.method, 'typeText');
    expect(calls.single.arguments, {'text': 'hello'});
  });
}
