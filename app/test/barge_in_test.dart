import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/barge_in.dart';

/// 20 ms of a tone at [amp] (0..1), optionally with seeded noise.
Uint8List tone(double amp, {double hz = 220, int ms = 20, int phase = 0, double noise = 0, Random? rnd}) {
  const rate = 24000;
  final n = rate * ms ~/ 1000;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    var v = amp * sin(2 * pi * hz * (phase + i) / rate);
    if (noise > 0) v += noise * (rnd!.nextDouble() * 2 - 1);
    b.setInt16(i * 2, (v.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

Uint8List mix(Uint8List a, Uint8List b) {
  final x = ByteData.sublistView(a), y = ByteData.sublistView(b);
  final out = ByteData(a.length);
  for (var i = 0; i < a.length; i += 2) {
    out.setInt16(i, (x.getInt16(i, Endian.little) + y.getInt16(i, Endian.little)).clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

void main() {
  group('BargeInDetector', () {
    test('ignores speaker echo, fires on the user talking over it', () {
      final d = BargeInDetector();
      final rnd = Random(1);
      // 2 s of assistant speech with a varying level; the mic hears 30 % echo.
      for (var i = 0; i < 100; i++) {
        final level = 0.2 + 0.3 * (i % 7) / 7;
        final play = tone(level, phase: i * 480);
        d.onPlayback(play);
        final echo = tone(level * 0.3, phase: i * 480, noise: 0.002, rnd: rnd);
        expect(d.process(echo, audible: true), isFalse, reason: 'echo frame $i');
      }
      // User starts talking (louder than the echo): fires within ~140 ms.
      var firedAt = -1;
      for (var i = 0; i < 20; i++) {
        final play = tone(0.35, phase: i * 480);
        d.onPlayback(play);
        final mic = mix(tone(0.35 * 0.3, phase: i * 480), tone(0.3, hz: 140, phase: i * 480));
        if (d.process(mic, audible: true)) {
          firedAt = i;
          break;
        }
      }
      expect(firedAt, inInclusiveRange(4, 7));
    });

    test('fires once per reply and re-arms after silence', () {
      final d = BargeInDetector(warmupMs: 0);
      var fires = 0;
      for (var i = 0; i < 30; i++) {
        if (d.process(tone(0.3), audible: true)) fires++;
      }
      expect(fires, 1);
      for (var i = 0; i < 5; i++) {
        d.process(tone(0.001), audible: false);
      }
      for (var i = 0; i < 30; i++) {
        if (d.process(tone(0.3), audible: true)) fires++;
      }
      expect(fires, 2);
    });

    test('never fires while nothing is playing', () {
      final d = BargeInDetector(warmupMs: 0);
      for (var i = 0; i < 50; i++) {
        expect(d.process(tone(0.5), audible: false), isFalse);
      }
    });

    test('a short click is not an onset', () {
      final d = BargeInDetector(warmupMs: 0);
      expect(d.process(tone(0.4, ms: 60), audible: true), isFalse);
      for (var i = 0; i < 10; i++) {
        expect(d.process(tone(0.001), audible: true), isFalse);
      }
    });

    test('handles odd chunk sizes', () {
      final d = BargeInDetector(warmupMs: 0);
      final big = tone(0.3, ms: 400);
      var hit = false;
      for (var o = 0; o < big.length; o += 333 * 2 + 1) {
        hit |= d.process(Uint8List.sublistView(big, o, min(o + 667, big.length)), audible: true);
      }
      expect(hit, isTrue);
    });
  });

  group('isStopPhrase', () {
    for (final s in ['Stop', 'stop.', 'Stop!', 'Okay, stop.', 'Please stop', 'stop talking', 'Cancel', 'cancel that',
      'Never mind', 'Nevermind.', 'Forget it', 'Woi, stop.', 'Stop, please.', 'Be quiet', 'That\'s enough']) {
      test('"$s" is a stop phrase', () => expect(isStopPhrase(s), isTrue));
    }
    for (final s in ['Stop the music player and open Firefox', 'How do I cancel my subscription?',
      'Don\'t stop', 'Hello, how are you?', '', 'Show me the file stop.txt']) {
      test('"$s" is not a stop phrase', () => expect(isStopPhrase(s), isFalse));
    }
  });
}
