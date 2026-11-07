import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_input_control.dart';
import 'package:woi/platform/control_feedback.dart';
import 'package:woi/platform/input_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(AndroidBridge.method, null));

  test('left tap and right long press retain their actual native button', () async {
    final input = AndroidInputControl();
    await input.click(120, 230);
    await input.click(450, 670, button: MouseButton.right);
    expect(calls.map((c) => c.method), ['click', 'click']);
    expect(calls[0].arguments, {'x': 120, 'y': 230, 'button': 'left'});
    expect(calls[1].arguments, {'x': 450, 'y': 670, 'button': 'right'});
  });

  test('double tap is explicitly left and unsupported buttons emit no input', () async {
    final input = AndroidInputControl();
    await input.doubleClick(140, 250);
    expect(calls.single.method, 'doubleClick');
    expect(calls.single.arguments, {'x': 140, 'y': 250, 'button': 'left'});
    calls.clear();
    await expectLater(input.click(1, 2, button: MouseButton.middle), throwsUnsupportedError);
    await expectLater(input.doubleClick(1, 2, button: MouseButton.middle), throwsUnsupportedError);
    await expectLater(input.doubleClick(1, 2, button: MouseButton.right), throwsUnsupportedError);
    expect(calls, isEmpty);
    expect(await input.mouseLocation(), const Point(140, 250));
  });

  test('move-only pointer updates stay neutral and never emit a native tap', () async {
    final feedbackCalls = <(String, Map<String, Object?>?)>[];
    final feedback = ControlFeedback((method, args) async {
      feedbackCalls.add((method, args));
      return method == 'begin'
          ? true
          : method == 'interrupted'
          ? false
          : null;
    });
    final input = AndroidInputControl(
      control: ControlGuard(feedback, warning: Duration.zero, cooldown: Duration.zero),
    );
    await input.moveMouse(190, 280);
    expect(calls, isEmpty);
    final begin = feedbackCalls.singleWhere((c) => c.$1 == 'begin').$2!;
    final update = feedbackCalls.singleWhere((c) => c.$1 == 'update').$2!;
    expect(begin, {'kind': 'pointer', 'keys': '', 'x': 190, 'y': 280});
    expect(update, {'keys': null, 'x': 190, 'y': 280, 'button': null});
    expect(await input.mouseLocation(), const Point(190, 280));
  });
}
