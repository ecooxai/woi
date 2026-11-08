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

  /// Mutes / unmutes the outgoing mic track (push-to-talk, mute). May be
  /// called before [createOffer]: the track is then created in that state.
  void setMicEnabled(bool enabled);

  /// Releases native microphone capture immediately for an exclusive held
  /// recording. Completes only after in-flight capture opens are stopped.
  /// May be set before [createOffer]; a suspended offer must not open a mic.
  /// Resuming restores capture only when the microphone is enabled.
  Future<void> setCaptureSuspended(bool suspended);

  /// Mutes / unmutes playback of the assistant's remote audio track
  /// (local barge-in flush and the stop button). May be called before
  /// [createOffer], like [setMicEnabled].
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
    this.androidAudioRoute = 'phone',
    this.noiseSuppression = true,
    this.autoGainControl = true,
  });

  /// Case-insensitive substring of the input device label (null = default).
  final String? inputDeviceMatch;

  /// Case-insensitive substring of the output device label (null = default).
  final String? outputDeviceMatch;
  final bool echoCancellation;

  /// Android's saved output route. Media keeps MODE_NORMAL and media volume;
  /// phone uses MODE_IN_COMMUNICATION and voice-call volume.
  final String androidAudioRoute;
  final bool noiseSuppression;
  final bool autoGainControl;
}

typedef LiveRtcTransportFactory = LiveRtcTransport Function();

/// Native Android's parser only reads mandatory/optional key-value lists.
/// Keep browser-style properties too for other native/browser implementations.
Map<String, Object> liveAudioConstraints(
  LiveRtcOptions options, {
  required bool android,
  required bool externalEchoCapture,
  String? deviceId,
}) {
  final aec = !externalEchoCapture && options.echoCancellation;
  return {
    'echoCancellation': aec,
    'noiseSuppression': options.noiseSuppression,
    'autoGainControl': options.autoGainControl,
    if (deviceId != null || android)
      'optional': [
        if (deviceId != null) {'sourceId': deviceId},
        if (android) ...[
          {'googEchoCancellation': aec},
          {'echoCancellation': aec},
          {'googNoiseSuppression': options.noiseSuppression},
          {'googAutoGainControl': options.autoGainControl},
        ],
      ],
  };
}
