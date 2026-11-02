import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../voice/voice_backend.dart';

/// Wraps raw PCM16 mono in a RIFF/WAVE container.
Uint8List encodeWav(Uint8List pcm16, {int sampleRate = kVoiceSampleRate}) {
  final dataLen = pcm16.length;
  final b = ByteData(44);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  final out = Uint8List(44 + dataLen);
  out.setRange(0, 44, b.buffer.asUint8List());
  out.setRange(44, 44 + dataLen, pcm16);
  return out;
}

Future<void> writeWav(String path, Uint8List pcm16,
    {int sampleRate = kVoiceSampleRate}) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(encodeWav(pcm16, sampleRate: sampleRate), flush: true);
}

int pcmDurationMs(int byteCount, {int sampleRate = kVoiceSampleRate}) =>
    (byteCount * 1000) ~/ (sampleRate * 2);

/// RMS level of a PCM16 chunk, normalised to 0..1.
double pcm16Rms(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) return 0;
  final bd = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
    sum += s * s;
  }
  return sqrt(sum / n);
}

/// Maps RMS to a perceptual 0..1 meter value (roughly -60 dB .. 0 dB).
double rmsToMeter(double rms) {
  if (rms <= 1e-6) return 0;
  final db = 20 * log(rms) / ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

/// Growable byte buffer for accumulating PCM.
class PcmBuffer {
  final BytesBuilder _b = BytesBuilder(copy: false);
  int get length => _b.length;
  bool get isEmpty => _b.isEmpty;
  void add(Uint8List chunk) => _b.add(chunk);
  Uint8List takeBytes() => _b.takeBytes();
  void clear() => _b.clear();
}

/// Fixed-duration ring of recent PCM chunks (pre-roll before VAD fires).
class PcmRing {
  PcmRing(this.maxBytes);
  final int maxBytes;
  final List<Uint8List> _chunks = [];
  int _len = 0;

  void add(Uint8List c) {
    _chunks.add(c);
    _len += c.length;
    while (_len > maxBytes && _chunks.length > 1) {
      _len -= _chunks.removeAt(0).length;
    }
  }

  Uint8List drain() {
    final b = BytesBuilder(copy: false);
    for (final c in _chunks) {
      b.add(c);
    }
    _chunks.clear();
    _len = 0;
    return b.takeBytes();
  }
}
