import 'dart:convert';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/platform/camera.dart';
import 'package:woi/platform/media_capture.dart';
import 'package:woi/platform/platform_services.dart';

import 'fakes/fakes.dart';

class _PendingCamera extends FakeCamera {
  final state = ValueNotifier(const MediaCaptureState());
  @override
  MediaCaptureState get captureState => state.value;
  @override
  Listenable get changes => state;
  @override
  bool get supportsBackgroundCapture => true;
  @override
  Future<void> open() async {
    opens++;
    state.value = const MediaCaptureState(state: 'permission_pending');
  }

  void firstFrame() {
    (active as ValueNotifier<bool>).value = true;
    state.value = const MediaCaptureState(state: 'active', frames: 1);
    push();
  }

  @override
  Future<void> close() async {
    await super.close();
    state.value = const MediaCaptureState();
  }
}

class _NoFrameCamera extends FakeCamera {
  @override
  Future<void> open() async {
    opens++;
    (active as ValueNotifier<bool>).value = true;
  }

  @override
  Future<CameraFrame?> nextFrame({Duration timeout = const Duration(seconds: 4)}) async => null;
}

class _SharingScreen extends FakeScreen implements ScreenSharingControl {
  @override
  final ValueNotifier<MediaCaptureState> sharingState = ValueNotifier(const MediaCaptureState());
  @override
  Future<MediaCaptureState> refreshSharing() async => sharingState.value;
  @override
  Future<MediaCaptureState> setSharing(bool on) async =>
      sharingState.value = MediaCaptureState(state: on ? 'permission_pending' : 'inactive');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ScriptedBackend? latestBackend;
  var backendCreations = 0;
  Future<AppController> controllerFor(CameraService camera) async {
    latestBackend = null;
    backendCreations = 0;
    final fake = await FakePlatform.create();
    final source = fake.services;
    final controller = AppController(
      platform: PlatformServices(
        paths: source.paths,
        audio: source.audio,
        screen: _SharingScreen(),
        input: source.input,
        shell: source.shell,
        files: source.files,
        viewer: source.viewer,
        camera: camera,
        isMobile: true,
        autoScreenshot: () => false,
      ),
      confirmations: FakeConfirmations(),
      backendFactory: () {
        backendCreations++;
        return latestBackend = ScriptedBackend();
      },
      authManager: CodexAuthManager(path: '${fake.root.path}/no-auth.json'),
    );
    addTearDown(() async {
      await controller.shutdown();
      await fake.dispose();
    });
    await controller.init();
    expect(controller.initError, isNull);
    return controller;
  }

  test('registered model tools preserve pending state and Android background ownership', () async {
    final camera = _PendingCamera();
    final controller = await controllerFor(camera);
    expect(controller.tools.specs.map((t) => t.name), containsAll(['camera', 'screen_share']));
    final pending = jsonDecode(
      (await controller.tools.dispatch('camera', '{"action":"open"}', callId: 'native_model_call')).json,
    );
    expect(pending['state'], 'permission_pending');
    expect(pending['on'], isFalse);
    expect(controller.cameraBusy, isTrue);
    controller.onLifecycle(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(camera.closes, 0, reason: 'Android consent/foreground capture may outlive the main activity');
    camera.firstFrame();
    expect(controller.cameraOn, isTrue);
    expect(controller.cameraBusy, isFalse);
    final active = jsonDecode((await controller.tools.dispatch('camera', '{"action":"status"}')).json);
    expect(active['state'], 'active');
    final share = jsonDecode((await controller.tools.dispatch('screen_share', '{"action":"start"}')).json);
    expect(share['pending'], isTrue);
    expect(share['on'], isFalse);
    final stopped = jsonDecode((await controller.tools.dispatch('camera', '{"action":"close"}')).json);
    expect(stopped['state'], 'inactive');
    expect(controller.cameraOn, isFalse);
  });

  test('typed explicit capture uses the production registry without a provider turn', () async {
    final camera = _PendingCamera();
    final controller = await controllerFor(camera);
    await controller.pipeline.suspend();
    final before = backendCreations;
    expect(controller.pipeline.status, SessionStatus.disconnected);
    controller.pipeline.sendText('Please open the camera');
    for (
      var i = 0;
      i < 20 && !controller.pipeline.conversation.messages.any((m) => m.text.contains('Waiting for Android capture'));
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(camera.opens, 1);
    expect(backendCreations, before, reason: 'A local command must not bootstrap a provider');
    expect(latestBackend?.texts ?? [], isEmpty);
    expect(latestBackend?.images ?? [], isEmpty);
    expect(camera.captureState.state, 'permission_pending');
    expect(
      controller.pipeline.conversation.messages.any((m) => m.text.contains('Waiting for Android capture')),
      isTrue,
    );
    camera.firstFrame();
    await Future<void>.delayed(Duration.zero);
    expect(controller.pipeline.contextImagesSent, 0);
    expect(controller.pipeline.conversation.messages.where((m) => m.image != null), isEmpty);
    expect(backendCreations, before);
    controller.pipeline.sendText('Close the camera');
    for (var i = 0; i < 20 && camera.captureState.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(camera.captureState.active, isFalse);
    for (final request in [
      'do not open the camera',
      '"open the camera"',
      'open the camera if it is dark',
      'how do I open the camera?',
    ]) {
      controller.pipeline.sendText(request);
      expect(
        controller.pipeline.conversation.messages.where((m) => m.text == request),
        hasLength(1),
        reason: 'An offline ordinary message must remain recoverable',
      );
    }
    expect(camera.opens, 1);
    expect(backendCreations, before);
  });

  test('a camera start without a usable frame is stopped and never reported active', () async {
    final camera = _NoFrameCamera();
    final controller = await controllerFor(camera);
    final result = jsonDecode((await controller.tools.dispatch('camera', '{"action":"open"}')).json);
    expect(result['ok'], isFalse);
    expect(result['on'], isFalse);
    expect(result['state'], 'error');
    expect(camera.closes, 1);
    expect(controller.cameraOn, isFalse);
  });
}
