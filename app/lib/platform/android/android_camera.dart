import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../camera.dart';
import 'android_bridge.dart';

/// "open camera" on Android: the back camera through Camera2 (WoiCamera.kt),
/// ~4 upright JPEG frames a second while open; nothing runs while closed.
class AndroidCameraService extends CameraService {
  AndroidCameraService({AndroidBridge? bridge, this.front = false}) : _bridge = bridge ?? AndroidBridge.instance;

  final AndroidBridge _bridge;

  /// Selfie camera instead of the back camera.
  bool front;

  final _active = ValueNotifier(false);
  final _frames = ValueNotifier<CameraFrame?>(null);
  StreamSubscription<AndroidEvent>? _sub;
  String? _error;

  @override
  ValueListenable<bool> get active => _active;
  @override
  ValueListenable<CameraFrame?> get frames => _frames;
  @override
  String? get lastError => _error;

  @override
  Future<void> open() async {
    if (_active.value) return;
    if (!await _bridge.requestPermissions(['android.permission.CAMERA'])) {
      _error = 'camera permission denied';
      throw CameraException('Camera permission was denied (Android settings > Apps > Woi > Permissions).');
    }
    _sub ??= _bridge.events.listen((e) {
      if (e is CameraFrameEvent && _active.value) {
        _frames.value = CameraFrame(jpeg: e.jpeg, width: e.width, height: e.height, capturedAt: DateTime.now());
      }
    });
    try {
      await _bridge.call<bool>('cameraOpen', {'front': front});
    } on PlatformException catch (e) {
      _error = e.message ?? e.code;
      await _sub?.cancel();
      _sub = null;
      throw CameraException(_error!);
    }
    _error = null;
    _active.value = true;
  }

  @override
  Future<void> close() async {
    final was = _active.value;
    _active.value = false;
    _frames.value = null;
    await _sub?.cancel();
    _sub = null;
    if (was) {
      try {
        await _bridge.call<bool>('cameraClose');
      } catch (e) {
        debugPrint('camera close: $e');
      }
    }
  }
}
