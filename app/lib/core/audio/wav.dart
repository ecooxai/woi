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

/// Reads the PCM payload of an archived recording without sending the RIFF
/// header as audio. The Realtime input format is PCM16 mono at 24 kHz.
/// Walk all RIFF chunks (including padded unknown chunks); reject truncated
/// or incompatible files instead of playing/sending incorrectly decoded data.
Uint8List decodePcm16Wav(Uint8List bytes, {int sampleRate = kVoiceSampleRate}) {
  Never invalid(String detail) => throw FormatException('Unsupported recording: $detail');
  if (bytes.length < 12) invalid('incomplete WAV header');
  String tag(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') invalid('expected RIFF/WAVE');
  final data = ByteData.sublistView(bytes);
  final end = data.getUint32(4, Endian.little) + 8;
  if (end < 12 || end > bytes.length) invalid('truncated RIFF data');
  var formatOk = false;
  int? pcmStart;
  var pcmLength = 0;
  var offset = 12;
  while (offset + 8 <= end) {
    final chunk = tag(offset);
    final length = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (body + length > end) invalid('truncated $chunk chunk');
    if (chunk == 'fmt ') {
      if (length < 16 ||
          data.getUint16(body, Endian.little) != 1 ||
          data.getUint16(body + 2, Endian.little) != 1 ||
          data.getUint32(body + 4, Endian.little) != sampleRate ||
          data.getUint32(body + 8, Endian.little) != sampleRate * 2 ||
          data.getUint16(body + 12, Endian.little) != 2 ||
          data.getUint16(body + 14, Endian.little) != 16) {
        invalid('expected PCM16 mono at $sampleRate Hz');
      }
      formatOk = true;
    } else if (chunk == 'data') {
      if (pcmStart != null || length == 0 || length.isOdd) invalid('invalid PCM data length');
      pcmStart = body;
      pcmLength = length;
    }
    offset = body + length + (length & 1);
    if (offset > end) invalid('missing chunk padding');
  }
  if (offset != end || !formatOk || pcmStart == null) invalid('missing or incomplete WAV chunks');
  return Uint8List.sublistView(bytes, pcmStart, pcmStart + pcmLength);
}

Future<void> writeWav(String path, Uint8List pcm16, {int sampleRate = kVoiceSampleRate}) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(encodeWav(pcm16, sampleRate: sampleRate), flush: true);
}

int pcmDurationMs(int byteCount, {int sampleRate = kVoiceSampleRate}) => (byteCount * 1000) ~/ (sampleRate * 2);

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
