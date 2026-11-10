import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_clipboard_access.dart';
import 'package:woi/platform/clipboard_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? response;
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(AndroidBridge.method, null));

  test('native available flag distinguishes text from empty clipboard', () async {
    final clipboard = AndroidClipboardAccess();
    response = {'available': true, 'text': '雪🙂'};
    expect(await clipboard.readText(), '雪🙂');
    response = {'available': false, 'text': null};
    expect(await clipboard.readText(), null);
    expect(calls.map((e) => e.method), ['readClipboard', 'readClipboard']);
  });

  test('a denied background read remains an error', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (_) async {
      throw PlatformException(code: 'clipboard_access', message: 'Android did not grant clipboard focus');
    });
    await expectLater(
      AndroidClipboardAccess().readText(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('clipboard focus'))),
    );
  });

  test('write requires native acknowledgement and keeps exact payload', () async {
    response = true;
    await AndroidClipboardAccess().writeText('  x\n雪  ');
    expect(calls.single.arguments, {'text': '  x\n雪  '});
    response = false;
    await expectLater(AndroidClipboardAccess().writeText('x'), throwsStateError);
  });

  test('malformed native replies cannot masquerade as empty clipboard', () async {
    for (final bad in [
      null,
      false,
      <String, Object?>{},
      {'available': true, 'text': null},
    ]) {
      response = bad;
      await expectLater(AndroidClipboardAccess().readText(), throwsStateError);
    }
  });

  test('passive rich reads never request a focus window and preserve image bytes', () async {
    final bytes = Uint8List.fromList([137, 80, 78, 71]);
    response = {
      'text': 'caption',
      'image': {'bytes': bytes, 'mimeType': 'image/png', 'name': 'picture.png'},
    };
    final content = await AndroidClipboardAccess().readContent(allowFocus: false);
    expect(content!.text, 'caption');
    expect(content.image!.bytes, bytes);
    expect(calls.single.method, 'readClipboardContent');
    expect(calls.single.arguments, {'allowFocus': false});
  });

  test('rich image writes require an explicit native success', () async {
    final content = ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1])));
    response = true;
    await AndroidClipboardAccess().writeContent(content);
    expect(calls.single.method, 'writeClipboardContent');
    response = false;
    await expectLater(AndroidClipboardAccess().writeContent(content), throwsStateError);
  });
}
