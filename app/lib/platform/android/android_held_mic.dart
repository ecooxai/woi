import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/audio/wav.dart';
import '../audio_io.dart';
import 'android_bridge.dart';

/// Microphone-only held recording, separate from normal listening, with an
/// explicit native readiness event and an awaited microphone-release handoff.
class AndroidHeldMic implements MicStream {
  AndroidHeldMic._() {
    _subscription = const EventChannel('woi/android/held_audio')
        .receiveBroadcastStream()
        .listen(_data, onError: _error, onDone: _done);
  }

  static Future<AndroidHeldMic> open() async {
    final stream = AndroidHeldMic._();
    try {
      await stream._ready.future.timeout(const Duration(seconds: 8));
      return stream;
    } catch (_) {
      await stream.close();
      rethrow;
    }
  }

  final _ready = Completer<void>();
  final _chunks = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  late final StreamSubscription<Object?> _subscription;
  bool _closed = false;
  Future<void>? _closing;

  void _data(Object? data) {
    if (_closed) return;
    if (data is Map && data['ready'] == true) {
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (data is! Uint8List || data.isEmpty) return;
    _level.value = rmsToMeter(pcm16Rms(data));
    _chunks.add(data);
  }

  void _error(Object error) {
    if (_closed) return;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    } else {
      _chunks.addError(error);
    }
  }

  void _done() {
    if (_closed) return;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Audio capture ended before it started'));
    }
    unawaited(_chunks.close());
  }

  @override
  Stream<Uint8List> get chunks => _chunks.stream;
  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() => _closing ??= _closeNative();

  Future<void> _closeNative() async {
    _closed = true;
    try {
      final released = await AndroidBridge.method.invokeMethod<bool>('heldAudioStop');
      if (released != true) {
        throw StateError('Native audio release was not confirmed');
      }
    } catch (error) {
      throw AudioCaptureReleaseFailure(error);
    } finally {
      try {
        await _subscription.cancel();
      } finally {
        if (!_chunks.isClosed) await _chunks.close();
        _level.value = 0;
        _level.dispose();
      }
    }
  }
}
