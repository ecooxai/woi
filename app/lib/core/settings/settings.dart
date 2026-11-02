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

const kVoiceModels = ['gpt-live-1.1', 'gpt-live-1'];
const kVoices = ['marin', 'cedar', 'alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'];

class AppSettings {
  const AppSettings({
    this.authMode = AuthMode.codex,
    this.apiKey = '',
    this.voiceModel = 'gpt-live-1.1',
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

  final AuthMode authMode;
  final String apiKey;
  final String voiceModel;
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

  AppSettings copyWith({
    AuthMode? authMode,
    String? apiKey,
    String? voiceModel,
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
    authMode: authMode ?? this.authMode,
    apiKey: apiKey ?? this.apiKey,
    voiceModel: voiceModel ?? this.voiceModel,
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
      o.authMode != authMode || o.apiKey != apiKey || o.voiceModel != voiceModel || o.voice != voice;

  Map<String, Object?> toJson() => {
    'authMode': authMode.name,
    'apiKey': apiKey,
    'voiceModel': voiceModel,
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
      authMode: AuthMode.values.asNameMap()[j['authMode']] ?? d.authMode,
      apiKey: j['apiKey'] as String? ?? '',
      voiceModel: s('voiceModel', d.voiceModel),
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
