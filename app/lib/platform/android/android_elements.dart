import 'package:flutter/services.dart';

import '../../core/vision/ui_elements.dart';
import 'android_bridge.dart';

/// Visible elements of the app the user is in, from Woi's accessibility
/// service (WoiAccessibilityService.elements): bounds in real screen pixels.
class AndroidElementSource implements ElementSource {
  AndroidElementSource({AndroidBridge? bridge, this.max = 600}) : _bridge = bridge ?? AndroidBridge.instance;
  final AndroidBridge _bridge;
  final int max;

  @override
  Future<List<UiElement>> elements() async {
    try {
      final list = await _bridge.call<List<Object?>>('elements', {'max': max});
      return [for (final m in list ?? const []) UiElement.fromJson(m! as Map<Object?, Object?>)];
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }
}
