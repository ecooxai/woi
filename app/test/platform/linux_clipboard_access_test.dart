import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/platform/linux/linux_clipboard_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('woi/clipboard');
  const codec = StandardMethodCodec();
  const clipboard = LinuxClipboardAccess();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> changed(int revision) async {
    await messenger.handlePlatformMessage(channel.name, codec.encodeMethodCall(MethodCall('changed', revision)), null);
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('only the explicit Linux adapter advertises background capture', () {
    expect(clipboard.supportsBackgroundCapture, isTrue);
    expect(const SystemClipboardAccess(), isNot(isA<ClipboardChangeEvents>()));
  });

  test('native change signals have one subscription and work after close and reopen', () async {
    for (var cycle = 0; cycle < 2; cycle++) {
      var count = 0;
      final subscription = clipboard.changes.listen((_) => count++);
      await changed(cycle * 2 + 1);
      await changed(cycle * 2 + 2);
      expect(count, 2);
      await subscription.cancel();
      await changed(100 + cycle);
      expect(count, 2, reason: 'A stopped listener must not receive native clipboard events.');
    }
  });

  test('native events preserve explicit fresh reads and passive read flags', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'text': 'synthetic read ${calls.length}'};
    });
    final subscription = clipboard.changes.listen((_) {});
    addTearDown(subscription.cancel);
    await changed(1);
    expect((await clipboard.readContent())?.text, 'synthetic read 1');
    expect((await clipboard.readContent())?.text, 'synthetic read 2');
    expect((await clipboard.readContent(allowFocus: false))?.text, 'synthetic read 3');
    expect(calls.map((call) => call.method), everyElement('read'));
    expect(calls.map((call) => (call.arguments as Map)['allowFocus']), [true, true, false]);
  });
}
