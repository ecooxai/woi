import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dart:io';

import '../platform/platform_services.dart';
import '../tools/builtin_tools.dart';
import '../tools/confirmation.dart';
import '../tools/tool_registry.dart';
import 'auth/auth.dart';
import 'context/compressor.dart';
import 'context/context_manager.dart';
import 'context/image_tiers.dart';
import 'context/responses_compressor.dart';
import 'delegate/delegate_backend.dart';
import 'delegate/responses_delegate.dart';
import 'models/message.dart';
import 'pipeline/turn_pipeline.dart';
import 'responses/responses_client.dart';
import 'settings/settings.dart';
import 'storage/history_store.dart';
import 'voice/backend_factory.dart';
import 'voice/voice_backend.dart';

const kAssistantInstructions = '''
Your name is Woi. You are a fast voice assistant running on the user's Linux desktop. If asked who you are, say
you are Woi. Never call yourself ChatGPT, Aurora, an OpenAI model or any name you see in window titles or on screen.
Be quick and concise: answer in one or two short spoken sentences, no markdown, no lists unless asked.
Act, don't narrate: when a request maps to a tool, call the tool directly and immediately, without asking for
confirmation and without announcing it first; afterwards confirm the result in a few words.
Honesty: never say an action is done, opened, written, clicked or saved before its tool result says so. Report
the real outcome; if a tool failed, was rejected or did nothing, say that plainly. Never invent file contents,
paths or command output.
Say any acknowledgement ("on it", "one moment") at most once per request; do not repeat filler while waiting.
Screenshots of the user's screen are attached while they speak; use them to resolve what they refer to.
click_screen takes x/y in the pixel coordinates of the latest screenshot image (not the real screen);
the app scales them to real screen pixels. Take a screenshot first if you have none or the screen changed.
Tools: click_screen, type_text, key_combo, take_screenshot, run_bash, read_file, list_dir, edit_file,
write_file, show_file (show a file, image, audio or video to the user), delegate_task.
File writes and edits are shown to the user as a diff for approval by the app; shell commands may need approval.
Use delegate_task only for genuinely complex multi-step work (writing programs, multi-file changes, research
or long analysis); simple actions you do yourself. When a delegated result comes back, speak its gist briefly.
If the user only says stop, cancel or never mind, stop and say nothing at all; do not acknowledge it.
''';

/// Extra rules for gpt-live, which acts only through delegation.
const kLiveInstructions = '''
On this connection you cannot use tools yourself: every request to do something on the computer (open, show,
play, click, type, run, read, write, edit, create, delete, find, list, take a screenshot) must go to delegation,
every time, even if a similar request was handled before. Never claim an action happened unless the delegation
result says so; speak the result as reported, including failures.
''';

/// Owns the long-lived services and exposes app-level actions to the UI.
class AppController extends ChangeNotifier {
  AppController({
    required this.platform,
    required this.confirmations,
    VoiceBackend Function()? backendFactory,
    Compressor? compressor,
    DelegateBackend? delegate,
    CodexAuthManager? authManager,
  }) : _backendOverride = backendFactory,
       _compressorOverride = compressor,
       _delegateOverride = delegate,
       authManager = authManager ?? CodexAuthManager();

  final PlatformServices platform;
  final ConfirmationService confirmations;
  final VoiceBackend Function()? _backendOverride;
  final Compressor? _compressorOverride;
  final DelegateBackend? _delegateOverride;

  /// Codex login (~/.codex/auth.json) with refresh-near-expiry.
  final CodexAuthManager authManager;

  /// Responses API (compression + delegation) with the current credentials.
  late final ResponsesClient responses = ResponsesClient(credentials: credentials);
  late final Compressor compressor = _compressorOverride ?? ResponsesCompressor(responses);
  late final DelegateBackend delegate =
      _delegateOverride ??
      ResponsesDelegate(
        responses,
        tools: () => tools,
        latestScreenshot: () => toolEnv.lastScreenshot?.png,
        environment: environmentNote,
      );

  /// Real user name, \$HOME and workspace dir for model prompts.
  String environmentNote() {
    final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? '';
    final home = platform.files.homeDir;
    final ws = platform.files.workspaceDir;
    return 'Environment: user name ${user.isEmpty ? 'unknown' : user}; home directory (\$HOME, ~) is $home; '
        'workspace directory (relative paths and the default shell cwd) is $ws. '
        'Use exactly these paths; never invent others such as /home/oai or /home/user.';
  }

  BackendSelection? _selection;

  /// Mode actually in use (gpt-live falls back to direct until registered).
  BackendMode get activeBackendMode => _selection?.mode ?? _settings.backendMode;

  /// Voice model of the running session.
  String get activeVoiceModel =>
      _selection?.model ??
      (_settings.backendMode == BackendMode.gptLive ? _settings.voiceModel : _settings.realtimeModel);

  /// Credentials for the selected mode; refreshes the Codex token when close
  /// to expiry and persists it back to auth.json.
  Future<Credentials?> credentials() => resolveCredentials(_settings.authMode, _settings.apiKey, manager: authManager);

  VoiceBackend _createBackend() {
    final o = _backendOverride;
    if (o != null) {
      _selection = null;
      return o();
    }
    final sel = createVoiceBackend(BackendContext(settings: _settings, credentials: credentials));
    _selection = sel;
    final notice = sel.notice;
    if (notice != null) {
      debugPrint(notice);
      scheduleMicrotask(() {
        if (_ready) pipeline.notice(notice);
      });
    }
    notifyListeners();
    return sel.backend;
  }

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
      _defaultWorkspace = platform.files.workspaceDir;
      _applyWorkspace();
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
        backendFactory: _createBackend,
        audio: platform.audio,
        screen: platform.screen,
        tools: tools,
        context: contextManager,
        store: history,
        conversation: conv,
        sessionConfig: _sessionConfig,
        options: _pipelineOptions,
        onScreenshotCaptured: (s) => toolEnv.lastScreenshot = s,
        imageCompactor: ImageCompactor(
          downscale: uiDownscale,
          describe: responsesDescriber(responses, model: () => _settings.compressionModel),
          save: history.saveImage,
        ),
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

  late String _defaultWorkspace;

  /// The configured workspace dir if it exists, else the launch default.
  String get defaultWorkspace => _defaultWorkspace;

  void _applyWorkspace() {
    final want = _settings.workspaceDir.trim();
    var dir = _defaultWorkspace;
    if (want.isNotEmpty) {
      final full = platform.files.resolve(want);
      if (Directory(full).existsSync()) {
        dir = full;
      } else {
        debugPrint('workspace dir $full does not exist; using $dir');
      }
    }
    platform.files.workspaceDir = dir;
  }

  PipelineOptions _pipelineOptions() => PipelineOptions(
    autoScreenshot: _settings.autoScreenshot,
    screenshotDelay: Duration(milliseconds: _settings.screenshotDelayMs),
    micMode: _settings.micMode,
    thinkingEarcon: _settings.thinkingEarcon,
  );

  Future<SessionConfig> _sessionConfig(Conversation c) async {
    Credentials? creds;
    try {
      creds = await credentials();
    } on AuthException catch (e) {
      pipeline.notice(e.message);
    }
    return SessionConfig(
      model: activeVoiceModel,
      voice: _settings.activeVoice,
      instructions: [
        kAssistantInstructions,
        if (_settings.backendMode == BackendMode.gptLive) kLiveInstructions,
        environmentNote(),
      ].join('\n'),
      tools: tools.specs,
      credentials: creds,
      priorContext: c.summary,
      recentContext: contextManager.recentTurns(),
      environment: environmentNote(),
    );
  }

  Future<void> updateSettings(AppSettings next) async {
    final prev = _settings;
    _settings = next;
    contextManager
      ..threshold = next.compressionThreshold
      ..compressionModel = next.compressionModel
      ..imageTokenCost = next.imageTokenCost;
    if (next.workspaceDir != prev.workspaceDir) _applyWorkspace();
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
