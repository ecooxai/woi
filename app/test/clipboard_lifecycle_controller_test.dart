import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/platform/platform_services.dart';

import 'fakes/fakes.dart';

class _NativeClipboard implements ClipboardAccess, RichClipboardAccess, ClipboardChangeEvents {
  final events = StreamController<void>.broadcast(sync: true);
  String value = 'baseline';
  int reads = 0;
  final focusRequests = <bool>[];
  @override
  bool get supportsBackgroundCapture => true;
  @override
  Stream<void> get changes => events.stream;
  void copy(String text) {
    value = text;
    events.add(null);
  }

  @override
  Future<String?> readText() async => value;
  @override
  Future<void> writeText(String text) async => copy(text);
  @override
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async {
    reads++;
    focusRequests.add(allowFocus);
    return ClipboardContent(text: value);
  }

  @override
  Future<void> writeContent(ClipboardContent content) async => copy(content.text ?? '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> controllerFor(_NativeClipboard clipboard, {bool mobile = false}) async {
    final fake = await FakePlatform.create();
    final source = fake.services;
    final controller = AppController(
      platform: PlatformServices(
        paths: source.paths,
        audio: source.audio,
        screen: source.screen,
        input: source.input,
        shell: source.shell,
        files: source.files,
        viewer: source.viewer,
        clipboard: clipboard,
        isMobile: mobile,
        autoScreenshot: () => false,
      ),
      confirmations: FakeConfirmations(),
      backendFactory: ScriptedBackend.new,
      authManager: CodexAuthManager(path: '${fake.root.path}/no-auth.json'),
    );
    addTearDown(() async {
      await controller.shutdown();
      await clipboard.events.close();
      await fake.dispose();
    });
    await controller.init();
    expect(controller.initError, isNull);
    await controller.clipboardHistory.capture(allowFocus: false);
    return controller;
  }

  test('capable desktop captures while hidden and stops after detach', () async {
    final clipboard = _NativeClipboard();
    final controller = await controllerFor(clipboard);
    controller.onLifecycle(AppLifecycleState.hidden);
    await controller.clipboardHistory.capture(allowFocus: false);
    clipboard.copy('minimized A');
    await waitFor(
      () => controller.clipboardHistory.entries.any((entry) => entry.content.text == 'minimized A'),
      timeout: const Duration(seconds: 1),
    );
    clipboard.copy('minimized B');
    await waitFor(
      () => controller.clipboardHistory.entries.any((entry) => entry.content.text == 'minimized B'),
      timeout: const Duration(seconds: 1),
    );
    expect(
      controller.clipboardHistory.entries.map((entry) => entry.content.text),
      containsAll(['minimized A', 'minimized B']),
    );
    expect(clipboard.focusRequests, everyElement(isFalse));
    controller.onLifecycle(AppLifecycleState.detached);
    await waitFor(() => !controller.clipboardHistory.capturing);
    final reads = clipboard.reads;
    clipboard.copy('after detach');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(clipboard.reads, reads);
    controller.onLifecycle(AppLifecycleState.resumed);
    await waitFor(() => controller.clipboardHistory.entries.any((entry) => entry.content.text == 'after detach'));
  });

  test('mobile never gains background clipboard access from desktop capability', () async {
    final clipboard = _NativeClipboard();
    final controller = await controllerFor(clipboard, mobile: true);
    controller.onLifecycle(AppLifecycleState.paused);
    await waitFor(() => !controller.clipboardHistory.capturing);
    final reads = clipboard.reads;
    clipboard.copy('mobile background');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(clipboard.reads, reads);
    expect(controller.clipboardHistory.entries.any((entry) => entry.content.text == 'mobile background'), isFalse);
    controller.onLifecycle(AppLifecycleState.resumed);
    await waitFor(() => controller.clipboardHistory.entries.any((entry) => entry.content.text == 'mobile background'));
    expect(clipboard.focusRequests, everyElement(isFalse));
  });
}
