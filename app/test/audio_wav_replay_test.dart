import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/wav.dart';

void main() {
  final pcm = Uint8List.fromList([1, 0, 255, 127, 0, 128, 12, 0]);

  test('WAV replay sends only exact PCM16 payload without a RIFF header', () {
    final wav = encodeWav(pcm);
    expect(decodePcm16Wav(wav), orderedEquals(pcm));
    expect(wav.length, pcm.length + 44);
  });

  test('walks an unknown odd-sized RIFF chunk and its padding', () {
    final wav = encodeWav(pcm);
    final junk = Uint8List.fromList([74, 85, 78, 75, 3, 0, 0, 0, 10, 20, 30, 0]);
    final joined = Uint8List.fromList([...wav.sublist(0, 12), ...junk, ...wav.sublist(12)]);
    ByteData.sublistView(joined).setUint32(4, joined.length - 8, Endian.little);
    expect(decodePcm16Wav(joined), orderedEquals(pcm));
  });

  test('rejects wrong rate, stereo, non-PCM and non-16-bit recordings', () {
    for (final (offset, value) in [(22, 2), (20, 3), (34, 8)]) {
      final wav = encodeWav(pcm);
      ByteData.sublistView(wav).setUint16(offset, value, Endian.little);
      expect(() => decodePcm16Wav(wav), throwsFormatException);
    }
    expect(() => decodePcm16Wav(encodeWav(pcm, sampleRate: 16000)), throwsFormatException);
  });

  test('rejects malformed headers and truncated chunk bodies without reading past buffers', () {
    expect(() => decodePcm16Wav(Uint8List(3)), throwsFormatException);
    expect(() => decodePcm16Wav(Uint8List(44)), throwsFormatException);
    final truncated = encodeWav(pcm).sublist(0, 46);
    expect(() => decodePcm16Wav(truncated), throwsFormatException);
    final oversizedChunk = encodeWav(pcm);
    ByteData.sublistView(oversizedChunk).setUint32(40, 0x7fffffff, Endian.little);
    expect(() => decodePcm16Wav(oversizedChunk), throwsFormatException);
  });

  test('rejects empty or partial PCM samples', () {
    expect(() => decodePcm16Wav(encodeWav(Uint8List(0))), throwsFormatException);
    expect(() => decodePcm16Wav(encodeWav(Uint8List(3))), throwsFormatException);
  });
}
