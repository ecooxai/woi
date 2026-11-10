import 'dart:async';

import 'package:flutter/services.dart';

import '../clipboard_access.dart';

/// GTK reports clipboard owner changes even while the Woi window is minimized.
/// Keep the common text/rich adapter unchanged for other platforms and tests.
class LinuxClipboardAccess extends SystemClipboardAccess implements ClipboardChangeEvents {
  const LinuxClipboardAccess();

  static const _channel = MethodChannel('woi/clipboard');
  static final _changes = StreamController<void>.broadcast(
    onListen: () => _channel.setMethodCallHandler(_onNativeCall),
    onCancel: () => _channel.setMethodCallHandler(null),
  );

  static Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'changed') throw MissingPluginException();
    _changes.add(null);
    return null;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get supportsBackgroundCapture => true;
}
