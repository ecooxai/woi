import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/audio/wav.dart';
import '../audio_io.dart';
import 'android_bridge.dart';

/// Separate channel from normal listening, with an explicit readiness event.
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
      final released = await AndroidBridge.method.invokeMethod<bool>(
        'heldAudioStop',
      );
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

/// Consent may complete after the first hold was released. The recorder's
/// generation check prevents sending that cancelled gesture; the next hold
/// can use the now-approved projection.
Future<void> ensureSystemAudioProjection(AndroidBridge bridge) async {
  if (bridge.sharing.value) return;
  final ready = Completer<void>();
  void changed() {
    if (bridge.sharing.value && !ready.isCompleted) ready.complete();
  }

  bridge.sharing.addListener(changed);
  try {
    final accepted =
        await bridge
            .call<bool>('shareStart')
            .timeout(
              const Duration(minutes: 2),
              onTimeout: () => throw StateError(
                'Screen/audio permission was not completed. Hold again when ready.',
              ),
            ) ??
        false;
    if (!accepted) {
      throw StateError(
        'Open Woi and allow screen/audio capture, then hold the microphone again.',
      );
    }
    changed();
    await ready.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw StateError(
        'Screen/audio capture did not start. Enable screen sharing and try again.',
      ),
    );
  } finally {
    bridge.sharing.removeListener(changed);
  }
}
