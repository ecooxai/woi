import 'package:flutter/services.dart';

import '../clipboard_access.dart';
import 'android_bridge.dart';

class AndroidClipboardAccess implements ClipboardAccess {
  AndroidClipboardAccess({AndroidBridge? bridge})
    : _bridge = bridge ?? AndroidBridge.instance;
  final AndroidBridge _bridge;

  @override
  Future<String?> readText() async {
    try {
      final reply = await _bridge.call<Object?>('readClipboard');
      if (reply is! Map ||
          reply['available'] is! bool ||
          (reply['available'] == true && reply['text'] is! String)) {
        throw StateError('Android did not acknowledge clipboard access');
      }
      return reply['available'] == true ? reply['text'] as String : null;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<void> writeText(String text) async {
    try {
      if (await _bridge.call<Object?>('writeClipboard', {'text': text}) !=
          true) {
        throw StateError('Android did not acknowledge the clipboard write');
      }
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }
}
