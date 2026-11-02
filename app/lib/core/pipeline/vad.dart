import 'dart:math';
import 'dart:typed_data';

import '../audio/wav.dart';

enum VadEvent { speechStarted, speechStopped }

/// Energy VAD with an adaptive noise floor, used when the backend has no
/// server-side turn detection.
class EnergyVad {
  EnergyVad({
    this.minThreshold = 0.02,
    this.noiseMultiplier = 3.0,
    this.startMs = 150,
    this.stopMs = 800,
    this.calibrationMs = 400,
  });

  final double minThreshold;
  final double noiseMultiplier;
  final int startMs;
  final int stopMs;

  /// Initial period that only learns the noise floor (never triggers).
  final int calibrationMs;

  double _noiseFloor = 0.005;
  bool _speaking = false;
  int _voicedMs = 0;
  int _silentMs = 0;
  int _calibratedMs = 0;

  /// Multiplies the threshold, e.g. while our own speaker output is playing
  /// (crude echo guard).
  double sensitivityScale = 1.0;

  bool get speaking => _speaking;
  double get noiseFloor => _noiseFloor;
  double get threshold => max(minThreshold, _noiseFloor * noiseMultiplier) * sensitivityScale;

  VadEvent? process(Uint8List pcm16) {
    final ms = pcmDurationMs(pcm16.length);
    if (ms == 0) return null;
    final rms = pcm16Rms(pcm16);
    if (_calibratedMs < calibrationMs) {
      // Fast average while calibrating so a noisy room starts with a sane floor.
      _noiseFloor = _calibratedMs == 0 ? rms : _noiseFloor * 0.8 + rms * 0.2;
      _calibratedMs += ms;
      return null;
    }
    final loud = rms >= threshold;
    if (!loud) {
      // Track ambient noise only on non-speech frames.
      _noiseFloor = _noiseFloor * 0.95 + rms * 0.05;
    }
    if (!_speaking) {
      _voicedMs = loud ? _voicedMs + ms : 0;
      if (_voicedMs >= startMs) {
        _speaking = true;
        _silentMs = 0;
        return VadEvent.speechStarted;
      }
    } else {
      _silentMs = loud ? 0 : _silentMs + ms;
      if (_silentMs >= stopMs) {
        _speaking = false;
        _voicedMs = 0;
        return VadEvent.speechStopped;
      }
    }
    return null;
  }

  void reset() {
    _speaking = false;
    _voicedMs = 0;
    _silentMs = 0;
  }
}
