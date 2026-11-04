import 'dart:math';
import 'dart:typed_data';

import '../voice/voice_backend.dart' show kVoiceBytesPerSecond;
import '../audio/wav.dart';

/// Local mic-onset detector for barge-in while the assistant is speaking.
///
/// Runs on the raw mic in both modes, so playback can be cut within a few
/// hundred ms instead of waiting for the server to notice the user. It is an
/// energy detector made robust against our own speaker output leaking into
/// the mic: it learns the echo gain (mic level ÷ playback level) while the
/// assistant talks and nobody else does, and while audio plays only fires on
/// mic energy well above the echo that the current playback level predicts.
class BargeInDetector {
  BargeInDetector({
    this.onsetMs = 80,
    this.minThreshold = 0.02,
    this.noiseMultiplier = 3.5,
    this.echoMargin = 2.5,
    this.warmupMs = 300,
    this.maxGapMs = 60,
  });

  /// Voiced time needed to fire (gaps up to [maxGapMs] are bridged, so the
  /// closure of a stop consonant, the "t" in "stop", does not restart it).
  final int onsetMs;

  /// Lowest mic level that counts as the user (settable: a platform echo
  /// canceller leaves short residual bursts, so phones use a higher floor).
  double minThreshold;
  final double noiseMultiplier;

  /// Mic energy must exceed predicted echo by this factor.
  final double echoMargin;

  /// Playback time used only for learning the echo gain before the first
  /// detection is allowed.
  final int warmupMs;
  final int maxGapMs;

  static const _frameMs = 10;
  static const _frameBytes = kVoiceBytesPerSecond * _frameMs ~/ 1000;

  double _noiseFloor = 0.003;
  double _echoGain = 0;
  int _learnedMs = 0;
  double _refRms = 0;
  int _refAgeMs = 1 << 30;
  int _voicedMs = 0;
  int _gapMs = 0;
  bool _fired = false;
  final _carry = BytesBuilder(copy: false);

  /// Learned ratio of mic echo to playback level (diagnostics).
  double get echoGain => _echoGain;
  double get noiseFloor => _noiseFloor;

  /// Threshold for a mic frame while [refRms] is playing.
  double thresholdFor(double refRms) =>
      max(max(minThreshold, _noiseFloor * noiseMultiplier), _echoGain * refRms * echoMargin);

  /// Assistant audio that is about to be heard (feeds the echo model).
  void onPlayback(Uint8List pcm16) {
    if (pcm16.isEmpty) return;
    final r = pcm16Rms(pcm16);
    // Conservative: follow peaks quickly, decay slowly.
    _refRms = r > _refRms ? r : _refRms * 0.85 + r * 0.15;
    _refAgeMs = 0;
  }

  /// Re-arms after a detection (call when the assistant starts a new reply).
  void rearm() {
    _fired = false;
    _voicedMs = 0;
    _gapMs = 0;
  }

  /// Feeds mic audio. [audible] is whether assistant audio is playing now.
  /// Returns true once per onset while audible.
  bool process(Uint8List pcm16, {required bool audible}) {
    _carry.add(pcm16);
    final all = _carry.takeBytes();
    var off = 0;
    var hit = false;
    while (off + _frameBytes <= all.length) {
      if (_frame(Uint8List.sublistView(all, off, off + _frameBytes), audible)) hit = true;
      off += _frameBytes;
    }
    if (off < all.length) _carry.add(Uint8List.fromList(all.sublist(off)));
    return hit;
  }

  bool _frame(Uint8List f, bool audible) {
    final rms = pcm16Rms(f);
    _refAgeMs += _frameMs;
    if (!audible) {
      // Replies are generated faster than they play, so the reference only
      // decays once playback is over.
      if (_refAgeMs > 600) _refRms *= 0.9;
      // Between replies: track the room noise, re-arm.
      _noiseFloor = rms < _noiseFloor * 4 || rms < minThreshold ? _noiseFloor * 0.97 + rms * 0.03 : _noiseFloor;
      _voicedMs = 0;
      _gapMs = 0;
      _fired = false;
      return false;
    }
    final ref = max(_refRms, 1e-4);
    final thr = thresholdFor(_refRms);
    final loud = rms >= thr;
    if (rms < thr * 0.5) {
      // Pure echo (+ noise): learn its gain. Peaks are followed quickly so the
      // threshold never sits below the loudest echo seen recently. Frames just
      // under the threshold are not learned: they are usually the rising edge
      // of the user's own speech, and learning them raised the threshold right
      // when the user started talking (barge-in fired 300-400 ms late).
      final ratio = min(rms / ref, 2.0);
      _echoGain = ratio > _echoGain ? _echoGain * 0.7 + ratio * 0.3 : _echoGain * 0.998 + ratio * 0.002;
      _learnedMs += _frameMs;
    }
    if (_learnedMs < warmupMs) {
      if (loud) {
        // Loud during warm-up: most likely echo the model has not learned yet.
        final ratio = min(rms / ref, 2.0);
        _echoGain = max(_echoGain, ratio * 0.8);
        _learnedMs += _frameMs;
      }
      return false;
    }
    if (_fired) return false;
    if (loud) {
      _voicedMs += _frameMs + _gapMs;
      _gapMs = 0;
    } else if (_voicedMs > 0) {
      _gapMs += _frameMs;
      if (_gapMs > maxGapMs) {
        _voicedMs = 0;
        _gapMs = 0;
      }
    }
    if (_voicedMs >= onsetMs) {
      _fired = true;
      _voicedMs = 0;
      return true;
    }
    return false;
  }
}

/// "Stop" / "cancel" / "never mind" (and close variants) as a whole utterance.
final _stopPhrase = RegExp(
  r"^(?:(?:ok(?:ay)?|hey|no|woi|please|um|uh)[\s,.!]+)*"
  r"(?:stop(?:\s+(?:it|that|talking|now|there|please))?|cancel(?:\s+(?:it|that|this|please))?|never\s*mind|"
  r"forget\s+it|be\s+quiet|quiet|shut\s+up|hush|enough|that'?s\s+enough|hold\s+on|wait)"
  r"(?:[\s,.!]+(?:please|thanks|thank\s+you|woi|now))*[\s.!?]*$",
  caseSensitive: false,
);

/// Whether [text] is just a request to stop / cancel.
bool isStopPhrase(String text) {
  final t = text.trim();
  return t.isNotEmpty && t.length <= 40 && _stopPhrase.hasMatch(t);
}

const _stopWords = {
  'ok',
  'okay',
  'hey',
  'no',
  'woi',
  'please',
  'um',
  'uh',
  'stop',
  'it',
  'that',
  'this',
  'talking',
  'now',
  'there',
  'cancel',
  'never',
  'mind',
  'nevermind',
  'forget',
  'be',
  'quiet',
  'shut',
  'up',
  'hush',
  'enough',
  "that's",
  'thats',
  'hold',
  'on',
  'wait',
  'thanks',
  'thank',
  'you',
};

/// Whether a partial transcript may still turn out to be a stop phrase.
bool couldBecomeStopPhrase(String text) {
  final words = text.toLowerCase().split(RegExp(r"[^a-z']+")).where((w) => w.isNotEmpty).toList();
  return words.length <= 6 && words.every(_stopWords.contains);
}
