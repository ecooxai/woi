import 'package:flutter/foundation.dart';

/// Microphone capture: PCM16, 24 kHz, mono.
abstract class MicStream {
  /// Raw audio chunks (even byte length, typically 10–40 ms each).
  Stream<Uint8List> get chunks;

  /// Smoothed input level 0..1 for meters.
  ValueListenable<double> get level;

  Future<void> close();
}

/// Streaming PCM16 24 kHz mono output with instant stop (barge-in).
abstract class PcmPlayer {
  void write(Uint8List pcm16);

  /// Drops everything queued and silences output immediately.
  Future<void> stop();

  /// True while queued audio is still being heard.
  bool get isPlaying;

  /// Output level 0..1, aligned with what is currently audible.
  ValueListenable<double> get level;

  Future<void> close();
}

/// Playback of an audio file (wav, ogg, …).
abstract class ClipPlayback {
  Future<void> get done;
  Future<void> stop();
}

abstract class AudioIO {
  Future<MicStream> openMic();
  Future<PcmPlayer> openPlayer();
  Future<ClipPlayback> playFile(String path);

  /// Human-readable description of the backend in use (for diagnostics).
  String get description;
}

/// Optional [AudioIO] capability: removing what the speakers play from the
/// microphone. A change applies to mics opened afterwards.
abstract class EchoCancellable {
  bool get echoCancellation;
  set echoCancellation(bool on);

  /// Human-readable state ("active ...", "off", "unavailable: ...").
  String get echoCancellationStatus;

  /// Releases the canceller (app exit).
  Future<void> disposeEchoCancellation();
}

/// Optional [AudioIO] capability (Android): the system audio route and a mic
/// that steps aside while another app records.
abstract class AudioRouted {
  /// 'phone' (call path, default) or 'media'. Applies to mics opened
  /// afterwards.
  set audioRoute(String route);

  /// Non-null while the mic is paused for another app (status-row text).
  ValueListenable<String?> get micPaused;
}
