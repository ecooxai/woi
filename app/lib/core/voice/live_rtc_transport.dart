/// Media transport for the gpt-live backend (research/REALTIME_API.md §3).
///
/// gpt-live only accepts microphone audio over RTP, so the backend needs a
/// real WebRTC peer connection. This interface keeps the backend testable
/// without the native plugin: unit tests use a fake, the app uses
/// `FlutterLiveRtcTransport` (live_rtc_flutter.dart), which lets libwebrtc
/// own the microphone and speaker (and so gives echo cancellation for free).
abstract class LiveRtcTransport {
  /// Creates the peer connection (iceServers=[]), the sendrecv mic track and
  /// the `oai-events` data channel; returns the offer SDP once ICE gathering
  /// is complete (host candidates only: ~20–50 ms).
  Future<String> createOffer();

  /// Applies the SDP answer returned by call creation.
  Future<void> setAnswer(String sdp);

  /// Mutes / unmutes the outgoing mic track (push-to-talk, mute).
  void setMicEnabled(bool enabled);

  /// Mutes / unmutes playback of the assistant's remote audio track
  /// (local barge-in flush and the stop button).
  void setSpeakerEnabled(bool enabled);

  /// Peer connection state names (`connected`, `failed`, `closed`, ...).
  Stream<String> get connectionStates;

  /// Short description for diagnostics (devices in use).
  String get description;

  Future<void> close();
}

/// Device and processing options for a WebRTC transport.
class LiveRtcOptions {
  const LiveRtcOptions({
    this.inputDeviceMatch,
    this.outputDeviceMatch,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
  });

  /// Case-insensitive substring of the input device label (null = default).
  final String? inputDeviceMatch;

  /// Case-insensitive substring of the output device label (null = default).
  final String? outputDeviceMatch;
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;
}

typedef LiveRtcTransportFactory = LiveRtcTransport Function();
