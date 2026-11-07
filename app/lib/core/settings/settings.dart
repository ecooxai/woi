import 'dart:convert';
import 'dart:io';

import '../auth/auth.dart';

enum MicMode {
  handsFree('Hands-free'),
  pushToTalk('Push-to-talk'),
  muted('Muted');

  const MicMode(this.label);
  final String label;
}

/// Colour theme of the UI.
enum AppTheme {
  light('Light'),
  dark('Dark'),
  system('System');

  const AppTheme(this.label);
  final String label;
}

/// How Woi's own audio goes through Android's audio system.
enum AndroidAudioRoute {
  /// The call path: hardware/platform call echo cancellation, call volume,
  /// headset or loudspeaker.
  phone('Phone (echo cancellation)'),

  /// The media path: media volume, speech-recognition capture.
  media('Media');

  const AndroidAudioRoute(this.label);
  final String label;
}

/// Which voice backend the app talks to.
enum BackendMode {
  gptLive('gpt-live (WebRTC)'),
  direct('Direct realtime (gpt-realtime-2.1)'),
  apiKey('OpenAI API key');

  const BackendMode(this.label);
  final String label;

  /// Credentials this mode authenticates with.
  AuthMode get authMode => this == BackendMode.apiKey ? AuthMode.apiKey : AuthMode.codex;
}

/// Audio model family, separate from which credentials authenticate it.
/// It is derived from [BackendMode]; no additional persisted setting is needed.
enum AudioModelFamily { realtime, live }

/// gpt-live models (WebRTC path, research/REALTIME_API.md §3).
const kVoiceModels = ['gpt-live-1.1', 'gpt-live-1', 'gpt-live-1-codex'];

/// Models that work on wss://api.openai.com/v1/realtime (§2.1).
const kRealtimeModels = [
  'gpt-realtime-2.1',
  'gpt-realtime-2.1-mini',
  'gpt-realtime-2',
  'gpt-realtime-1.5',
  'gpt-realtime',
  'gpt-realtime-mini',
];

/// Voices of the realtime WebSocket models (direct and API-key modes).
const kVoices = ['marin', 'cedar', 'alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'];

/// v3 voices accepted by gpt-live (§3.1). Realtime voices (marin, alloy...)
/// are incompatible and rejected before opening its transport.
const kLiveVoices = [
  'cove',
  'juniper',
  'maple',
  'spruce',
  'ember',
  'vale',
  'breeze',
  'arbor',
  'sol',
  'aube',
  'bubbie',
  'haetsal', //
  'hanul',
  'himari',
  'leher',
  'miko',
  'neer',
  'porto',
  'rindo',
  'rio',
  'rivage',
  'selva',
  'sonna',
  'tinta',
  'viola',
];
const kLiveDefaultVoice = 'cove';

/// [AppSettings.editApplyDelay] value: edits wait for an explicit Apply.
const kRequireApproval = -1;

/// Default share of the window width taken by the chat pane (wide layout).
const kDefaultChatPaneFraction = 0.42;

/// Bounds of [AppSettings.chatPaneFraction].
const kChatPaneMinFraction = 0.25;
const kChatPaneMaxFraction = 0.6;

/// Choices for [AppSettings.editApplyDelay] (seconds).
const kEditApplyDelays = [0, 3, 5, 10, kRequireApproval];

/// [AppSettings.replyDelayMs] default and range.
const kDefaultReplyDelayMs = 2000;
const kMinReplyDelayMs = 300;
const kMaxReplyDelayMs = 5000;

/// [AppSettings.idleStandbySeconds] default and upper bound (0 = off).
const kDefaultIdleStandbySeconds = 60;
const kMaxIdleStandbySeconds = 600;

class AppSettings {
  const AppSettings({
    this.backendMode = BackendMode.gptLive,
    this.apiKey = '',
    this.voiceModel = 'gpt-live-1.1',
    this.realtimeModel = 'gpt-realtime-2.1',
    this.voice = 'marin',
    this.compressionThreshold = 10000,
    this.compressionModel = 'gpt-6-luna',
    this.delegateModel = 'gpt-6-luna',
    this.imageModel = 'gpt-image-2.6-flare',
    this.imageQuality = 'low',
    this.imageSize = '1024x1024',
    this.imageFormat = 'jpeg',
    this.webSearchEnabled = true,
    this.useLunaPointer = true,
    this.screenshotDelayMs = 1200,
    this.autoScreenshot = true,
    this.screenshotScale = 0.0,
    this.screenshotJpegQuality = 80,
    this.assistantKeepAliveSeconds = 120,
    this.confirmBeforeBash = true,
    this.runBashInTerminal = false,
    this.micMode = MicMode.handsFree,
    this.imageTokenCost = 765,
    this.thinkingEarcon = false,
    this.liveVoice = 'cove',
    this.workspaceDir = '',
    this.imageFullCount = 3,
    this.imageScaledCount = 5,
    this.imageScaleDivisor = 5,
    this.theme = AppTheme.light,
    this.editApplyDelay = 5,
    this.cameraReplacesScreenshot = false,
    this.fallbackToDirectOnLimit = false,
    this.echoCancellation = true,
    this.androidAudioRoute = AndroidAudioRoute.phone,
    this.stopWordDetection = true,
    this.stopWords = const ['stop'],
    this.usageGuardPercent = 20,
    this.chatPaneFraction = kDefaultChatPaneFraction,
    this.replyDelayMs = kDefaultReplyDelayMs,
    this.idleStandbySeconds = kDefaultIdleStandbySeconds,
  });

  final BackendMode backendMode;
  final String apiKey;

  /// gpt-live model (gpt-live mode).
  final String voiceModel;

  /// Realtime WebSocket model (direct and API-key modes, and the gpt-live fallback).
  final String realtimeModel;
  final String voice;
  final int compressionThreshold;
  final String compressionModel;
  final String delegateModel;

  /// The image model ID is sent unchanged to the selected provider.
  final String imageModel;

  /// Rendering quality for generated images.
  final String imageQuality;

  /// Generated image dimensions, or auto for the provider's choice.
  final String imageSize;
  static const imageSizeChoices = ['1024x1024', '1024x1536', '1536x1024', 'auto'];

  /// Encoded output format; JPEG is shown as JPG in the settings UI.
  final String imageFormat;
  static const imageFormatChoices = ['jpeg', 'png', 'webp'];

  /// Make current web information available to the assistant.
  final bool webSearchEnabled;

  /// Route pointer clicks and movement through a dedicated gpt-6-luna agent.
  final bool useLunaPointer;
  final int screenshotDelayMs;
  final bool autoScreenshot;

  /// Screenshots sent to the model: fraction of the screen's physical
  /// pixels (0.25-1, never upscaled) and JPEG quality (50-100).
  final double screenshotScale;
  final int screenshotJpegQuality;

  /// Android assistant panel: how long the voice session stays connected
  /// after the panel closes (the mic closes at once), so the next activation
  /// skips the 2-7 s handshake. 0: suspend shortly after closing.
  final int assistantKeepAliveSeconds;
  static const List<int> assistantKeepAliveChoices = [0, 30, 120, 300];
  final bool confirmBeforeBash;

  /// run_bash runs visibly in the terminal's AI tab (output still returned).
  final bool runBashInTerminal;
  final MicMode micMode;

  /// Heuristic context cost of one screenshot, in tokens.
  final int imageTokenCost;

  /// Soft chime at the end of the user's speech while the reply is coming.
  final bool thinkingEarcon;

  /// gpt-live voice (its own voice set, see [kLiveVoices]).
  final String liveVoice;

  /// Directory relative paths resolve against; empty = launch directory
  /// (or \$HOME when launched from \$HOME or /).
  final String workspaceDir;

  /// Image compaction tiers: the newest [imageFullCount] screenshots stay at
  /// full resolution, the next [imageScaledCount] are sent at
  /// 1/[imageScaleDivisor] width and height, older ones become text.
  final int imageFullCount;
  final int imageScaledCount;
  final int imageScaleDivisor;

  /// UI colour theme (light by default).
  final AppTheme theme;

  /// Seconds an AI note/file edit preview counts down before it applies
  /// itself (one of [kEditApplyDelays]); [kRequireApproval] = wait for an
  /// explicit Apply.
  final int editApplyDelay;

  /// While the camera is on its frame replaces the turn's screenshot
  /// (default: both are attached).
  final bool cameraReplacesScreenshot;

  /// When gpt-live answers with the ChatGPT usage limit (HTTP 429), connect
  /// with Direct realtime instead until the limit resets.
  final bool fallbackToDirectOnLimit;

  /// Remove what the speakers play (Woi's voice, music, videos) from the
  /// microphone: PipeWire WebRTC echo canceller on Linux, the platform
  /// AEC/NS/AGC on Android, libwebrtc's AEC for gpt-live.
  final bool echoCancellation;

  /// Android only: [AndroidAudioRoute.phone] (default) or media.
  final AndroidAudioRoute androidAudioRoute;

  /// Offline stop-word spotting (sherpa-onnx, on device) while Woi speaks:
  /// saying a stop word cuts Woi right away, without waiting for the server.
  final bool stopWordDetection;

  /// The words [stopWordDetection] listens for (English, default "stop").
  final List<String> stopWords;

  /// When either Codex usage window (5 h, week) has less than this many
  /// percent remaining, delegation and compaction use gpt-6-luna even if a
  /// more expensive model is selected. 0 = off.
  final int usageGuardPercent;

  /// Wide two-pane layout: share of the width taken by the chat pane.
  final double chatPaneFraction;

  /// Direct realtime: silence (ms) that ends the user's spoken turn. Shorter
  /// pauses stay in the same message, and Woi waits at least this long after
  /// the user stops before it answers.
  final int replyDelayMs;

  /// Hands-free: after this many seconds with nothing said the session
  /// closes, the mic keeps listening, and speech reconnects and sends what
  /// was said (Realtime backends). 0: stay connected.
  final int idleStandbySeconds;

  /// The voice used by the current backend mode.
  String get activeVoice => backendMode == BackendMode.gptLive ? liveVoice : voice;

  /// Voices the current backend mode accepts.
  List<String> get voiceChoices => backendMode == BackendMode.gptLive ? kLiveVoices : kVoices;

  AuthMode get authMode => backendMode.authMode;

  /// The selected audio model, retaining each family's saved choice.
  String get audioModel => audioModelFamily == AudioModelFamily.live ? voiceModel : realtimeModel;

  AudioModelFamily get audioModelFamily =>
      backendMode == BackendMode.gptLive ? AudioModelFamily.live : AudioModelFamily.realtime;

  /// Changing login never overwrites saved models or voices. API auth uses
  /// realtime; returning from API to Codex preserves that active family.
  AppSettings withAuthMode(AuthMode mode) {
    if (mode == authMode) return this;
    return copyWith(backendMode: mode == AuthMode.apiKey ? BackendMode.apiKey : BackendMode.direct);
  }

  /// A reason to disable a model family in the UI, or null if selectable.
  /// Build availability is supplied by the caller instead of depending on a
  /// registered transport from this settings/persistence layer.
  String? audioModelUnavailableReason(AudioModelFamily family, {bool liveAvailable = true}) {
    if (family != AudioModelFamily.live) return null;
    if (authMode == AuthMode.apiKey) return 'API uses realtime audio models. gpt-live requires Codex login.';
    if (!liveAvailable) return 'gpt-live is not available in this build.';
    return null;
  }

  /// Select a model by its explicit family. Custom IDs retain the family of
  /// their saved field; never infer it from a name prefix or replace a model.
  AppSettings withAudioModel(String model, {required AudioModelFamily family, bool liveAvailable = true}) {
    final selected = model.trim();
    if (selected.isEmpty) throw ArgumentError.value(model, 'model', 'Choose a nonempty audio model.');
    final unavailable = audioModelUnavailableReason(family, liveAvailable: liveAvailable);
    if (unavailable != null) throw ArgumentError.value(model, 'model', unavailable);
    if (family == AudioModelFamily.live && kRealtimeModels.contains(selected)) {
      throw ArgumentError.value(model, 'model', 'This model belongs to the realtime audio family.');
    }
    if (family == AudioModelFamily.realtime && kVoiceModels.contains(selected)) {
      throw ArgumentError.value(model, 'model', 'This model belongs to the gpt-live audio family.');
    }
    return family == AudioModelFamily.live
        ? copyWith(backendMode: BackendMode.gptLive, voiceModel: selected)
        : copyWith(
            backendMode: authMode == AuthMode.apiKey ? BackendMode.apiKey : BackendMode.direct,
            realtimeModel: selected,
          );
  }

  /// A voice choice changes only the current family's voice. It cannot switch
  /// login or model to make an incompatible voice appear to work.
  AppSettings withActiveVoice(String selected) {
    final value = selected.trim();
    if (!voiceChoices.contains(value)) {
      final family = audioModelFamily == AudioModelFamily.live ? 'gpt-live' : 'realtime';
      throw ArgumentError.value(selected, 'voice', 'This voice is not supported by $family audio models.');
    }
    return audioModelFamily == AudioModelFamily.live ? copyWith(liveVoice: value) : copyWith(voice: value);
  }

  AppSettings copyWith({
    BackendMode? backendMode,
    String? apiKey,
    String? voiceModel,
    String? realtimeModel,
    String? voice,
    int? compressionThreshold,
    String? compressionModel,
    String? delegateModel,
    String? imageModel,
    String? imageQuality,
    String? imageSize,
    String? imageFormat,
    bool? webSearchEnabled,
    bool? useLunaPointer,
    int? screenshotDelayMs,
    bool? autoScreenshot,
    double? screenshotScale,
    int? screenshotJpegQuality,
    int? assistantKeepAliveSeconds,
    bool? confirmBeforeBash,
    bool? runBashInTerminal,
    MicMode? micMode,
    int? imageTokenCost,
    bool? thinkingEarcon,
    String? liveVoice,
    String? workspaceDir,
    int? imageFullCount,
    int? imageScaledCount,
    int? imageScaleDivisor,
    AppTheme? theme,
    int? editApplyDelay,
    bool? cameraReplacesScreenshot,
    bool? echoCancellation,
    AndroidAudioRoute? androidAudioRoute,
    bool? stopWordDetection,
    List<String>? stopWords,
    bool? fallbackToDirectOnLimit,
    int? usageGuardPercent,
    double? chatPaneFraction,
    int? replyDelayMs,
    int? idleStandbySeconds,
  }) => AppSettings(
    backendMode: backendMode ?? this.backendMode,
    apiKey: apiKey ?? this.apiKey,
    voiceModel: voiceModel ?? this.voiceModel,
    realtimeModel: realtimeModel ?? this.realtimeModel,
    voice: voice ?? this.voice,
    compressionThreshold: compressionThreshold ?? this.compressionThreshold,
    compressionModel: compressionModel ?? this.compressionModel,
    delegateModel: delegateModel ?? this.delegateModel,
    imageModel: imageModel ?? this.imageModel,
    imageQuality: imageQuality ?? this.imageQuality,
    imageSize: imageSize ?? this.imageSize,
    imageFormat: imageFormat ?? this.imageFormat,
    webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
    useLunaPointer: useLunaPointer ?? this.useLunaPointer,
    screenshotDelayMs: screenshotDelayMs ?? this.screenshotDelayMs,
    autoScreenshot: autoScreenshot ?? this.autoScreenshot,
    screenshotScale: screenshotScale ?? this.screenshotScale,
    screenshotJpegQuality: screenshotJpegQuality ?? this.screenshotJpegQuality,
    assistantKeepAliveSeconds: assistantKeepAliveSeconds ?? this.assistantKeepAliveSeconds,
    confirmBeforeBash: confirmBeforeBash ?? this.confirmBeforeBash,
    runBashInTerminal: runBashInTerminal ?? this.runBashInTerminal,
    micMode: micMode ?? this.micMode,
    imageTokenCost: imageTokenCost ?? this.imageTokenCost,
    thinkingEarcon: thinkingEarcon ?? this.thinkingEarcon,
    liveVoice: liveVoice ?? this.liveVoice,
    workspaceDir: workspaceDir ?? this.workspaceDir,
    imageFullCount: imageFullCount ?? this.imageFullCount,
    imageScaledCount: imageScaledCount ?? this.imageScaledCount,
    imageScaleDivisor: imageScaleDivisor ?? this.imageScaleDivisor,
    theme: theme ?? this.theme,
    editApplyDelay: editApplyDelay ?? this.editApplyDelay,
    cameraReplacesScreenshot: cameraReplacesScreenshot ?? this.cameraReplacesScreenshot,
    fallbackToDirectOnLimit: fallbackToDirectOnLimit ?? this.fallbackToDirectOnLimit,
    echoCancellation: echoCancellation ?? this.echoCancellation,
    androidAudioRoute: androidAudioRoute ?? this.androidAudioRoute,
    stopWordDetection: stopWordDetection ?? this.stopWordDetection,
    stopWords: stopWords ?? this.stopWords,
    usageGuardPercent: usageGuardPercent ?? this.usageGuardPercent,
    chatPaneFraction: chatPaneFraction ?? this.chatPaneFraction,
    replyDelayMs: replyDelayMs ?? this.replyDelayMs,
    idleStandbySeconds: idleStandbySeconds ?? this.idleStandbySeconds,
  );

  /// Whether a change requires reconnecting the live session.
  bool sessionDiffers(AppSettings o) =>
      o.backendMode != backendMode ||
      o.webSearchEnabled != webSearchEnabled ||
      o.useLunaPointer != useLunaPointer ||
      // Editing a saved API key must not reconnect an active Codex session.
      (authMode == AuthMode.apiKey && o.apiKey != apiKey) ||
      o.voiceModel != voiceModel ||
      o.realtimeModel != realtimeModel ||
      o.voice != voice ||
      o.liveVoice != liveVoice ||
      // Only the realtime WebSocket backends use it.
      (backendMode != BackendMode.gptLive && o.replyDelayMs != replyDelayMs);

  Map<String, Object?> toJson() => {
    'backendMode': backendMode.name,
    'apiKey': apiKey,
    'voiceModel': voiceModel,
    'realtimeModel': realtimeModel,
    'voice': voice,
    'compressionThreshold': compressionThreshold,
    'compressionModel': compressionModel,
    'delegateModel': delegateModel,
    'imageModel': imageModel,
    'imageQuality': imageQuality,
    'imageSize': imageSize,
    'imageFormat': imageFormat,
    'webSearchEnabled': webSearchEnabled,
    'useLunaPointer': useLunaPointer,
    'screenshotDelayMs': screenshotDelayMs,
    'autoScreenshot': autoScreenshot,
    'screenshotScale': screenshotScale,
    'screenshotJpegQuality': screenshotJpegQuality,
    'assistantKeepAliveSeconds': assistantKeepAliveSeconds,
    'confirmBeforeBash': confirmBeforeBash,
    'runBashInTerminal': runBashInTerminal,
    'micMode': micMode.name,
    'imageTokenCost': imageTokenCost,
    'thinkingEarcon': thinkingEarcon,
    'liveVoice': liveVoice,
    'workspaceDir': workspaceDir,
    'imageFullCount': imageFullCount,
    'imageScaledCount': imageScaledCount,
    'imageScaleDivisor': imageScaleDivisor,
    'theme': theme.name,
    'editApplyDelay': editApplyDelay,
    'cameraReplacesScreenshot': cameraReplacesScreenshot,
    'fallbackToDirectOnLimit': fallbackToDirectOnLimit,
    'echoCancellation': echoCancellation,
    'androidAudioRoute': androidAudioRoute.name,
    'stopWordDetection': stopWordDetection,
    'stopWords': stopWords,
    'usageGuardPercent': usageGuardPercent,
    'chatPaneFraction': chatPaneFraction,
    'replyDelayMs': replyDelayMs,
    'idleStandbySeconds': idleStandbySeconds,
  };

  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    int i(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    String s(String k, String def) {
      final v = j[k];
      return v is String && v.isNotEmpty ? v : def;
    }

    bool b(String k, bool def) => j[k] is bool ? j[k] as bool : def;
    final savedImageModel = s('imageModel', d.imageModel).trim();
    final savedImageFormat = s('imageFormat', d.imageFormat).trim().toLowerCase();
    return AppSettings(
      backendMode:
          BackendMode.values.asNameMap()[j['backendMode']] ??
          // Settings written before backend modes existed.
          (j['authMode'] == AuthMode.apiKey.name ? BackendMode.apiKey : d.backendMode),
      apiKey: j['apiKey'] as String? ?? '',
      voiceModel: s('voiceModel', d.voiceModel),
      realtimeModel: s('realtimeModel', d.realtimeModel),
      voice: s('voice', d.voice),
      compressionThreshold: i('compressionThreshold', d.compressionThreshold).clamp(1000, 1000000),
      compressionModel: s('compressionModel', d.compressionModel),
      delegateModel: s('delegateModel', d.delegateModel),
      // Move the previous default forward without replacing custom choices.
      imageModel: savedImageModel.isEmpty || savedImageModel == 'gpt-image-flare-2.1' ? d.imageModel : savedImageModel,
      imageQuality: const ['low', 'medium', 'high', 'xhigh', 'max', 'auto'].contains(j['imageQuality'])
          ? j['imageQuality'] as String
          : d.imageQuality,
      imageSize: imageSizeChoices.contains(j['imageSize']) ? j['imageSize'] as String : d.imageSize,
      imageFormat: savedImageFormat == 'jpg'
          ? 'jpeg'
          : imageFormatChoices.contains(savedImageFormat)
          ? savedImageFormat
          : d.imageFormat,
      webSearchEnabled: b('webSearchEnabled', d.webSearchEnabled),
      useLunaPointer: b('useLunaPointer', d.useLunaPointer),
      screenshotDelayMs: i('screenshotDelayMs', d.screenshotDelayMs).clamp(0, 10000),
      autoScreenshot: b('autoScreenshot', d.autoScreenshot),
      screenshotScale: switch (j['screenshotScale']) {
        final num v when v.isFinite && v <= 0 => 0.0,
        final num v when v.isFinite => v.toDouble().clamp(0.25, 1.0),
        _ => d.screenshotScale,
      },
      screenshotJpegQuality: i('screenshotJpegQuality', d.screenshotJpegQuality).clamp(50, 100),
      assistantKeepAliveSeconds: i('assistantKeepAliveSeconds', d.assistantKeepAliveSeconds).clamp(0, 600),
      confirmBeforeBash: b('confirmBeforeBash', d.confirmBeforeBash),
      runBashInTerminal: b('runBashInTerminal', d.runBashInTerminal),
      micMode: MicMode.values.asNameMap()[j['micMode']] ?? d.micMode,
      imageTokenCost: i('imageTokenCost', d.imageTokenCost),
      thinkingEarcon: b('thinkingEarcon', d.thinkingEarcon),
      liveVoice: s('liveVoice', d.liveVoice),
      workspaceDir: j['workspaceDir'] as String? ?? '',
      imageFullCount: i('imageFullCount', d.imageFullCount).clamp(1, 50),
      imageScaledCount: i('imageScaledCount', d.imageScaledCount).clamp(0, 100),
      imageScaleDivisor: i('imageScaleDivisor', d.imageScaleDivisor).clamp(2, 10),
      theme: AppTheme.values.asNameMap()[j['theme']] ?? d.theme,
      editApplyDelay: kEditApplyDelays.contains(i('editApplyDelay', d.editApplyDelay))
          ? i('editApplyDelay', d.editApplyDelay)
          : d.editApplyDelay,
      cameraReplacesScreenshot: b('cameraReplacesScreenshot', d.cameraReplacesScreenshot),
      fallbackToDirectOnLimit: b('fallbackToDirectOnLimit', d.fallbackToDirectOnLimit),
      echoCancellation: b('echoCancellation', d.echoCancellation),
      androidAudioRoute: AndroidAudioRoute.values.asNameMap()[j['androidAudioRoute']] ?? d.androidAudioRoute,
      stopWordDetection: b('stopWordDetection', d.stopWordDetection),
      stopWords: j['stopWords'] is List
          ? [
              for (final w in j['stopWords'] as List)
                if (w is String && w.trim().isNotEmpty) w.trim().toLowerCase(),
            ]
          : d.stopWords,
      usageGuardPercent: i('usageGuardPercent', d.usageGuardPercent).clamp(0, 100),
      chatPaneFraction: ((j['chatPaneFraction'] as num?)?.toDouble() ?? d.chatPaneFraction).clamp(
        kChatPaneMinFraction,
        kChatPaneMaxFraction,
      ),
      replyDelayMs: i('replyDelayMs', d.replyDelayMs).clamp(kMinReplyDelayMs, kMaxReplyDelayMs),
      idleStandbySeconds: i('idleStandbySeconds', d.idleStandbySeconds).clamp(0, kMaxIdleStandbySeconds),
    );
  }
}

/// JSON-file settings persistence (file mode 0600 since it may hold a key).
class SettingsStore {
  SettingsStore(this.path);
  final String path;

  Future<AppSettings> load() async {
    final f = File(path);
    if (!await f.exists()) return const AppSettings();
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map ? AppSettings.fromJson(j.cast()) : const AppSettings();
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings s) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['600', tmp.path]);
    }
    await tmp.rename(path);
  }
}

/// "stop, hold on" -> ["stop", "hold on"] (lower case, no empties).
List<String> parseStopWords(String text) => [
  for (final w in text.split(RegExp(r'[,;\n]')))
    if (w.trim().isNotEmpty) w.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
];
