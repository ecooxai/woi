import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/clip_loudness.dart';
import 'package:woi/core/audio/wav.dart';

Uint8List _tone(double amp, {int ms = 1000, int rate = 24000}) {
  final n = rate * ms ~/ 1000;
  final b = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    b.setInt16(i * 2, (amp * 32767 * sin(2 * pi * 220 * i / rate)).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

double _peak(Uint8List pcm) {
  final b = ByteData.sublistView(pcm);
  var p = 0;
  for (var i = 0; i < pcm.length ~/ 2; i++) {
    p = max(p, b.getInt16(i * 2, Endian.little).abs());
  }
  return p / 32768;
}

void main() {
  test('a quiet recording is boosted, a loud one is left alone, silence is not', () {
    expect(speechGain(_tone(0.03)), greaterThan(5));
    expect(speechGain(_tone(0.5)), 1.0);
    expect(speechGain(Uint8List(48000)), 1.0);
  });

  test('the soft limiter never clips', () {
    final out = applyGain(_tone(0.5), 10);
    expect(_peak(out), lessThan(1.0));
    expect(_peak(out), greaterThan(0.9));
  });

  test('loudPlaybackPath writes a louder cached copy and keeps the original', () async {
    final dir = await Directory.systemTemp.createTemp('woi-loud');
    addTearDown(() => dir.delete(recursive: true));
    final quiet = '${dir.path}/q.wav';
    final loud = '${dir.path}/l.wav';
    await writeWav(quiet, _tone(0.03));
    await writeWav(loud, _tone(0.5));
    final cache = '${dir.path}/cache';
    final played = await loudPlaybackPath(quiet, cacheDir: cache);
    expect(played, isNot(quiet));
    final pcm = Uint8List.sublistView(await File(played).readAsBytes(), 44);
    expect(_peak(pcm), greaterThan(0.2));
    expect(await loudPlaybackPath(quiet, cacheDir: cache), played, reason: 'cached');
    expect(_peak(Uint8List.sublistView(await File(quiet).readAsBytes(), 44)), lessThan(0.04));
    expect(await loudPlaybackPath(loud, cacheDir: cache), loud);
    expect(await loudPlaybackPath('${dir.path}/missing.wav', cacheDir: cache), '${dir.path}/missing.wav');
  });
}
