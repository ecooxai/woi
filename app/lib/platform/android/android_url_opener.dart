import 'package:flutter/services.dart';

import '../../core/auth/pkce_login.dart';
import 'android_bridge.dart';

/// Opens links in a Chrome Custom Tab (any browser as fallback). Sign-in
/// can opt into a foreground service while its callback server is waiting.
class AndroidUrlOpener implements PlatformUrlOpener {
  AndroidUrlOpener({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;
  final AndroidBridge _bridge;

  @override
  Future<bool> open(Uri url, {bool keepAlive = false}) async {
    try {
      return await _bridge.call<bool>('openUrl', {'url': url.toString(), 'keepAlive': keepAlive}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Ends the sign-in foreground service.
  Future<void> done() async => _bridge.call<bool>('loginDone');
}
