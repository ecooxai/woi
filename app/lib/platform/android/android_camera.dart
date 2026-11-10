import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../camera.dart';
import '../media_capture.dart';
import 'android_bridge.dart';

/// Android owns permission UI and a camera foreground service. A successful
/// request can be pending; only the native first frame marks it active.
class AndroidCameraService extends CameraService {
  AndroidCameraService({AndroidBridge? bridge, this.front = false}) : _bridge = bridge ?? AndroidBridge.instance {
    _bridge.cameraCapture.addListener(_onState);
    _sub = _bridge.events.listen((event) {
      if (event is CameraFrameEvent && captureState.active && event.requestId == captureState.requestId) {
        _frames.value = CameraFrame(
          jpeg: event.jpeg,
          width: event.width,
          height: event.height,
          capturedAt: DateTime.now(),
        );
      }
    });
    _onState();
  }

  final AndroidBridge _bridge;
  bool front;
  final _active = ValueNotifier(false);
  final _frames = ValueNotifier<CameraFrame?>(null);
  StreamSubscription<AndroidEvent>? _sub;
  int _requestId = 0;

  @override
  ValueListenable<bool> get active => _active;
  @override
  ValueListenable<CameraFrame?> get frames => _frames;
  @override
  String? get lastError => captureState.error;
  @override
  MediaCaptureState get captureState => _bridge.cameraCapture.value;
  @override
  Listenable get changes => _bridge.cameraCapture;
  @override
  bool get supportsBackgroundCapture => true;
  @override
  bool get supportsFacingSelection => true;

  void _onState() {
    final state = captureState;
    if (!state.active || state.requestId != _requestId) _frames.value = null;
    _requestId = state.requestId;
    _active.value = state.active;
  }

  @override
  Future<MediaCaptureState> refreshCaptureState() => _bridge.refreshCapture('camera');

  @override
  Future<void> selectFacing(String facing) async {
    if (facing != 'front' && facing != 'back') throw CameraException('Camera facing must be front or back.');
    front = facing == 'front';
  }

  @override
  Future<void> open() async {
    try {
      final state = await _bridge.controlCapture('camera', true, front: front);
      if (!state.ok) throw CameraException(state.error ?? state.message ?? 'Camera could not start.');
    } on PlatformException catch (error) {
      throw CameraException(error.message ?? error.code);
    }
  }

  @override
  Future<void> close() async {
    // Stop even while off: a permission window or service start may be pending.
    try {
      final state = await _bridge.controlCapture('camera', false);
      if (state.active || state.pending) throw CameraException('Android has not stopped camera capture.');
    } on PlatformException catch (error) {
      throw CameraException(error.message ?? error.code);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await close();
    } finally {
      _bridge.cameraCapture.removeListener(_onState);
      await _sub?.cancel();
      _sub = null;
    }
  }
}
