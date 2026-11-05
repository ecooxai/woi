import 'dart:math';
import 'dart:typed_data';

import '../voice/voice_backend.dart';

/// Mic audio captured while the voice session is still connecting (launch,
/// assistant activation, auto-reconnect). Flushed in order once the session
/// is ready, so the user's first words are not lost to the handshake.
///
/// Bounded ([capBytes], oldest dropped). [take] trims only a long run of
/// leading *digital* silence (exact zeros, e.g. a recorder still starting;
/// beyond [maxLeadSilenceBytes]) down to [keepBeforeVoiceBytes]. Anything
/// with signal is kept: a level gate mislabelled quiet call-mode speech as
/// silence and cut it (on a MI 8 every flush came out as 300 ms).
class PreConnectBuffer {
  PreConnectBuffer({
    this.capBytes = kPreConnectCapBytes,
    this.maxLeadSilenceBytes = kVoiceBytesPerSecond,
    this.keepBeforeVoiceBytes = kVoiceBytesPerSecond * 3 ~/ 10,
  });

  /// ~40 s of PCM16 24 kHz mono: a cold assist start holds up to 15 s
  /// natively and the handshake itself took ~10 s on a phone; a 15 s cap
  /// dropped the first words.
  static const int kPreConnectCapBytes = kVoiceBytesPerSecond * 40;

  /// A chunk is voiced at >= floor + 10 dB and at least -50 dBFS.
  static const double minVoiceRms = 0.003;

  final int capBytes;
  final int maxLeadSilenceBytes;
  final int keepBeforeVoiceBytes;

  final List<Uint8List> _chunks = [];
  final List<bool> _voiced = [];
  final List<bool> _zero = [];
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
    if (r > _maxRms) _maxRms = r;
    _chunks.add(chunk);
    _voiced.add(voiced);
    _zero.add(isDigitalSilence(chunk));
    _bytes += chunk.length;
    while (_bytes > capBytes && _chunks.length > 1) {
      _bytes -= _chunks.removeAt(0).length;
      _voiced.removeAt(0);
      _zero.removeAt(0);
      dropped++;
    }
    return voiced;
  }

  double _maxRms = 0;

  void clear() {
    _chunks.clear();
    _voiced.clear();
    _zero.clear();
    _bytes = 0;
    _maxRms = 0;
  }

  /// One line about the buffered audio (diagnostics; call before [take]).
  String describe() {
    final first = _voiced.indexOf(true);
    var firstMs = -1;
    if (first >= 0) {
      var b = 0;
      for (var i = 0; i < first; i++) {
        b += _chunks[i].length;
      }
      firstMs = b * 1000 ~/ kVoiceBytesPerSecond;
    }
    return '${_bytes * 1000 ~/ kVoiceBytesPerSecond} ms in ${_chunks.length} chunks, '
        'voiced ${_voiced.where((v) => v).length}, first voiced at $firstMs ms, '
        'zero ${_zero.where((z) => z).length}, max rms ${_maxRms.toStringAsFixed(4)}, '
        'floor ${_floor.toStringAsFixed(4)}, dropped $dropped';
  }

  /// The buffered audio (leading digital silence trimmed), in order, as
  /// frames of at most [frameBytes]; empties the buffer.
  ///
  /// Also sets [takenFirstVoicedBytes] and [takenFirstPauseBytes] (offsets
  /// into the returned audio).
  List<Uint8List> take({int frameBytes = kVoiceBytesPerSecond * 2 ~/ 10, int pauseBytes = kDefaultPauseBytes}) {
    var first = _zero.indexOf(false);
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
    var start = 0;
    if (lead > maxLeadSilenceBytes) {
      start = (lead - keepBeforeVoiceBytes) & ~1;
      bytes = Uint8List.sublistView(bytes, start);
    }
    _segment(start, pauseBytes);
    clear();
    final out = <Uint8List>[];
    for (var o = 0; o < bytes.length; o += frameBytes) {
      out.add(Uint8List.fromList(Uint8List.sublistView(bytes, o, min(o + frameBytes, bytes.length))));
    }
    return out;
  }

  /// A run of unvoiced audio this long ends an utterance: longer than the
  /// server VAD's 500 ms silence, so its first turn is over by then.
  static const int kDefaultPauseBytes = kVoiceBytesPerSecond * 7 ~/ 10;

  /// Of the last [take]: where the first voiced chunk starts, or null.
  int? takenFirstVoicedBytes;

  /// Of the last [take]: where the first utterance is followed by
  /// [kDefaultPauseBytes] of unvoiced audio (the end of that pause), or null
  /// when speech runs to the end of the buffer.
  int? takenFirstPauseBytes;

  void _segment(int start, int pauseBytes) {
    takenFirstVoicedBytes = null;
    takenFirstPauseBytes = null;
    var off = -start;
    var quiet = 0;
    for (var i = 0; i < _chunks.length; i++) {
      final len = _chunks[i].length;
      if (_voiced[i]) {
        takenFirstVoicedBytes ??= max(0, off);
        quiet = 0;
      } else if (takenFirstVoicedBytes != null) {
        quiet += len;
        if (quiet >= pauseBytes) {
          takenFirstPauseBytes = off + len;
          return;
        }
      }
      off += len;
    }
  }

  /// Every sample within ±1 LSB of zero: no microphone signal at all.
  static bool isDigitalSilence(Uint8List pcm16) {
    final bd = ByteData.sublistView(pcm16);
    for (var i = 0; i + 1 < pcm16.length; i += 2) {
      final v = bd.getInt16(i, Endian.little);
      if (v > 1 || v < -1) return false;
    }
    return true;
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
