import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';
import 'wav.dart';

/// Bounded, sample-aligned 24 kHz mono mixer. Both sources get equal headroom
/// and saturate safely; a stalled source contributes silence rather than
/// retaining seconds of old audio and replaying it after recovery.
class MicSystemPcmMixer {
  MicSystemPcmMixer({this.maxBufferedSamples = 4800});
  final int maxBufferedSamples;
  final _mic = Queue<int>();
  final _system = Queue<int>();

  int get pendingSamples =>
      _mic.length > _system.length ? _mic.length : _system.length;

  void addMic(Uint8List pcm) => _add(_mic, pcm);
  void addSystem(Uint8List pcm) => _add(_system, pcm);

  void _add(Queue<int> queue, Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      queue.add(data.getInt16(i, Endian.little));
    }
    while (queue.length > maxBufferedSamples) {
      queue.removeFirst();
    }
  }

  Uint8List take(int samples) {
    final out = Uint8List(samples * 2);
    final data = ByteData.sublistView(out);
    for (var i = 0; i < samples; i++) {
      final mic = _mic.isEmpty ? 0 : _mic.removeFirst();
      final system = _system.isEmpty ? 0 : _system.removeFirst();
      data.setInt16(
        i * 2,
        ((mic + system) * 0.7).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    return out;
  }
}

/// Owns both captures. Closing a cancelled or released hold closes both
/// native streams, even when one of them ends unexpectedly.
class MicSystemMixStream implements MicStream {
  MicSystemMixStream(this._mic, this._system) {
    _micSub = _mic.chunks.listen(_mixer.addMic, onError: _fail, onDone: _ended);
    _systemSub = _system.chunks.listen(
      _mixer.addSystem,
      onError: _fail,
      onDone: _ended,
    );
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_closed) return;
      final chunk = _mixer.take(480);
      _level.value = rmsToMeter(pcm16Rms(chunk));
      _chunks.add(chunk);
    });
  }

  final MicStream _mic, _system;
  final _mixer = MicSystemPcmMixer();
  final _chunks = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  late final StreamSubscription<Uint8List> _micSub, _systemSub;
  Timer? _timer;
  bool _closed = false;
  Future<void>? _closing;

  void _fail(Object error, StackTrace trace) {
    if (!_closed) _chunks.addError(error, trace);
    unawaited(close());
  }

  void _ended() {
    unawaited(close());
  }

  @override
  Stream<Uint8List> get chunks => _chunks.stream;
  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() => _closing ??= _doClose();

  Future<void> _doClose() async {
    _closed = true;
    _timer?.cancel();
    try {
      await Future.wait([_micSub.cancel(), _systemSub.cancel()]);
      await Future.wait([_mic.close(), _system.close()]);
    } finally {
      // Button release must keep the final partial audio frame. Queues are
      // bounded, so this cannot append a stale multi-second recording tail.
      while (_mixer.pendingSamples > 0) {
        final pending = _mixer.pendingSamples;
        _chunks.add(_mixer.take(pending > 480 ? 480 : pending));
      }
      _level.value = 0;
      await _chunks.close();
    }
  }
}
