import 'backend_factory.dart';
import 'live_rtc_flutter.dart';
import 'live_rtc_transport.dart';
import 'live_webrtc_backend.dart';

/// Registers the gpt-live (WebRTC) backend with the factory's [GptLiveHook].
/// libwebrtc uses the default PulseAudio/PipeWire input and output with its
/// echo canceller (plus NS/AGC) on, unless the Echo cancellation setting is
/// off.
void registerGptLive() {
  GptLiveHook.register(
    (ctx) => LiveWebRtcBackend(
      transportFactory: () =>
          FlutterLiveRtcTransport(options: LiveRtcOptions(echoCancellation: ctx.settings.echoCancellation)),
      credentialsProvider: ctx.credentials,
    ),
  );
}
