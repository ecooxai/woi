import 'backend_factory.dart';
import 'live_rtc_flutter.dart';
import 'live_webrtc_backend.dart';

/// Registers the gpt-live (WebRTC) backend with the factory's [GptLiveHook].
/// libwebrtc uses the default PulseAudio/PipeWire input and output with
/// echo cancellation on.
void registerGptLive() {
  GptLiveHook.register(
    (ctx) => LiveWebRtcBackend(
      transportFactory: FlutterLiveRtcTransport.new,
      credentialsProvider: ctx.credentials,
    ),
  );
}
