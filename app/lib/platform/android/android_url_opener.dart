import '../../core/auth/pkce_login.dart';
import 'android_bridge.dart';

/// Opens the sign-in page in a Chrome Custom Tab (any browser as fallback)
/// and keeps the app alive with a foreground service while the browser is in
/// front, so the 127.0.0.1:1455 callback server keeps answering.
class AndroidUrlOpener implements PlatformUrlOpener {
  AndroidUrlOpener({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;
  final AndroidBridge _bridge;

  @override
  Future<bool> open(Uri url) async =>
      await _bridge.call<bool>('openUrl', {'url': url.toString(), 'keepAlive': true}) ?? false;

  /// Ends the sign-in foreground service.
  Future<void> done() async => _bridge.call<bool>('loginDone');
}
