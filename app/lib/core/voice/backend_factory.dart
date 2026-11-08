import '../../platform/audio_io.dart';
import '../auth/auth.dart';
import '../settings/settings.dart';
import 'realtime_ws_backend.dart';
import 'voice_backend.dart';

/// What a backend builder gets from the app.
class BackendContext {
  const BackendContext({required this.settings, required this.credentials, this.audio, this.textReasoningEffort});

  final AudioIO? audio;

  final AppSettings settings;

  /// Read at each text task so editing thinking does not restart voice.
  final String Function()? textReasoningEffort;

  /// Fresh credentials for the mode's auth (Codex token refreshed when
  /// close to expiry, or the API key). Call on every (re)connect.
  final Future<Credentials?> Function() credentials;
}

typedef VoiceBackendBuilder = VoiceBackend Function(BackendContext ctx);

/// Registration point for the gpt-live (WebRTC) backend.
///
/// TODO(gpt-live): the WebRTC backend (lib/core/voice/live_*.dart) registers
/// itself here at startup, e.g. `GptLiveHook.register((ctx) => LiveWebRtcBackend(...))`,
/// and the call is added to `AppController.init` / `main`. Until then the
/// factory falls back to [RealtimeWsBackend] with a visible notice.
/// The builder should use `ctx.settings.voiceModel` and `ctx.credentials()`;
/// `Credentials.headers(live: true)` adds `openai-alpha: quicksilver=v2`.
class GptLiveHook {
  GptLiveHook._();
  static VoiceBackendBuilder? _builder;

  static void register(VoiceBackendBuilder builder) => _builder = builder;
  static void unregister() => _builder = null;
  static bool get isRegistered => _builder != null;
  static VoiceBackendBuilder? get builder => _builder;
}

class BackendSelection {
  const BackendSelection({required this.backend, required this.mode, required this.model, this.notice});

  final VoiceBackend backend;

  /// Mode actually in use (differs from the setting on fallback).
  final BackendMode mode;

  /// Model to put in the [SessionConfig].
  final String model;

  /// User-visible notice (e.g. fallback explanation), or null.
  final String? notice;
}

/// Builds the voice backend for [BackendContext.settings].
BackendSelection createVoiceBackend(BackendContext ctx, {VoiceBackend Function(BackendContext ctx)? realtimeBuilder}) {
  final s = ctx.settings;
  VoiceBackend realtime() =>
      realtimeBuilder?.call(ctx) ??
      RealtimeWsBackend(credentialsProvider: ctx.credentials, vadSilenceMs: s.replyDelayMs);
  switch (s.backendMode) {
    case BackendMode.gptLive:
      final live = GptLiveHook.builder;
      if (live != null) {
        return BackendSelection(backend: live(ctx), mode: BackendMode.gptLive, model: s.voiceModel);
      }
      return BackendSelection(
        backend: realtime(),
        mode: BackendMode.direct,
        model: s.realtimeModel,
        notice:
            'gpt-live (WebRTC) is not available in this build yet; '
            'using Direct realtime (${s.realtimeModel}) instead.',
      );
    case BackendMode.direct:
    case BackendMode.apiKey:
      return BackendSelection(backend: realtime(), mode: s.backendMode, model: s.realtimeModel);
  }
}
