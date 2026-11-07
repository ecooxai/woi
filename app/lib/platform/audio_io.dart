import 'package:flutter/foundation.dart';

/// Microphone capture: PCM16, 24 kHz, mono.
abstract class MicStream {
  /// Raw audio chunks (even byte length, typically 10–40 ms each).
  Stream<Uint8List> get chunks;

  /// Smoothed input level 0..1 for meters.
  ValueListenable<double> get level;

  Future<void> close();
}

/// Native capture ownership was not confirmed released. A new microphone
/// must not be opened until cleanup succeeds or the voice session restarts.
class AudioCaptureReleaseFailure implements Exception {
  AudioCaptureReleaseFailure(this.cause);
  final Object cause;

  @override
  String toString() => 'Audio capture release was not confirmed: $cause';
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

/// Optional [AudioIO] capability: the microphone before echo cancellation,
/// for the stop-word spotter (an AEC in double talk eats the onset of a
/// short word, e.g. the "s" of "stop"; Woi's own words are vetoed against
/// the reference instead).
abstract class RawMicCapable {
  /// A capture of the same source without the canceller; null when the
  /// normal mic is not echo-cancelled (it is raw already).
  Future<MicStream?> openRawMic();
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

/// A leased, already echo-cancelled input for transports which own capture
/// themselves (WebRTC). Keep the lease until their native track is stopped.
class EchoCaptureLease {
  EchoCaptureLease({
    required this.deviceName,
    required this.deviceLabel,
    required Future<void> Function() release,
    // Keep the public named argument while hiding the callback itself.
    // ignore: prefer_initializing_formals
  }) : _release = release;

  final String deviceName;
  final String deviceLabel;
  final Future<void> Function() _release;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

/// Optional platform capture source shared by PCM and WebRTC consumers.
abstract interface class ExternalEchoCapture {
  Future<EchoCaptureLease?> acquireEchoCapture();
}

/// Explicit recording of microphone and system output. Normal listening
/// stays on the echo-cancelled microphone; only a held recording uses this.
abstract interface class MicSystemCapture {
  Future<MicStream> openMicAndSystemAudio();
}
