import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/vision/click_locator.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_elements.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(AndroidBridge.method, null));

  test('lists accessibility elements and matches a target on them', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return [
        {'role': 'label', 'name': 'Google', 'x': 300, 'y': 400, 'w': 480, 'h': 160},
        {'role': 'entry', 'name': 'Search or type URL', 'x': 140, 'y': 90, 'w': 700, 'h': 110},
        {'role': 'entry', 'name': 'Search', 'x': 60, 'y': 640, 'w': 960, 'h': 130},
        {'role': 'button', 'name': 'Voice search', 'x': 900, 'y': 660, 'w': 90, 'h': 90},
      ];
    });
    final src = AndroidElementSource(max: 50);
    final els = await src.elements();
    expect(calls.single.method, 'elements');
    expect(calls.single.arguments, {'max': 50});
    expect(els[1].bounds, const Rectangle(140, 90, 700, 110));
    final r = await ElementLocator(src).locate('"Search" field in the middle of the Google page');
    expect(r.point, const Point(60 + 480, 640 + 65));
    expect(r.label, "entry 'Search'");
  });

  test('a missing accessibility service surfaces as an error', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      throw PlatformException(code: 'no_accessibility', message: "Woi's accessibility service is off");
    });
    await expectLater(AndroidElementSource().elements(), throwsA(isA<StateError>()));
    await expectLater(ElementLocator(AndroidElementSource()).locate('x'), throwsA(isA<StateError>()));
  });
}
