import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/audio/playback_clock.dart';
import '../../core/audio/wav.dart';
import '../audio_io.dart';
import 'android_bridge.dart';

/// PCM16 / 24 kHz / mono through AudioRecord (VOICE_COMMUNICATION source,
/// platform AEC + noise suppression) and a streaming AudioTrack
/// (WoiAudio.kt). gpt-live does not use this: flutter_webrtc captures and
/// plays with its own echo-cancelled audio device module.
class AndroidAudioIO implements AudioIO {
  AndroidAudioIO({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;

  final AndroidBridge _bridge;

  @override
  String get description => 'Android AudioRecord (AEC) / AudioTrack';

  Future<void> _ensureMicPermission() async {
    final ok = await _bridge.requestPermissions(['android.permission.RECORD_AUDIO']);
    if (!ok) throw StateError('Microphone permission denied');
  }

  @override
  Future<MicStream> openMic() async {
    await _ensureMicPermission();
    return _AndroidMic();
  }

  @override
  Future<PcmPlayer> openPlayer() async {
    await _bridge.call<bool>('playerOpen');
    return _AndroidPlayer(_bridge);
  }

  @override
  Future<ClipPlayback> playFile(String path) async {
    final id = await _bridge.call<int>('clipPlay', {'path': path});
    return _AndroidClip(_bridge, id!);
  }
}

class _AndroidMic implements MicStream {
  _AndroidMic() {
    _sub = AndroidBridge.micChannel.receiveBroadcastStream().listen(
      (data) {
        if (data is! Uint8List || data.isEmpty) return;
        final m = rmsToMeter(pcm16Rms(data));
        final cur = _level.value;
        _level.value = m > cur ? m : cur * 0.7 + m * 0.3;
        _controller.add(data);
      },
      onError: (Object e) => _controller.addError(e),
      onDone: () => _controller.close(),
    );
  }

  final _controller = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  late final StreamSubscription<Object?> _sub;

  @override
  Stream<Uint8List> get chunks => _controller.stream;

  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    _level.value = 0;
  }
}

class _AndroidPlayer implements PcmPlayer {
  _AndroidPlayer(this._bridge);

  final AndroidBridge _bridge;
  // AudioTrack buffer (~100 ms) plus the mixer.
  final PlaybackClock _clock = PlaybackClock(outputLatency: const Duration(milliseconds: 140));
  bool _closed = false;

  @override
  void write(Uint8List pcm16) {
    if (_closed || pcm16.isEmpty) return;
    _clock.onWrite(pcm16);
    unawaited(_bridge.call<void>('playerWrite', pcm16).catchError((Object e) => debugPrint('player write: $e')));
  }

  @override
  Future<void> stop() async {
    _clock.reset();
    await _bridge.call<void>('playerStop');
  }

  @override
  bool get isPlaying => _clock.isPlaying;

  @override
  ValueListenable<double> get level => _clock.level;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _clock.dispose();
    // The AudioTrack is shared and idles itself (paused after 1 s silence).
    await _bridge.call<void>('playerStop');
  }
}

class _AndroidClip implements ClipPlayback {
  _AndroidClip(this._bridge, this._id) {
    _sub = _bridge.events.listen((e) {
      if (e is ClipDoneEvent && e.id == _id && !_done.isCompleted) _done.complete();
    });
    _done.future.whenComplete(() => _sub.cancel());
  }

  final AndroidBridge _bridge;
  final int _id;
  final _done = Completer<void>();
  late final StreamSubscription<AndroidEvent> _sub;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> stop() async {
    await _bridge.call<void>('clipStop', {'id': _id});
    if (!_done.isCompleted) _done.complete();
  }
}
