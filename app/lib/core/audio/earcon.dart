import 'dart:math' as math;
import 'dart:typed_data';

import '../voice/voice_backend.dart';

Uint8List? _thinking;

/// Soft two-note "got it" chime (PCM16, 24 kHz mono, ~190 ms, about -22 dBFS)
/// played at the user's end of speech while the reply is on its way. It is
/// quiet and shorter than any VAD's minimum speech, so it does not trigger
/// barge-in.
Uint8List thinkingEarconPcm() => _thinking ??= _render(const [(587.33, 0, 90), (880.0, 70, 120)], peak: 0.08);

Uint8List? _attention;

/// Rising three-note cue played when an approval dialog needs the user
/// (PCM16, 24 kHz mono, ~330 ms, louder than the thinking chime).
Uint8List attentionEarconPcm() =>
    _attention ??= _render(const [(659.25, 0, 120), (880.0, 100, 120), (1174.66, 200, 130)], peak: 0.12);

Uint8List _render(List<(double hz, int startMs, int durMs)> notes, {required double peak}) {
  var endMs = 0;
  for (final n in notes) {
    endMs = math.max(endMs, n.$2 + n.$3);
  }
  final total = kVoiceSampleRate * endMs ~/ 1000;
  final mix = Float64List(total);
  for (final (hz, startMs, durMs) in notes) {
    final start = kVoiceSampleRate * startMs ~/ 1000;
    final len = kVoiceSampleRate * durMs ~/ 1000;
    final attack = kVoiceSampleRate * 8 ~/ 1000;
    for (var i = 0; i < len && start + i < total; i++) {
      // Short linear attack, exponential decay: a soft mallet, no clicks.
      final env = (i < attack ? i / attack : 1.0) * math.exp(-4.0 * i / len) * (1 - i / len);
      mix[start + i] += math.sin(2 * math.pi * hz * i / kVoiceSampleRate) * env;
    }
  }
  final out = ByteData(total * 2);
  for (var i = 0; i < total; i++) {
    out.setInt16(i * 2, (mix[i].clamp(-1.0, 1.0) * peak * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}
