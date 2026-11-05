import 'dart:math';
import 'dart:typed_data';

import '../voice/voice_backend.dart';

/// Mic audio captured while the voice session is still connecting (launch,
/// assistant activation, auto-reconnect). Flushed in order once the session
/// is ready, so the user's first words are not lost to the handshake.
///
/// Bounded ([capBytes], oldest dropped). [take] trims a long leading silence
/// (beyond [maxLeadSilenceBytes]) down to [keepBeforeVoiceBytes] before the
/// first voiced chunk, judged by a simple level gate against the noise floor.
class PreConnectBuffer {
  PreConnectBuffer({
    this.capBytes = kPreConnectCapBytes,
    this.maxLeadSilenceBytes = kVoiceBytesPerSecond,
    this.keepBeforeVoiceBytes = kVoiceBytesPerSecond * 3 ~/ 10,
  });

  /// ~15 s of PCM16 24 kHz mono.
  static const int kPreConnectCapBytes = kVoiceBytesPerSecond * 15;

  /// A chunk is voiced at >= floor + 10 dB and at least -50 dBFS.
  static const double minVoiceRms = 0.003;

  final int capBytes;
  final int maxLeadSilenceBytes;
  final int keepBeforeVoiceBytes;

  final List<Uint8List> _chunks = [];
  final List<bool> _voiced = [];
  int _bytes = 0;
  double _floor = 0;

  /// Chunks dropped by the cap (tests/diagnostics).
  int dropped = 0;

  int get bytes => _bytes;
  bool get isEmpty => _chunks.isEmpty;

  /// Whether any buffered chunk is voiced.
  bool get hasVoice => _voiced.contains(true);

  /// Adds [chunk]; returns whether it is voiced.
  bool add(Uint8List chunk) {
    if (chunk.isEmpty) return false;
    final r = rms(chunk);
    final voiced = r >= max(minVoiceRms, _floor * 3.16);
    if (!voiced) _floor = _floor == 0 || r < _floor ? r : _floor * 0.98 + r * 0.02;
    _chunks.add(chunk);
    _voiced.add(voiced);
    _bytes += chunk.length;
    while (_bytes > capBytes && _chunks.length > 1) {
      _bytes -= _chunks.removeAt(0).length;
      _voiced.removeAt(0);
      dropped++;
    }
    return voiced;
  }

  void clear() {
    _chunks.clear();
    _voiced.clear();
    _bytes = 0;
  }

  /// The buffered audio (leading silence trimmed), in order, as frames of at
  /// most [frameBytes]; empties the buffer.
  List<Uint8List> take({int frameBytes = kVoiceBytesPerSecond * 2 ~/ 10}) {
    var first = _voiced.indexOf(true);
    if (first < 0) first = _chunks.length;
    var lead = 0;
    for (var i = 0; i < first; i++) {
      lead += _chunks[i].length;
    }
    final all = BytesBuilder(copy: false);
    for (final c in _chunks) {
      all.add(c);
    }
    var bytes = all.takeBytes();
    if (lead > maxLeadSilenceBytes) {
      final start = (lead - keepBeforeVoiceBytes) & ~1;
      bytes = Uint8List.sublistView(bytes, start);
    }
    clear();
    final out = <Uint8List>[];
    for (var o = 0; o < bytes.length; o += frameBytes) {
      out.add(Uint8List.fromList(Uint8List.sublistView(bytes, o, min(o + frameBytes, bytes.length))));
    }
    return out;
  }

  static double rms(Uint8List pcm16) {
    final n = pcm16.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(pcm16);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little);
      sum += v * v;
    }
    return sqrt(sum / n) / 32768;
  }
}
