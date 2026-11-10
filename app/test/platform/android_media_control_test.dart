import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/media/media_context.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_camera.dart';
import 'package:woi/platform/android/android_screen_capture.dart';
import 'package:woi/platform/media_capture.dart';
import 'package:woi/tools/media_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import '../fakes/live_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const eventChannel = MethodChannel('woi/android/events');
  final bridge = AndroidBridge.instance;
  late AndroidCameraService camera;
  late AndroidScreenCapture screen;
  late ToolRegistry registry;
  late Map<String, Map<String, Object?>> native;
  late List<MethodCall> calls;
  var revision = 0;
  var request = 0;

  Map<String, Object?> state(String phase, {int? id, String? facing, String? error}) => {
    'ok': error == null,
    'state': phase,
    'on': phase == 'active',
    'pending': phase == 'permission_pending' || phase == 'starting',
    'requestId': id ?? ++request,
    'revision': ++revision,
    'facing': ?facing,
    'error': ?error,
    'frames': phase == 'active' ? 1 : 0,
    'message': phase == 'permission_pending' ? 'Complete Android consent; capture is not active.' : phase,
  };

  Future<void> event(Map<String, Object?> value) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      eventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> publish(String kind, Map<String, Object?> value) async {
    native[kind] = value;
    await event({...value, 'type': 'capture', 'kind': kind});
  }

  Future<Map<String, dynamic>> dispatch(String tool, Map<String, Object?> arguments) async =>
      jsonDecode((await registry.dispatch(tool, jsonEncode(arguments), callId: 'model_capture')).json)
          as Map<String, dynamic>;

  setUp(() async {
    calls = [];
    revision = 0;
    request = 0;
    bridge.cameraCapture.value = const MediaCaptureState();
    bridge.screenCapture.value = const MediaCaptureState();
    bridge.sharing.value = false;
    native = {'camera': state('inactive', facing: 'back'), 'screen': state('inactive')};
    messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      final arguments = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'init':
          return {
            'filesDir': '/test',
            'cacheDir': '/test/cache',
            'sdk': 35,
            'model': 'Test Android',
            'screenWidth': 100,
            'screenHeight': 200,
            'density': 1.0,
            'package': 'dev.woi.woi',
          };
        case 'status':
          return {'sharing': native['screen']!['on'], 'accessibility': true};
        case 'mediaCaptureStatus':
          return native[arguments['kind']];
        case 'cameraOpen':
        case 'shareStart':
          final kind = call.method == 'cameraOpen' ? 'camera' : 'screen';
          final facing = kind == 'camera'
              ? arguments['front'] == true
                    ? 'front'
                    : 'back'
              : null;
          final current = native[kind]!;
          if ((current['on'] == true || current['pending'] == true) &&
              (kind == 'screen' || current['facing'] == facing)) {
            return current;
          }
          return native[kind] = state('permission_pending', facing: facing);
        case 'cameraClose':
        case 'shareStop':
          final kind = call.method == 'cameraClose' ? 'camera' : 'screen';
          return native[kind] = state('inactive', facing: native[kind]!['facing'] as String?);
      }
      throw PlatformException(code: 'unexpected', message: call.method);
    });
    await bridge.init();
    await bridge.refreshStatus();
    camera = AndroidCameraService(bridge: bridge);
    screen = AndroidScreenCapture(bridge: bridge);
    registry = ToolRegistry()
      ..registerAll(
        mediaTools(
          MediaToolsHost(
            setCamera: (on) async {
              if (on) {
                await camera.open();
              } else {
                await camera.close();
              }
              return camera.captureState.toToolResult();
            },
            cameraOn: () => camera.active.value,
            cameraStatus: () async => (await camera.refreshCaptureState()).toToolResult(),
            setCameraFacing: (facing) async {
              await camera.selectFacing(facing);
              await camera.open();
              return camera.captureState.toToolResult();
            },
            setScreenSharing: (on) async => (await screen.setSharing(on)).toToolResult(),
            screenSharingStatus: () async => (await screen.refreshSharing()).toToolResult(),
            inspectMedia: (_) async => {'ok': true},
          ),
        ),
      );
    calls.clear();
  });

  tearDown(() async {
    await camera.dispose();
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
  });

  test('production tool dispatch reports camera consent pending, then first-frame active', () async {
    final pending = await dispatch('camera', {'action': 'open'});
    expect(pending, containsPair('state', 'permission_pending'));
    expect(pending, containsPair('on', false));
    expect(camera.active.value, isFalse);
    expect(camera.latest(), isNull);
    expect(calls.map((e) => e.method), ['cameraOpen']);
    final id = native['camera']!['requestId'] as int;
    await publish('camera', state('starting', id: id, facing: 'back'));
    expect((await dispatch('camera', {'action': 'status'}))['on'], isFalse);
    await publish('camera', state('active', id: id, facing: 'back'));
    await event({
      'type': 'camera',
      'requestId': id,
      'jpeg': Uint8List.fromList([1, 2, 3]),
      'width': 2,
      'height': 2,
    });
    final active = await dispatch('camera', {'action': 'status'});
    expect(active['state'], 'active');
    expect(active['frames_received'], 1);
    expect(camera.latest(), isNotNull);
    expect((await dispatch('camera', {'action': 'close'}))['on'], isFalse);
    expect(camera.latest(), isNull);
  });

  test('late pending method reply cannot regress an already active first frame', () async {
    final pending = state('permission_pending', facing: 'back');
    final answer = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      if (call.method == 'cameraOpen') return answer.future;
      if (call.method == 'cameraClose') return native['camera'] = state('inactive');
      if (call.method == 'mediaCaptureStatus') return native['camera'];
      throw PlatformException(code: 'unexpected', message: call.method);
    });
    final opening = camera.open();
    await Future<void>.delayed(Duration.zero);
    final id = pending['requestId'] as int;
    await publish('camera', state('active', id: id, facing: 'back'));
    await event({
      'type': 'camera',
      'requestId': id,
      'jpeg': Uint8List.fromList([1]),
      'width': 1,
      'height': 1,
    });
    expect(camera.latest(), isNotNull);
    answer.complete(pending);
    await opening;
    expect(camera.captureState.state, 'active');
    expect(camera.captureState.requestId, id);
    expect(camera.latest(), isNotNull);
  });

  test('stop cancels pending start and late state/frame cannot revive it', () async {
    await dispatch('camera', {'action': 'open'});
    final old = Map<String, Object?>.of(native['camera']!);
    await dispatch('camera', {'action': 'close'});
    await event({...old, 'type': 'capture', 'kind': 'camera', 'state': 'active', 'on': true});
    await event({
      'type': 'camera',
      'requestId': old['requestId'],
      'jpeg': Uint8List.fromList([1]),
      'width': 1,
      'height': 1,
    });
    expect(camera.captureState.state, 'inactive');
    expect(camera.active.value, isFalse);
    expect(camera.frames.value, isNull);
  });

  test('denial and runtime failure remain off and visible in status', () async {
    await dispatch('camera', {'action': 'open'});
    final id = native['camera']!['requestId'] as int;
    await publish('camera', state('denied', id: id, error: 'Camera permission denied.'));
    expect((await dispatch('camera', {'action': 'status'})), containsPair('ok', false));
    expect(camera.active.value, isFalse);
    await dispatch('camera', {'action': 'open'});
    final next = native['camera']!['requestId'] as int;
    await publish('camera', state('active', id: next));
    await publish('camera', state('error', id: next, error: 'Camera disconnected.'));
    final failed = await dispatch('camera', {'action': 'status'});
    expect(failed['error'], 'Camera disconnected.');
    expect(failed['on'], isFalse);
  });

  test('front/back switch is explicit, validated, and repeat start is idempotent', () async {
    await dispatch('camera', {'action': 'open', 'facing': 'front'});
    expect(calls.single.arguments, {'front': true});
    final first = native['camera']!['requestId'];
    await dispatch('camera', {'action': 'open', 'facing': 'front'});
    expect(native['camera']!['requestId'], first);
    await dispatch('camera', {'action': 'switch', 'facing': 'back'});
    expect(calls.last.arguments, {'front': false});
    final count = calls.length;
    expect((await dispatch('camera', {'action': 'switch'}))['ok'], isFalse);
    expect((await dispatch('camera', {'action': 'open', 'facing': 'side'}))['ok'], isFalse);
    expect((await dispatch('camera', {'action': 'close', 'facing': 'front'}))['ok'], isFalse);
    expect(calls.length, count);
  });

  test('screen sharing tool and manual service share pending, active and stop state', () async {
    final start = await dispatch('screen_share', {'action': 'start'});
    expect(start['on'], isFalse);
    expect(start['pending'], isTrue);
    expect(screen.autoCapture, isFalse);
    final id = native['screen']!['requestId'] as int;
    await publish('screen', state('active', id: id));
    expect(screen.autoCapture, isTrue);
    expect((await dispatch('screen_share', {'action': 'status'}))['on'], isTrue);
    await screen.setSharing(false); // same method used by the manual button
    expect(screen.autoCapture, isFalse);
    expect((await dispatch('screen_share', {'action': 'status'}))['state'], 'inactive');
    await dispatch('screen_share', {'action': 'start'});
    expect((await dispatch('screen_share', {'action': 'stop'}))['pending'], isFalse);
  });

  test('gpt-live explicit capture delegation dispatches production tool without provider call', () async {
    final model = FakeDelegationModel([]);
    final executor = DelegationExecutor(
      model: model,
      tools: registry.specs,
      runTool: (id, name, args) async => (await registry.dispatch(name, args, callId: id)).json,
    );
    final pending = await executor.execute('Please share my screen with Woi');
    expect(pending.tools.single.name, 'screen_share');
    expect(pending.resultText, startsWith('Capture requested; Android capture is not active yet.'));
    expect(model.requests, isEmpty);
    final stopped = await executor.execute('Stop sharing my screen');
    expect(jsonDecode(stopped.tools.single.argsJson), {'action': 'stop'});
    expect(screen.autoCapture, isFalse);
  });

  test('capture fast paths require complete intended actions', () {
    for (final text in ['Please share my screen', 'Start screen sharing', 'Could you open screen share?']) {
      expect(mediaCaptureCommand(text)?.arguments, {'action': 'start'}, reason: text);
    }
    expect(mediaCaptureCommand('switch to the front camera')?.arguments, {'action': 'switch', 'facing': 'front'});
    expect(mediaCaptureCommand('Is the camera active?')?.arguments, {'action': 'status'});
    expect(mediaCaptureCommand('screen sharing status')?.tool, 'screen_share');
    for (final text in [
      'Do not share my screen',
      'When I say open camera, explain it',
      'The button says "start screen sharing"',
      'How does screen sharing work?',
      'What is on my screen?',
      'I bought a camera',
      'If needed, open the camera',
    ]) {
      expect(mediaCaptureCommand(text), isNull, reason: text);
    }
  });
}
