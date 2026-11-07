import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_url_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late AndroidUrlOpener opener;

  setUp(() {
    calls = [];
    opener = AndroidUrlOpener();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(AndroidBridge.method, null));

  test('ordinary source links open without starting the sign-in service', () async {
    final source = Uri.parse('https://dart.dev/libraries/async');
    expect(await opener.open(source), isTrue);
    expect(calls.single.method, 'openUrl');
    expect(calls.single.arguments, {'url': source.toString(), 'keepAlive': false});
  });

  test('sign-in opts into keep-alive and done ends its service', () async {
    final authorize = Uri.parse('https://auth.openai.com/oauth/authorize');
    expect(await opener.open(authorize, keepAlive: true), isTrue);
    await opener.done();
    expect(calls.map((call) => call.method), ['openUrl', 'loginDone']);
    expect(calls.first.arguments, {'url': authorize.toString(), 'keepAlive': true});
  });

  test('unavailable browsers return false so the UI can report the failure', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (_) async => false);
    expect(await opener.open(Uri.parse('https://dart.dev')), isFalse);
  });

  test('platform launch errors return false instead of escaping the link action', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (_) async {
      throw PlatformException(code: 'unavailable', message: 'No browser activity');
    });
    expect(await opener.open(Uri.parse('https://dart.dev')), isFalse);
  });
}
