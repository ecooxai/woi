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

/// gpt-live models (WebRTC path, research/REALTIME_API.md §3).
const kVoiceModels = ['gpt-live-1.1', 'gpt-live-1', 'gpt-live-1-codex'];

/// Models that work on wss://api.openai.com/v1/realtime (§2.1).
const kRealtimeModels = ['gpt-realtime-2.1', 'gpt-realtime-2.1-mini', 'gpt-realtime-2', 'gpt-realtime-1.5', 'gpt-realtime', 'gpt-realtime-mini'];

/// Voices of the realtime WebSocket models (direct and API-key modes).
const kVoices = ['marin', 'cedar', 'alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'];

/// v3 voices accepted by gpt-live (§3.1). Realtime voices (marin, alloy...)
/// make the call die silently, so anything else maps to [kLiveDefaultVoice].
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

/// Choices for [AppSettings.editApplyDelay] (seconds).
const kEditApplyDelays = [0, 3, 5, 10, kRequireApproval];

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
    this.screenshotDelayMs = 1200,
    this.autoScreenshot = true,
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
  final int screenshotDelayMs;
  final bool autoScreenshot;
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

  /// The voice used by the current backend mode.
  String get activeVoice => backendMode == BackendMode.gptLive ? liveVoice : voice;

  /// Voices the current backend mode accepts.
  List<String> get voiceChoices => backendMode == BackendMode.gptLive ? kLiveVoices : kVoices;

  AuthMode get authMode => backendMode.authMode;

  AppSettings copyWith({
    BackendMode? backendMode,
    String? apiKey,
    String? voiceModel,
    String? realtimeModel,
    String? voice,
    int? compressionThreshold,
    String? compressionModel,
    String? delegateModel,
    int? screenshotDelayMs,
    bool? autoScreenshot,
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
    bool? fallbackToDirectOnLimit,
  }) => AppSettings(
    backendMode: backendMode ?? this.backendMode,
    apiKey: apiKey ?? this.apiKey,
    voiceModel: voiceModel ?? this.voiceModel,
    realtimeModel: realtimeModel ?? this.realtimeModel,
    voice: voice ?? this.voice,
    compressionThreshold: compressionThreshold ?? this.compressionThreshold,
    compressionModel: compressionModel ?? this.compressionModel,
    delegateModel: delegateModel ?? this.delegateModel,
    screenshotDelayMs: screenshotDelayMs ?? this.screenshotDelayMs,
    autoScreenshot: autoScreenshot ?? this.autoScreenshot,
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
  );

  /// Whether a change requires reconnecting the live session.
  bool sessionDiffers(AppSettings o) =>
      o.backendMode != backendMode ||
      o.apiKey != apiKey ||
      o.voiceModel != voiceModel ||
      o.realtimeModel != realtimeModel ||
      o.voice != voice ||
      o.liveVoice != liveVoice;

  Map<String, Object?> toJson() => {
    'backendMode': backendMode.name,
    'apiKey': apiKey,
    'voiceModel': voiceModel,
    'realtimeModel': realtimeModel,
    'voice': voice,
    'compressionThreshold': compressionThreshold,
    'compressionModel': compressionModel,
    'delegateModel': delegateModel,
    'screenshotDelayMs': screenshotDelayMs,
    'autoScreenshot': autoScreenshot,
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
  };

  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    int i(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    String s(String k, String def) {
      final v = j[k];
      return v is String && v.isNotEmpty ? v : def;
    }

    bool b(String k, bool def) => j[k] is bool ? j[k] as bool : def;
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
      screenshotDelayMs: i('screenshotDelayMs', d.screenshotDelayMs).clamp(0, 10000),
      autoScreenshot: b('autoScreenshot', d.autoScreenshot),
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
