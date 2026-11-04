// EchoGuard on synthesized signals: Woi's "speech" (harmonic voice with a
// syllable envelope) through an echo path (delay, room reverb, soft clip,
// clock drift, a canceller leaving residual -25 dB with bursts), the user a
// different voice. The rig in qa/aec (echo_guard_rig_test.dart) measures the
// same on rendered fixtures with the real WebRTC canceller.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/echo_guard.dart';

const _rate = 24000;

/// Voice-like signal: f0 with harmonics to 3.5 kHz, syllables of 120-250 ms
/// with short pauses, slow pitch movement.
Float64List _speech(double seconds, {required double f0, required int seed, double level = 0.2}) {
  final r = Random(seed);
  final n = (seconds * _rate).round();
  final out = Float64List(n);
  var i = 0;
  var phase = 0.0;
  while (i < n) {
    final syl = ((0.12 + 0.13 * r.nextDouble()) * _rate).round();
    final gap = ((0.03 + 0.08 * r.nextDouble()) * _rate).round();
    final f = f0 * (0.85 + 0.3 * r.nextDouble());
    for (var k = 0; k < syl && i < n; k++, i++) {
      final env = sin(pi * k / syl);
      phase += 2 * pi * f / _rate;
      var v = 0.0;
      for (var h = 1; h * f < 3500; h++) {
        v += sin(h * phase) / h;
      }
      out[i] = level * env * v * 0.5;
    }
    i += gap;
  }
  return out;
}

/// Echo path: delay, exponential-decay room reverb, soft clipping, drift.
Float64List _echoPath(Float64List x, {required int delayMs, double gain = 0.5, double ppm = 100, int seed = 3}) {
  final r = Random(seed);
  // Room: direct path plus a sparse exponentially decaying tail (a tap every
  // 8 samples over 300 ms, about -6 dB of reverberant energy).
  final y = Float64List.fromList(x);
  for (var k = 8; k < _rate * 3 ~/ 10; k += 8) {
    final w = 0.06 * (r.nextDouble() * 2 - 1) * exp(-k / (_rate * 0.06));
    for (var i = k; i < x.length; i++) {
      y[i] += w * x[i - k];
    }
  }
  final d = delayMs * _rate ~/ 1000;
  final out = Float64List(x.length);
  for (var i = 0; i < x.length; i++) {
    final src = (i - d) * (1 + ppm * 1e-6);
    final j = src.floor();
    if (j < 0 || j + 1 >= x.length) continue;
    final s = gain * (y[j] + (y[j + 1] - y[j]) * (src - j));
    out[i] = 0.7 * (2 / pi) * atan(s * 2); // speaker soft clip
  }
  return out;
}

Uint8List _pcm(Float64List x, int a, int b) {
  final out = Int16List(b - a);
  for (var i = a; i < b; i++) {
    out[i - a] = (x[i].clamp(-1.0, 1.0) * 32767).round();
  }
  return out.buffer.asUint8List();
}

class _Run {
  final onsets = <double>[];
  bool gatedDuringEcho = true;
}

/// Plays [far] (handed to the guard in 100 ms chunks 60 ms ahead), feeds
/// [mic] in 20 ms chunks [micDelayMs] after capture.
_Run _run(EchoGuard g, Float64List far, Float64List mic, {int micDelayMs = 40, List<double>? echoOnly}) {
  final run = _Run();
  var nowUs = 0;
  final guard = g;
  _clock = 0;
  var nextFar = 0;
  const chunk = _rate ~/ 50;
  for (var e = chunk; e <= mic.length; e += chunk) {
    final t = e / _rate;
    nowUs = ((t + micDelayMs / 1000) * 1e6).round();
    _clock = nowUs;
    while (nextFar < far.length && nextFar / _rate - 0.06 <= nowUs / 1e6) {
      final end = min(nextFar + _rate ~/ 10, far.length);
      guard.onPlayback(_pcm(far, nextFar, end));
      nextFar = end;
    }
    if (guard.process(_pcm(mic, e - chunk, e), audible: true)) run.onsets.add(t);
    if (echoOnly != null && t > echoOnly[0] && t < echoOnly[1] && (!guard.echoExpected || guard.gateOpen)) {
      run.gatedDuringEcho = false;
    }
  }
  return run;
}

int _clock = 0;

void main() {
  final far = _speech(8, f0: 130, seed: 1);
  final user = _speech(1.2, f0: 220, seed: 2, level: 0.25);

  Float64List mix(Float64List echo, {double residual = 1, double? userAt}) {
    final m = Float64List(echo.length);
    final r = Random(9);
    for (var i = 0; i < m.length; i++) {
      m[i] = echo[i] * residual + 1e-4 * (r.nextDouble() * 2 - 1);
    }
    if (userAt != null) {
      final a = (userAt * _rate).round();
      for (var i = 0; i < user.length && a + i < m.length; i++) {
        m[a + i] += user[i];
      }
    }
    return m;
  }

  for (final delay in [100, 200, 300]) {
    test('raw echo (delay $delay ms, reverb, clip, drift): no onset, gated throughout', () {
      final g = EchoGuard(nowUs: () => _clock);
      final run = _run(g, far, mix(_echoPath(far, delayMs: delay)), echoOnly: [0.1, 8.2]);
      expect(run.onsets, isEmpty);
      expect(run.gatedDuringEcho, isTrue);
    });
  }

  test('canceller residual (-25 dB with a 0 dB burst at a reply start): no onset', () {
    final echo = _echoPath(far, delayMs: 180);
    final m = mix(echo, residual: 0.056);
    // Re-convergence burst 4.0-4.4 s: residual at full echo level.
    for (var i = (4.0 * _rate).round(); i < (4.4 * _rate).round(); i++) {
      m[i] = echo[i];
    }
    final run = _run(EchoGuard(nowUs: () => _clock), far, m);
    expect(run.onsets, isEmpty);
  });

  test('the user talking over Woi: one onset within 300 ms, the gate opens', () {
    final g = EchoGuard(nowUs: () => _clock);
    final m = mix(_echoPath(far, delayMs: 200), residual: 0.1, userAt: 5.0);
    final run = _run(g, far, m);
    expect(run.onsets, hasLength(1));
    expect(run.onsets.single, inInclusiveRange(5.0, 5.3));
    expect(g.gateOpen, isTrue);
  });

  test('after the reply (and its echo tail) nothing is gated; a new reply re-arms', () {
    final g = EchoGuard(nowUs: () => _clock);
    _clock = 0;
    g.onPlayback(_pcm(far, 0, _rate)); // 1 s
    expect(g.echoExpected, isTrue);
    _clock = 1700000; // 1 s + 60 ms + 600 ms window + slack
    expect(g.echoExpected, isFalse);
    expect(g.queuedMs, 0);
    g.onPlayback(_pcm(far, 0, _rate ~/ 10));
    expect(g.echoExpected, isTrue);
    expect(g.gateOpen, isFalse);
    expect(g.queuedMs, inInclusiveRange(150, 170));
    g.stopPlayback();
    expect(g.queuedMs, lessThanOrEqualTo(70));
  });
}
