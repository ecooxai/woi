import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'wav.dart';

/// Gain that brings the loud (speech) part of [pcm16] to [target] RMS,
/// never above [maxGain], 1.0 when it is already loud enough.
///
/// The level is the 90th percentile of 20 ms frame RMS over the frames above
/// the noise floor, so pauses and silence do not drag it down.
double speechGain(Uint8List pcm16, {int sampleRate = 24000, double target = 0.2, double maxGain = 24}) {
  final n = pcm16.length ~/ 2;
  if (n == 0) return 1;
  final bd = ByteData.sublistView(pcm16);
  final frame = max(1, sampleRate ~/ 50);
  final levels = <double>[];
  for (var start = 0; start < n; start += frame) {
    final end = min(n, start + frame);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    final rms = sqrt(sum / (end - start));
    if (rms > 0.002) levels.add(rms); // above about -54 dBFS
  }
  if (levels.isEmpty) return 1;
  levels.sort();
  final level = levels[min(levels.length - 1, (levels.length * 0.9).floor())];
  return (target / level).clamp(1.0, maxGain);
}

/// [pcm16] times [gain] with a soft limiter above [knee] (no hard clipping).
Uint8List applyGain(Uint8List pcm16, double gain, {double knee = 0.8}) {
  final n = pcm16.length ~/ 2;
  final src = ByteData.sublistView(pcm16);
  final out = Uint8List(n * 2);
  final dst = ByteData.sublistView(out);
  final room = 1 - knee;
  for (var i = 0; i < n; i++) {
    var x = src.getInt16(i * 2, Endian.little) / 32768.0 * gain;
    final a = x.abs();
    if (a > knee) {
      final y = knee + room * _tanh((a - knee) / room);
      x = x.isNegative ? -y : y;
    }
    dst.setInt16(i * 2, (x * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return out;
}

double _tanh(double x) {
  final e = exp(2 * x);
  return (e - 1) / (e + 1);
}

/// PCM16 mono data of a WAV file: (sample rate, data offset, data length),
/// or null when it is not a PCM16 mono WAV.
(int, int, int)? _pcmWavLayout(Uint8List bytes) {
  if (bytes.length < 44) return null;
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  final bd = ByteData.sublistView(bytes);
  var off = 12;
  int? rate;
  while (off + 8 <= bytes.length) {
    final id = tag(off);
    final len = bd.getUint32(off + 4, Endian.little);
    final body = off + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      final format = bd.getUint16(body, Endian.little);
      final channels = bd.getUint16(body + 2, Endian.little);
      final bits = bd.getUint16(body + 14, Endian.little);
      if (format != 1 || channels != 1 || bits != 16) return null;
      rate = bd.getUint32(body + 4, Endian.little);
    } else if (id == 'data') {
      if (rate == null) return null;
      return (rate, body, min(len, bytes.length - body) & ~1);
    }
    off = body + len + (len & 1);
  }
  return null;
}

/// A louder copy of the WAV clip at [path] for playback (quiet microphone
/// recordings are boosted, loud ones are left alone), cached in
/// [cacheDir] (default: the system temp dir). Returns [path] itself when
/// no boost is needed or the file is not a PCM16 mono WAV.
Future<String> loudPlaybackPath(String path, {String? cacheDir}) async {
  try {
    final f = File(path);
    final stat = await f.stat();
    final dir = cacheDir ?? p.join(Directory.systemTemp.path, 'woi-play');
    final out = p.join(dir, '${p.basenameWithoutExtension(path)}-${stat.size}-${stat.modified.millisecondsSinceEpoch}.wav');
    if (await File(out).exists()) return out;
    final bytes = await f.readAsBytes();
    final layout = _pcmWavLayout(bytes);
    if (layout == null) return path;
    final (rate, start, len) = layout;
    final pcm = Uint8List.sublistView(bytes, start, start + len);
    final gain = speechGain(pcm, sampleRate: rate);
    if (gain < 1.15) return path;
    final loud = applyGain(pcm, gain);
    await Directory(dir).create(recursive: true);
    final tmp = File('$out.part');
    await tmp.writeAsBytes(encodeWav(loud, sampleRate: rate), flush: true);
    await tmp.rename(out);
    return out;
  } catch (_) {
    return path;
  }
}
