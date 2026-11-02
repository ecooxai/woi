import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/platform_services.dart';
import '../tools/builtin_tools.dart';
import '../tools/confirmation.dart';
import '../tools/tool_registry.dart';
import 'auth/auth.dart';
import 'context/compressor.dart';
import 'context/context_manager.dart';
import 'delegate/delegate_backend.dart';
import 'models/message.dart';
import 'pipeline/turn_pipeline.dart';
import 'settings/settings.dart';
import 'storage/history_store.dart';
import 'voice/mock_voice_backend.dart';
import 'voice/voice_backend.dart';

const kAssistantInstructions = '''
You are Woi, a fast, friendly voice assistant running on the user's Linux desktop.
Speak concisely: short sentences, no markdown, no lists unless asked.
When the user speaks you usually receive a screenshot of their screen taken a moment later;
use it to understand what they refer to. Coordinates for click_screen are pixels of the latest screenshot.
You can operate the computer with tools (click_screen, type_text, key_combo, take_screenshot, run_bash,
read_file, list_dir, edit_file, write_file, show_file). File writes and (by default) shell commands need the
user's approval, which the app requests. Delegate long or complex work (coding, deep analysis) with delegate_task.
Say briefly what you are about to do before acting, and summarise results in one or two sentences.
''';

/// Owns the long-lived services and exposes app-level actions to the UI.
class AppController extends ChangeNotifier {
  AppController({
    required this.platform,
    required this.confirmations,
    VoiceBackend Function()? backendFactory,
    Compressor? compressor,
    DelegateBackend? delegate,
  }) : _backendFactory = backendFactory ?? (() => MockVoiceBackend()),
       compressor = compressor ?? StubCompressor(),
       delegate = delegate ?? StubDelegateBackend();

  final PlatformServices platform;
  final ConfirmationService confirmations;
  final VoiceBackend Function() _backendFactory;
  final Compressor compressor;
  final DelegateBackend delegate;

  late final SettingsStore _settingsStore = SettingsStore(platform.paths.settingsFile);
  late final HistoryStore history = HistoryStore(platform.paths);
  late final ContextManager contextManager;
  late final ToolRegistry tools;
  late final ToolEnvironment toolEnv;
  late final TurnPipeline pipeline;

  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;
  CodexAuthInfo? codexAuth;
  bool _ready = false;
  bool get ready => _ready;
  Object? initError;

  Future<void> init() async {
    try {
      _settings = await _settingsStore.load();
      await history.init();
      codexAuth = await CodexAuthInfo.load();
      final conv = await history.loadLatest() ?? Conversation();

      contextManager = ContextManager(
        compressor: compressor,
        threshold: _settings.compressionThreshold,
        compressionModel: _settings.compressionModel,
        imageTokenCost: _settings.imageTokenCost,
      );

      late final TurnPipeline p;
      toolEnv = ToolEnvironment(
        platform: platform,
        confirmations: confirmations,
        delegate: delegate,
        settings: () => _settings,
        onScreenshot: (shot, note) => p.attachScreenshot(shot, note: note),
      );
      tools = ToolRegistry()..registerAll(builtinTools(toolEnv));

      p = TurnPipeline(
        backendFactory: _backendFactory,
        audio: platform.audio,
        screen: platform.screen,
        tools: tools,
        context: contextManager,
        store: history,
        conversation: conv,
        sessionConfig: _sessionConfig,
        options: _pipelineOptions,
        onScreenshotCaptured: (s) => toolEnv.lastScreenshot = s,
      );
      pipeline = p;
      _ready = true;
      notifyListeners();
      await pipeline.start();
    } catch (e, st) {
      initError = e;
      debugPrint('init failed: $e\n$st');
      notifyListeners();
    }
  }

  PipelineOptions _pipelineOptions() => PipelineOptions(
    autoScreenshot: _settings.autoScreenshot,
    screenshotDelay: Duration(milliseconds: _settings.screenshotDelayMs),
    micMode: _settings.micMode,
  );

  Future<SessionConfig> _sessionConfig(Conversation c) async => SessionConfig(
    model: _settings.voiceModel,
    voice: _settings.voice,
    instructions: kAssistantInstructions,
    tools: tools.specs,
    credentials: await resolveCredentials(_settings.authMode, _settings.apiKey),
    priorContext: c.summary,
  );

  Future<void> updateSettings(AppSettings next) async {
    final prev = _settings;
    _settings = next;
    contextManager
      ..threshold = next.compressionThreshold
      ..compressionModel = next.compressionModel
      ..imageTokenCost = next.imageTokenCost;
    notifyListeners();
    await _settingsStore.save(next);
    if (next.micMode != prev.micMode) await pipeline.setMicMode(next.micMode);
    if (prev.sessionDiffers(next)) await pipeline.connect();
    contextManager.onConversationChanged();
  }

  Future<void> setMicMode(MicMode mode) => updateSettings(_settings.copyWith(micMode: mode));

  Future<void> refreshCodexAuth() async {
    codexAuth = await CodexAuthInfo.load();
    notifyListeners();
  }

  Future<List<ConversationSummary>> listConversations() => history.list();

  Future<void> newConversation() async {
    if (pipeline.conversation.messages.isEmpty) return;
    await pipeline.switchConversation(Conversation());
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (id == pipeline.conversation.id) return;
    final c = await history.load(id);
    if (c == null) return;
    await pipeline.switchConversation(c);
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    if (id == pipeline.conversation.id) {
      await pipeline.switchConversation(Conversation());
    }
    await history.delete(id);
    notifyListeners();
  }

  /// Manual compaction from the UI.
  void compactNow() => contextManager.maybeCompress(force: true);

  Future<void> shutdown() async {
    if (_ready) await pipeline.shutdown();
  }
}
