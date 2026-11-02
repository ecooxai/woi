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

/// Which voice backend the app talks to.
enum BackendMode {
  gptLive('gpt-live (WebRTC)'),
  direct('Direct realtime (gpt-realtime-1.5)'),
  apiKey('OpenAI API key');

  const BackendMode(this.label);
  final String label;

  /// Credentials this mode authenticates with.
  AuthMode get authMode => this == BackendMode.apiKey ? AuthMode.apiKey : AuthMode.codex;
}

/// gpt-live models (WebRTC path, research/REALTIME_API.md §3).
const kVoiceModels = ['gpt-live-1.1', 'gpt-live-1', 'gpt-live-1-codex'];

/// Models that work on wss://api.openai.com/v1/realtime (§2.1).
const kRealtimeModels = ['gpt-realtime-1.5', 'gpt-realtime', 'gpt-realtime-2', 'gpt-realtime-mini'];
const kVoices = ['marin', 'cedar', 'alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'];

class AppSettings {
  const AppSettings({
    this.backendMode = BackendMode.gptLive,
    this.apiKey = '',
    this.voiceModel = 'gpt-live-1.1',
    this.realtimeModel = 'gpt-realtime-1.5',
    this.voice = 'marin',
    this.compressionThreshold = 10000,
    this.compressionModel = 'gpt-6-luna',
    this.delegateModel = 'gpt-6.1-sol',
    this.screenshotDelayMs = 1200,
    this.autoScreenshot = true,
    this.confirmBeforeBash = true,
    this.micMode = MicMode.handsFree,
    this.imageTokenCost = 765,
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
  final MicMode micMode;

  /// Heuristic context cost of one screenshot, in tokens.
  final int imageTokenCost;

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
    MicMode? micMode,
    int? imageTokenCost,
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
    micMode: micMode ?? this.micMode,
    imageTokenCost: imageTokenCost ?? this.imageTokenCost,
  );

  /// Whether a change requires reconnecting the live session.
  bool sessionDiffers(AppSettings o) =>
      o.backendMode != backendMode ||
      o.apiKey != apiKey ||
      o.voiceModel != voiceModel ||
      o.realtimeModel != realtimeModel ||
      o.voice != voice;

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
    'micMode': micMode.name,
    'imageTokenCost': imageTokenCost,
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
      micMode: MicMode.values.asNameMap()[j['micMode']] ?? d.micMode,
      imageTokenCost: i('imageTokenCost', d.imageTokenCost),
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
