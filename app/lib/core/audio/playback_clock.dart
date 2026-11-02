import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../voice/voice_backend.dart';
import 'wav.dart';

/// Tracks what part of a streamed PCM queue is audible "now", so the UI can
/// show the output level in sync and the pipeline knows when speech ends.
class PlaybackClock {
  PlaybackClock({this.outputLatency = const Duration(milliseconds: 60), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Duration outputLatency;
  final DateTime Function() _now;
  final ValueNotifier<double> level = ValueNotifier(0);
  final Queue<(DateTime, DateTime, double)> _segments = Queue();
  DateTime? _endAt;
  Timer? _ticker;

  bool get isPlaying {
    final end = _endAt;
    return end != null && _now().isBefore(end);
  }

  /// Time when everything queued so far will have been heard.
  DateTime? get endsAt => _endAt;

  void onWrite(Uint8List pcm) {
    if (pcm.isEmpty) return;
    final now = _now();
    var start = _endAt;
    if (start == null || start.isBefore(now)) start = now.add(outputLatency);
    final dur = Duration(microseconds: pcm.length * 1000000 ~/ kVoiceBytesPerSecond);
    final end = start.add(dur);
    _segments.add((start, end, rmsToMeter(pcm16Rms(pcm))));
    _endAt = end;
    _ticker ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  void _tick() {
    final now = _now();
    while (_segments.isNotEmpty && !_segments.first.$2.isAfter(now)) {
      _segments.removeFirst();
    }
    double target = 0;
    if (_segments.isNotEmpty && !_segments.first.$1.isAfter(now)) {
      target = _segments.first.$3;
    }
    // Fast attack, slower release.
    final cur = level.value;
    level.value = target > cur ? target : cur * 0.8 + target * 0.2;
    if (_segments.isEmpty && level.value < 0.01) {
      level.value = 0;
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void reset() {
    _segments.clear();
    _endAt = null;
    _ticker?.cancel();
    _ticker = null;
    level.value = 0;
  }

  void dispose() {
    _ticker?.cancel();
    level.dispose();
  }
}
