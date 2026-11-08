import '../../platform/audio_io.dart';
import 'backend_factory.dart';
import 'live_rtc_flutter.dart';
import 'live_rtc_transport.dart';
import 'live_webrtc_backend.dart';

/// Registers the gpt-live (WebRTC) backend with the factory's [GptLiveHook].
/// Linux leases the platform system-wide AEC source before WebRTC opens
/// capture. Other platforms retain their native WebRTC processing.
void registerGptLive() {
  GptLiveHook.register(
    (ctx) => LiveWebRtcBackend(
      transportFactory: () => FlutterLiveRtcTransport(
        options: LiveRtcOptions(
          echoCancellation: ctx.settings.echoCancellation,
          androidAudioRoute: ctx.settings.androidAudioRoute.name,
        ),
        captureDeviceProvider:
            ctx.settings.echoCancellation && ctx.audio is ExternalEchoCapture
            ? (ctx.audio! as ExternalEchoCapture).acquireEchoCapture
            : null,
      ),
      credentialsProvider: ctx.credentials,
    ),
  );
}
