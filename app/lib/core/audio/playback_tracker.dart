import '../voice/voice_backend.dart';

/// Models what the user has actually *heard* of streamed assistant audio.
///
/// The realtime server generates audio 3–10x faster than real time, so on a
/// barge-in only the client knows how much was played; that is the
/// `audio_end_ms` for `conversation.item.truncate` (REALTIME_API.md §2.6).
/// Every chunk handed to the player is appended to a virtual queue that
/// drains at real time, starting [outputLatency] after the first write.
class PlaybackTracker {
  PlaybackTracker({this.outputLatency = const Duration(milliseconds: 80), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Duration outputLatency;
  final DateTime Function() _now;
  final List<_Segment> _segments = [];
  final Map<String, int> _receivedMs = {};
  final List<String> _order = [];
  DateTime? _endAt;
  DateTime? _pausedAt;

  /// Local playback paused (a barge-in onset): the played position stops
  /// advancing until [resume] (or [reset] when it is cut).
  void pause() => _pausedAt ??= _now();

  /// Playback continues from where [pause] stopped it.
  void resume() {
    final p = _pausedAt;
    if (p == null) return;
    _pausedAt = null;
    final d = _now().difference(p);
    for (final s in _segments) {
      s.start = s.start.add(d);
    }
    final e = _endAt;
    if (e != null) _endAt = e.add(d);
  }

  DateTime _clock() => _pausedAt ?? _now();

  /// Records [bytes] of PCM16 24 kHz audio for [itemId] written to the player now.
  void onAudio(String itemId, int bytes) {
    if (bytes <= 0) return;
    final now = _clock();
    var start = _endAt;
    if (start == null || start.isBefore(now)) start = now.add(outputLatency);
    final durUs = bytes * 1000000 ~/ kVoiceBytesPerSecond;
    _segments.add(_Segment(itemId, start, durUs));
    _endAt = start.add(Duration(microseconds: durUs));
    if (!_receivedMs.containsKey(itemId)) _order.add(itemId);
    _receivedMs[itemId] = (_receivedMs[itemId] ?? 0) + durUs ~/ 1000;
    // Keep memory bounded: forget items that finished playing long ago.
    while (_order.length > 8) {
      final old = _order.removeAt(0);
      _receivedMs.remove(old);
      _segments.removeWhere((s) => s.itemId == old);
    }
  }

  bool get isPlaying {
    final e = _endAt;
    return e != null && (_pausedAt != null || _now().isBefore(e));
  }

  /// Milliseconds of [itemId] heard so far.
  int playedMs(String itemId) {
    final now = _clock();
    var us = 0;
    for (final s in _segments) {
      if (s.itemId != itemId) continue;
      final el = now.difference(s.start).inMicroseconds;
      if (el <= 0) continue;
      us += el > s.durUs ? s.durUs : el;
    }
    return us ~/ 1000;
  }

  int receivedMs(String itemId) => _receivedMs[itemId] ?? 0;

  /// Items whose audio was not fully heard, with the played length, in the
  /// order they were received. Call at the moment local playback stops.
  List<({String itemId, int playedMs, int receivedMs})> unheard() => [
    for (final id in _order)
      if (playedMs(id) case final played when played < receivedMs(id) - 5)
        (itemId: id, playedMs: played, receivedMs: receivedMs(id)),
  ];

  /// Local playback was stopped: everything queued is dropped.
  void reset() {
    _segments.clear();
    _receivedMs.clear();
    _order.clear();
    _endAt = null;
    _pausedAt = null;
  }
}

class _Segment {
  _Segment(this.itemId, this.start, this.durUs);
  final String itemId;
  DateTime start;
  final int durUs;
}
