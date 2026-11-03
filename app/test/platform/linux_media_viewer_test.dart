import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/linux_media_viewer.dart';
import 'package:woi/platform/media_viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;
  late Object? Function(Map<Object?, Object?> args) onOpen;

  setUp(() {
    calls = [];
    var next = 0;
    onOpen = (_) => true;
    messenger.setMockMethodCallHandler(windows, (call) async {
      calls.add(call.method);
      return call.method == 'createWindow' ? 'w${next++}' : null;
    });
    messenger.setMockMethodCallHandler(channels, (call) async {
      final args = (call.arguments as Map).cast<Object?, Object?>();
      calls.add('${call.method}:${args['method']}');
      return onOpen(args);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(windows, null);
    messenger.setMockMethodCallHandler(channels, null);
  });

  const readme = MediaItem(kind: MediaKind.text, path: '/tmp/README.md');
  const image = MediaItem(kind: MediaKind.image, path: '/tmp/a.png');

  test('the second file reuses the (possibly hidden) viewer window', () async {
    final viewer = LinuxMediaViewer();
    expect(await viewer.show(readme), ViewerSurface.window);
    expect(await viewer.show(image), ViewerSurface.window);
    expect(calls, ['createWindow', 'window_show', 'invokeMethod:${LinuxMediaViewer.openMethod}', 'window_show']);
  });

  test('a viewer that cannot be reached is replaced by a new window', () async {
    final viewer = LinuxMediaViewer();
    await viewer.show(readme);
    onOpen = (_) => throw PlatformException(code: 'CHANNEL_NOT_FOUND');
    expect(await viewer.show(image), ViewerSurface.window);
    expect(calls.where((c) => c == 'createWindow'), hasLength(2));
  });
}
