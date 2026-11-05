import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/playback_clock.dart';
import 'package:woi/core/voice/voice_backend.dart';

void main() {
  test('isPlaying from the first write until the queued audio has played', () {
    var now = DateTime(2026, 1, 1);
    final c = PlaybackClock(outputLatency: const Duration(milliseconds: 60), now: () => now);
    expect(c.isPlaying, isFalse);
    // The server sends 1 s of audio in a burst (faster than real time).
    for (var i = 0; i < 10; i++) {
      c.onWrite(Uint8List(kVoiceBytesPerSecond ~/ 10));
    }
    expect(c.isPlaying, isTrue, reason: 'queued, inside the output latency');
    now = now.add(const Duration(milliseconds: 500));
    expect(c.isPlaying, isTrue, reason: 'mid playback');
    now = now.add(const Duration(milliseconds: 550));
    expect(c.isPlaying, isTrue, reason: 'latency + 1 s not over yet');
    now = now.add(const Duration(milliseconds: 20));
    expect(c.isPlaying, isFalse);
    c.onWrite(Uint8List(kVoiceBytesPerSecond ~/ 10));
    expect(c.isPlaying, isTrue, reason: 'a new stretch');
    c.reset();
    expect(c.isPlaying, isFalse, reason: 'stopped');
    c.dispose();
  });
}
