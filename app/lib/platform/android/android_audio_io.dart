import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/audio/playback_clock.dart';
import '../../core/audio/wav.dart';
import '../audio_io.dart';
import 'android_bridge.dart';
import 'android_held_mic.dart';

/// PCM16 / 24 kHz / mono through AudioRecord and a streaming AudioTrack
/// (WoiAudio.kt). The [audioRoute] 'phone' (default) runs the call path
/// while the mic is open (MODE_IN_COMMUNICATION, VOICE_COMMUNICATION
/// capture, voice-call playback on the loudspeaker or a headset: the call
/// echo canceller); 'media' plays as media and records VOICE_RECOGNITION
/// with the AEC effect where available. With [echoCancellation] off the mic
/// records from the plain MIC source. While another app records, the mic is
/// released ([micPaused]) and resumes when the mic is free. gpt-live does
/// not use this: flutter_webrtc captures and plays with its own
/// echo-cancelled audio device module.
class AndroidAudioIO implements AudioIO, EchoCancellable, AudioRouted, HeldAudioCapture {
  AndroidAudioIO({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;

  final AndroidBridge _bridge;
  bool _echoCancellation = true;
  String _route = 'phone';
  final _micPaused = ValueNotifier<String?>(null);
  StreamSubscription<AndroidEvent>? _stateSub;

  @override
  set audioRoute(String route) => _route = route == 'media' ? 'media' : 'phone';

  @override
  ValueListenable<String?> get micPaused => _micPaused;

  /// What the last mic open got (WoiAudio "aecStatus").
  String _aecStatus = 'not started';

  @override
  bool get echoCancellation => _echoCancellation;

  @override
  set echoCancellation(bool on) => _echoCancellation = on;

  @override
  String get echoCancellationStatus => _echoCancellation ? _aecStatus : 'off (setting)';

  @override
  Future<void> disposeEchoCancellation() async {}

  @override
  String get description =>
      'Android AudioRecord / AudioTrack ($_route route); echo cancellation: $echoCancellationStatus';

  Future<void> _ensureMicPermission() async {
    final ok = await _bridge.requestPermissions(['android.permission.RECORD_AUDIO']);
    if (!ok) throw StateError('Microphone permission denied');
  }

  @override
  Future<MicStream> openMic() async {
    await _ensureMicPermission();
    _stateSub ??= _bridge.events.listen((e) {
      if (e is MicStateEvent) {
        _micPaused.value = e.paused ? (e.reason ?? 'Mic paused') : null;
      }
    });
    final mic = _AndroidMic(echoCancellation: _echoCancellation, route: _route, onClose: () => _micPaused.value = null);
    unawaited(_refreshAecStatus());
    return mic;
  }

  @override
  bool get includesSystemAudio => false;

  @override
  Future<MicStream> openHeldAudio() async {
    await _ensureMicPermission();
    return AndroidHeldMic.open();
  }

  Future<void> _refreshAecStatus() async {
    // The recorder starts on the channel's listen; ask once it has.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      _aecStatus = await _bridge.call<String>('aecStatus') ?? _aecStatus;
    } catch (_) {}
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
  _AndroidMic({required bool echoCancellation, required String route, required this.onClose}) {
    _sub = AndroidBridge.micChannel
        .receiveBroadcastStream({'aec': echoCancellation, 'route': route})
        .listen(
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
  final VoidCallback onClose;

  @override
  Stream<Uint8List> get chunks => _controller.stream;

  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    _level.value = 0;
    onClose();
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
      if (e is ClipDoneEvent && e.id == _id && !_done.isCompleted) {
        _done.complete();
      }
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
