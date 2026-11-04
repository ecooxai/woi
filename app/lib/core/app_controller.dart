import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import 'dart:io';

import '../platform/platform_services.dart';
import '../tools/builtin_tools.dart';
import '../platform/audio_io.dart';
import '../platform/camera.dart';
import '../platform/media_viewer.dart';
import '../tools/confirmation.dart';
import '../tools/app_tools.dart';
import '../tools/media_tools.dart';
import '../tools/note_tools.dart';
import '../tools/send_keys_tool.dart';
import '../tools/tool_registry.dart';
import 'app_actions.dart';
import 'auth/auth.dart';
import 'auth/pkce_login.dart';
import 'context/compressor.dart';
import 'context/context_manager.dart';
import 'context/image_tiers.dart';
import 'context/responses_compressor.dart';
import 'delegate/delegate_backend.dart';
import 'delegate/responses_delegate.dart';
import 'edits/edit_review.dart';
import 'media/audio_describer.dart';
import 'media/media_context.dart';
import 'models/message.dart';
import 'notes/note.dart';
import 'notes/note_controller.dart';
import 'notes/note_store.dart';
import 'notes/pinned_note.dart';
import 'pipeline/turn_pipeline.dart';
import 'responses/responses_client.dart';
import 'settings/settings.dart';
import 'storage/history_store.dart';
import 'terminal/terminal_hub.dart';
import 'usage/codex_usage.dart';
import 'usage/model_guard.dart';
import 'util/usage_limit.dart';
import 'voice/backend_factory.dart';
import 'voice/pinned_context.dart';
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
Tools: click_screen, type_text, send_keys, take_screenshot, run_bash, read_file, list_dir, edit_file,
write_file, show_file (show a file, image, audio or video to the user inside Woi), read_note, update_note,
note_control, app_control, delegate_task.
note_control runs the notes: append/insert/replace/delete_text in this note, the editor's undo/redo, and new,
switch, rename, delete, list of notes. app_control runs Woi itself: show_view (note, chat, terminal, split),
set_setting (theme, voice, voice_model, mic_mode, compaction_threshold, run_in_terminal, edit_apply_delay,
echo_cancellation), terminal tabs (terminal_new, terminal_run, terminal_close), the media viewer (viewer_open/close/pause/play/seek),
apply_edit / reject_edit, and undo_edit for "undo that" (reverts your last note or file edit).
Note and file edits appear as an inline diff that applies itself after a few seconds unless the user rejects it;
the tool result tells you whether it was applied. Shell commands may need explicit approval.
Use delegate_task only for genuinely complex multi-step work (writing programs, multi-file changes, research
or long analysis); simple actions you do yourself. When a delegated result comes back, speak its gist briefly.
If the user only says stop, cancel or never mind, stop and say nothing at all; do not acknowledge it.
Every conversation has a Markdown note that the user sees and edits too; its current text is pinned below.
Proactively record what matters with update_note, without asking and without announcing it at length:
decisions, todos (as "- [ ] task" checklist items), facts, names, dates, numbers and file paths. Check off
todos with mode check_item when they are done. Keep the note tidy: short bullets under "## " sections
(replace_section to rewrite a section). Answer questions from the note when it has the answer. Never read
the whole note aloud unless asked.
''';

/// Extra rules for gpt-live, which acts only through delegation.
const kLiveInstructions = '''
On this connection you cannot use tools yourself: every request to do something on the computer (open, show,
play, click, type, run, read, write, edit, create, delete, find, list, take a screenshot) must go to delegation,
every time, even if a similar request was handled before. That includes controlling Woi itself: switching the
view (note, chat, terminal), changing settings (theme, voice, mic mode), notes (add to, edit, new, switch,
rename, delete), terminal tabs, the media viewer, and "undo that". If the user only says "apply" or "reject"
while an edit preview is shown, the app handles it; say nothing. Never claim an action happened unless the delegation
result says so; speak the result as reported, including failures.
''';

/// Camera and media context (spec batch 2026-11-03 #3).
const kCameraMediaInstructions = '''
Camera: tool camera (open/close). While it is on, a live camera frame (the user and their surroundings, not the
screen) is attached to each user turn; answer "what do you see", "what am I holding" from the newest frame.
Media: when the user asks about what is open in Woi's viewer ("what's in this image", "what is this song",
"what are they saying", "what's happening in the video now"), call inspect_media (unless its result or the
media image is already attached to the turn) and answer from it; for video mention the timestamp if useful.
''';

/// gpt-live: looking and listening is done by delegation too.
const kLiveCameraMediaInstructions = '''
You cannot see or hear media yourself. Questions about what the camera sees, the screen, or the image, video or
audio open in Woi's viewer ("what do you see", "what's in this image", "what is this song", "what's happening
now") go to delegation as well, every time: it sees the camera frames and the open media. Opening or closing the
camera goes to delegation too.
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
    CodexUsage? usage,
  }) : _usageOverride = usage,
       _backendOverride = backendFactory,
       _compressorOverride = compressor,
       _delegateOverride = delegate,
       authManager = authManager ?? CodexAuthManager(path: platform.authPath);

  final PlatformServices platform;
  final ConfirmationService confirmations;
  final VoiceBackend Function()? _backendOverride;
  final Compressor? _compressorOverride;
  final DelegateBackend? _delegateOverride;
  final CodexUsage? _usageOverride;

  /// Codex login (~/.codex/auth.json) with refresh-near-expiry.
  final CodexAuthManager authManager;

  /// Responses API (compression + delegation) with the current credentials.
  late final ResponsesClient responses = ResponsesClient(credentials: credentials);
  late final Compressor compressor = _compressorOverride ?? ResponsesCompressor(responses);
  late final DelegateBackend delegate = GuardedDelegate(
    _delegateOverride ??
        ResponsesDelegate(
          responses,
          tools: () => tools,
          latestScreenshot: () => toolEnv.lastScreenshot?.png,
          environment: environmentNote,
        ),
    _guard,
    onChoice: (c) {
      if (c.downgraded) debugPrint('delegation: ${c.reason}');
    },
  );

  /// ChatGPT/Codex rate-limit windows (5 h + week), from response headers
  /// and the usage endpoint (at launch, then every 10 min while active).
  late final CodexUsage usage = _usageOverride ?? CodexUsage(credentials: credentials);

  ModelChoice _guard(String selected) =>
      guardModel(selected, usage.snapshot, thresholdPercent: _settings.usageGuardPercent);

  /// The model compaction (and screenshot descriptions) actually use, with
  /// the reason when the usage guard overrides the selected one.
  ModelChoice get compactionChoice => _guard(_settings.compressionModel);

  /// The model `delegate_task` actually uses (see [compactionChoice]).
  ModelChoice get delegationChoice => _guard(_settings.delegateModel);

  /// The usage window that is below the guard threshold, if any.
  (String, UsageWindow)? get lowUsage => usage.snapshot?.lowWindow(_settings.usageGuardPercent);

  bool _usageLowNoticed = false;

  void _onUsageChanged() {
    if (!_ready) return;
    contextManager.compressionModel = compactionChoice.model;
    final low = lowUsage;
    if (low == null) {
      _usageLowNoticed = false;
    } else if (!_usageLowNoticed) {
      // Once per low period (again after the window resets and drops again).
      _usageLowNoticed = true;
      final n = usageLowNotice(low.$1, low.$2);
      debugPrint(n);
      pipeline.notice(n);
    }
    notifyListeners();
  }

  /// "ChatGPT usage low: 5h window 12% left (resets Thu 5 Nov 14:31). ..."
  String usageLowNotice(String label, UsageWindow w) {
    final r = w.resetsAt;
    final models = [
      if (compactionChoice.downgraded || delegationChoice.downgraded) 'delegation and compaction now use $kCheapModel',
      if (activeBackendMode == BackendMode.gptLive) 'gpt-live voice uses the same quota',
    ];
    return 'ChatGPT usage low: $label window ${w.remainingPercent.round()}% left'
        '${r == null ? '' : ' (resets ${UsageLimit.formatReset(r)})'}'
        '${models.isEmpty ? '.' : '. ${_cap(models.join('; '))}.'}';
  }

  static String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// Polls the usage endpoint only while it can answer and the app is in use.
  void _syncUsagePolling() {
    usage.setActive(
      _ready &&
          !_inBackground &&
          !_windowHidden &&
          !_needsLogin &&
          _settings.authMode == AuthMode.codex &&
          (codexAuth?.isAvailable ?? false),
    );
  }

  /// Real user name, \$HOME and workspace dir for model prompts.
  String environmentNote() {
    final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? '';
    final home = platform.files.homeDir;
    final ws = platform.files.workspaceDir;
    return 'Environment: user name ${user.isEmpty ? 'unknown' : user}; home directory (\$HOME, ~) is $home; '
        'workspace directory (relative paths and the default shell cwd) is $ws. '
        'Use exactly these paths; never invent others such as /home/oai or /home/user.'
        '${platform.deviceNote.isEmpty ? '' : ' ${platform.deviceNote}'}';
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
    final limit = _liveLimit;
    final BackendSelection sel;
    if (_settings.backendMode == BackendMode.gptLive &&
        _settings.fallbackToDirectOnLimit &&
        limit != null &&
        limit.activeAt(DateTime.now(), seenAt: _liveLimitSeen)) {
      // gpt-live is out of quota: Direct realtime until the limit resets.
      sel = createVoiceBackend(
        BackendContext(
          settings: _settings.copyWith(backendMode: BackendMode.direct),
          credentials: credentials,
        ),
      );
      _selection = BackendSelection(
        backend: sel.backend,
        mode: BackendMode.direct,
        model: sel.model,
        notice: 'gpt-live: ${limit.message}. Using Direct realtime (${_settings.realtimeModel}) until then.',
      );
    } else {
      sel = createVoiceBackend(BackendContext(settings: _settings, credentials: credentials));
      _selection = sel;
    }
    final notice = _selection!.notice;
    // Once per limit, not on every reconnect attempt.
    if (notice != null && notice != _lastBackendNotice) {
      _lastBackendNotice = notice;
      debugPrint(notice);
      scheduleMicrotask(() {
        if (_ready) pipeline.notice(notice);
      });
    }
    notifyListeners();
    return sel.backend;
  }

  String? _lastBackendNotice;

  // gpt-live's usage limit (HTTP 429), remembered so a reconnect does not
  // hit it again before it resets.
  UsageLimit? _liveLimit;
  DateTime? _liveLimitSeen;

  /// The voice session failed on the ChatGPT usage limit. Returns true when
  /// one immediate retry makes sense (gpt-live with the Direct fallback on).
  Future<bool> _onUsageLimit(UsageLimit limit) async {
    if (_settings.backendMode != BackendMode.gptLive || activeBackendMode != BackendMode.gptLive) return false;
    _liveLimit = limit;
    _liveLimitSeen = DateTime.now();
    usage.onUsageLimit(limit);
    debugPrint('gpt-live: ${limit.message}; fallback to Direct ${_settings.fallbackToDirectOnLimit ? 'on' : 'off'}');
    return _settings.fallbackToDirectOnLimit;
  }

  late final SettingsStore _settingsStore = SettingsStore(platform.paths.settingsFile);
  late final HistoryStore history = HistoryStore(platform.paths);

  /// The note of the active conversation (pinned in the model context).
  late final NoteController notes = NoteController(store: NoteStore(platform.paths.dataDir));
  int _pinnedRevision = -1;
  late final ContextManager contextManager;
  late final ToolRegistry tools;
  late final ToolEnvironment toolEnv;

  /// Built-in terminal tabs (Ctrl+3). Nothing runs until the view opens or
  /// the AI runs a command with "Run in terminal" on.
  late final TerminalHub terminals = TerminalHub(workingDirectory: () => platform.files.workspaceDir);

  /// Inline previews of AI note/file edits with the auto-apply countdown.
  late final EditReview review = EditReview(delaySeconds: () => _settings.editApplyDelay);

  /// Applied AI edits ("undo that") and file backups per conversation.
  late final EditHistory editHistory = EditHistory(
    backupRoot: '${platform.paths.dataDir}/backups',
    notes: notes,
    conversationId: () => notes.conversationId,
  );

  /// Every app function, for the UI and the voice tools.
  late final AppActions actions = AppActions(this);
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
      if (platform.audio case final EchoCancellable ec) ec.echoCancellation = _settings.echoCancellation;
      // Woi listens from launch: a mic muted in the last session comes back
      // on (push-to-talk stays push-to-talk).
      if (_settings.micMode == MicMode.muted) {
        _settings = _settings.copyWith(micMode: MicMode.handsFree);
        unawaited(_settingsStore.save(_settings));
      }
      _defaultWorkspace = platform.files.workspaceDir;
      _applyWorkspace();
      await history.init();
      codexAuth = await CodexAuthInfo.load(path: authManager.path);
      _needsLogin = await _checkNeedsLogin();
      final conv = await history.loadLatest() ?? Conversation();
      await notes.open(conv.id);
      notes.onSaved = _onNoteSaved;

      contextManager = ContextManager(
        compressor: compressor,
        threshold: _settings.compressionThreshold,
        compressionModel: compactionChoice.model,
        imageTokenCost: _settings.imageTokenCost,
      );
      contextManager.pinnedTokens = pinnedNoteTokens(notes.text);
      _pinnedRevision = notes.revision;
      notes.addListener(_onNoteChanged);

      late final TurnPipeline p;
      toolEnv = ToolEnvironment(
        platform: platform,
        // File writes: inline diff card + countdown + backup; bash keeps the dialog.
        confirmations: ReviewingConfirmations(inner: confirmations, review: review, history: editHistory),
        delegate: delegate,
        settings: () => _settings,
        onScreenshot: (shot, note) => p.attachScreenshot(shot, note: note),
        terminalShell: TerminalShell(terminals),
      );
      tools = ToolRegistry()
        // send_keys supersedes key_combo (targets the user's app, not Woi).
        ..registerAll(builtinTools(toolEnv).where((t) => t.name != 'key_combo'))
        ..register(sendKeysTool(platform.input, phone: platform.isMobile))
        ..registerAll(noteTools(notes, review: review, history: editHistory))
        ..registerAll(appTools(actions))
        ..registerAll(
          mediaTools(MediaToolsHost(setCamera: setCamera, cameraOn: () => cameraOn, inspectMedia: inspectMedia)),
        );

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
        onTurnStart: () => unawaited(platform.input.rememberTargetWindow()),
        localCommand: _localCommand,
        imageCompactor: ImageCompactor(
          downscale: uiDownscale,
          describe: responsesDescriber(responses, model: () => compactionChoice.model),
          save: history.saveImage,
        ),
      );
      p
        ..cameraImage = _cameraImage
        ..beforeTypedTurn = _beforeTypedTurn
        ..onUsageLimit = _onUsageLimit;
      pipeline = p;
      _ready = true;
      ResponsesClient.onQuotaHeaders = usage.updateFromHeaders;
      usage.addListener(_onUsageChanged);
      _syncUsagePolling();
      notifyListeners();
      // Without credentials the voice session cannot connect: wait for the
      // login screen.
      if (!_needsLogin) await _startPipeline();
    } catch (e, st) {
      initError = e;
      debugPrint('init failed: $e\n$st');
      notifyListeners();
    }
  }

  bool _needsLogin = false;
  bool _pipelineStarted = false;

  /// No usable ChatGPT login and no API key: the UI shows the login screen.
  bool get needsLogin => _needsLogin;

  Future<bool> _checkNeedsLogin() async {
    // An injected backend (tests, demos) needs no credentials.
    if (_backendOverride != null) return false;
    final key = _settings.apiKey.trim().isNotEmpty || (Platform.environment['OPENAI_API_KEY'] ?? '').trim().isNotEmpty;
    if (key) return false;
    return !await hasValidCodexAuth(authManager.path);
  }

  Future<void> _startPipeline() async {
    if (_pipelineStarted) return;
    _pipelineStarted = true;
    await pipeline.start();
  }

  /// A login flow writing to the configured auth.json (never replacing a
  /// valid one).
  PkceLoginFlow createLoginFlow({PlatformUrlOpener? opener}) =>
      PkceLoginFlow(authPath: authManager.path, opener: opener ?? platform.urlOpener);

  /// Called by the login screen after "Sign in with ChatGPT" succeeded.
  Future<void> completeChatGptLogin() async {
    codexAuth = await CodexAuthInfo.load(path: authManager.path);
    _needsLogin = false;
    await _afterLogin(
      _settings.backendMode == BackendMode.apiKey ? _settings.copyWith(backendMode: BackendMode.gptLive) : _settings,
    );
  }

  /// Called by the login screen's "Use OpenAI API key" option.
  Future<void> useApiKey(String key) async {
    _needsLogin = false;
    await _afterLogin(_settings.copyWith(backendMode: BackendMode.apiKey, apiKey: key.trim()));
  }

  Future<void> _afterLogin(AppSettings next) async {
    _syncUsagePolling();
    notifyListeners();
    if (!_pipelineStarted) {
      _settings = next;
      notifyListeners();
      await _settingsStore.save(next);
      await _startPipeline();
    } else {
      await updateSettings(next);
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
    autoScreenshot: _settings.autoScreenshot && platform.autoScreenshot(),
    screenshotDelay: Duration(milliseconds: _settings.screenshotDelayMs),
    micMode: _settings.micMode,
    thinkingEarcon: _settings.thinkingEarcon,
    cameraReplacesScreenshot: _settings.cameraReplacesScreenshot,
    onsetMicWithManagedAudio: !platform.isMobile,
    bargeInFloor: platform.isMobile && _settings.echoCancellation ? 0.05 : 0.02,
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
      voice: activeBackendMode == BackendMode.gptLive ? _settings.liveVoice : _settings.voice,
      instructions: [
        kAssistantInstructions,
        if (activeBackendMode == BackendMode.gptLive) kLiveInstructions,
        kCameraMediaInstructions,
        if (activeBackendMode == BackendMode.gptLive) kLiveCameraMediaInstructions,
        environmentNote(),
      ].join('\n'),
      tools: tools.specs,
      credentials: creds,
      priorContext: c.summary,
      recentContext: contextManager.recentTurns(),
      environment: environmentNote(),
      phone: platform.isMobile,
      pinnedNote: notes.text,
    );
  }

  /// Keeps the pinned note current in the context meter and the live session.
  void _onNoteChanged() {
    if (notes.revision == _pinnedRevision) return;
    _pinnedRevision = notes.revision;
    contextManager.pinnedTokens = pinnedNoteTokens(notes.text);
    final Object? b = pipeline.backend;
    if (b is PinnedNoteSync) b.setPinnedNote(notes.text);
  }

  /// A conversation that only has a note is saved too, so it is listed in
  /// the history (titled after the note).
  void _onNoteSaved(Note n) {
    if (!_ready) return;
    final conv = pipeline.conversation;
    if (n.conversationId != conv.id) return;
    if (conv.messages.isEmpty && !conv.customTitle) conv.title = noteTitle(n.markdown);
    conv.updatedAt = DateTime.now();
    history.saveSoon(conv);
  }

  Future<void> updateSettings(AppSettings next) async {
    final prev = _settings;
    _settings = next;
    contextManager
      ..threshold = next.compressionThreshold
      ..compressionModel = compactionChoice.model
      ..imageTokenCost = next.imageTokenCost;
    if (next.workspaceDir != prev.workspaceDir) _applyWorkspace();
    _syncUsagePolling();
    if (next.usageGuardPercent != prev.usageGuardPercent) _usageLowNoticed = false;
    notifyListeners();
    await _settingsStore.save(next);
    if (next.echoCancellation != prev.echoCancellation) await _applyEchoCancellation(prev);
    if (next.micMode != prev.micMode) {
      await pipeline.setMicMode(next.micMode);
      if (_inBackground) _scheduleBackgroundSuspend();
    }
    if (prev.sessionDiffers(next)) {
      await pipeline.connect();
    } else if (next.fallbackToDirectOnLimit && !prev.fallbackToDirectOnLimit && pipeline.usageLimit != null) {
      // Turned on while gpt-live is at its limit: switch now.
      await pipeline.connect();
    }
    contextManager.onConversationChanged();
  }

  Future<void> setMicMode(MicMode mode) => updateSettings(_settings.copyWith(micMode: mode));

  /// Applies [AppSettings.echoCancellation]: the platform canceller takes it
  /// on the next mic open (reopened now); gpt-live's WebRTC mic needs a new
  /// call.
  Future<void> _applyEchoCancellation(AppSettings prev) async {
    if (platform.audio case final EchoCancellable ec) ec.echoCancellation = _settings.echoCancellation;
    if (prev.sessionDiffers(_settings)) return; // reconnecting anyway
    if (pipeline.backendManagesAudio) {
      await pipeline.connect();
    } else {
      await pipeline.reopenMic();
    }
  }

  Future<void> refreshCodexAuth() async {
    codexAuth = await CodexAuthInfo.load(path: authManager.path);
    _syncUsagePolling();
    notifyListeners();
  }

  Future<List<ConversationSummary>> listConversations() => history.list();

  Future<void> newConversation() async {
    if (pipeline.conversation.messages.isEmpty && notes.isEmpty) return;
    review.rejectAll();
    final c = Conversation();
    await notes.open(c.id);
    await pipeline.switchConversation(c);
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (id == pipeline.conversation.id) return;
    final c = await history.load(id);
    if (c == null) return;
    review.rejectAll();
    await notes.open(c.id);
    await pipeline.switchConversation(c);
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    await notes.deleteFor(id);
    if (id == pipeline.conversation.id) {
      review.rejectAll();
      final c = Conversation();
      await notes.open(c.id);
      await pipeline.switchConversation(c);
    }
    await history.delete(id);
    notifyListeners();
  }

  /// "apply" / "reject" while an edit preview is shown; typed "undo that"
  /// (spoken undo goes to the model, which may also be delegating it).
  bool _localCommand(String text, {required bool typed}) {
    final cmd = parseEditCommand(text, pending: review.hasPending);
    switch (cmd) {
      case EditVoiceCommand.apply:
        return review.apply();
      case EditVoiceCommand.reject:
        return review.reject();
      case EditVoiceCommand.undo:
        if (!typed || (!review.hasPending && editHistory.last == null)) return false;
        unawaited(
          actions.undoLastEdit().then(
            (r) => debugPrint('undo: $r'),
            onError: (Object e) => debugPrint('undo failed: $e'),
          ),
        );
        return true;
      case null:
        return false;
    }
  }

  /// Renames a conversation (= its note tab).
  Future<void> renameConversation(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    final c = id == pipeline.conversation.id ? pipeline.conversation : await history.load(id);
    if (c == null) return;
    c
      ..title = t
      ..customTitle = true;
    await history.save(c);
    notifyListeners();
  }

  // ---------------------------------------------------------------- camera

  CameraService get camera => platform.camera;
  bool get cameraOn => camera.active.value;
  bool _cameraBusy = false;

  /// Camera open/close in progress (the UI toggle shows a spinner).
  bool get cameraBusy => _cameraBusy;

  ContextImage? _cameraImage() {
    final f = camera.latest();
    return f == null ? null : ContextImage.camera(f, when: 'when the user spoke');
  }

  /// Turns the camera on/off (tool, delegation fast path, input bar toggle).
  /// Opening attaches the first frame right away so the model can look at
  /// once. Returns the tool result.
  Future<Map<String, Object?>> setCamera(bool on) async {
    if (on == cameraOn && !_cameraBusy) {
      return {'ok': true, 'on': on, 'note': 'camera already ${on ? 'on' : 'off'}'};
    }
    _cameraBusy = true;
    notifyListeners();
    try {
      if (on) {
        await camera.open();
        final f = await camera.nextFrame();
        if (f != null && _ready) {
          pipeline.attachContextImage(ContextImage.camera(f, when: 'just after the camera was opened'));
        }
        return {
          'ok': true,
          'on': true,
          if (f != null) 'frame': '${f.width}x${f.height} attached; a new frame comes with every user turn',
        };
      }
      await camera.close();
      if (_ready) pipeline.clearContextImage(ContextImageKind.camera);
      return {'ok': true, 'on': false};
    } on CameraException catch (e) {
      if (_ready) pipeline.notice('Camera: ${e.message}');
      return {'ok': false, 'error': e.message};
    } finally {
      _cameraBusy = false;
      notifyListeners();
    }
  }

  Future<void> toggleCamera() => setCamera(!cameraOn);

  // ---------------------------------------------------------- media context

  /// What is open in the viewer (refreshed whenever the media is inspected).
  final ValueNotifier<ViewerState?> openMedia = ValueNotifier(null);

  late final MediaContextService media = MediaContextService(
    viewer: platform.viewer,
    grabber: platform.mediaGrab,
    describeAudio: realtimeAudioDescriber(credentials: credentials, model: () => _settings.realtimeModel),
  );

  /// The viewer's current item, also kept in [openMedia].
  Future<ViewerState?> refreshOpenMedia() async {
    final s = await media.current();
    openMedia.value = s;
    return s;
  }

  /// `inspect_media`: attaches the open item's content to the conversation.
  Future<Map<String, Object?>> inspectMedia(String? question) async {
    final s = await refreshOpenMedia();
    if (s == null) return {'ok': false, 'error': 'nothing is open in the viewer'};
    final ctx = await media.grab(state: s, question: question);
    if (ctx == null) return {'ok': false, 'error': 'nothing is open in the viewer'};
    final img = ctx.image;
    if (img != null && _ready) pipeline.attachContextImage(img);
    if (img == null && _ready) pipeline.notice(ctx.summary);
    return ctx.toToolResult();
  }

  /// Typed "what's in this image": the media goes out with the turn.
  Future<String?>? _beforeTypedTurn(String text) {
    // gpt-live: the delegation runs inspect_media itself before answering.
    if (activeBackendMode == BackendMode.gptLive || !isMediaQuestion(text)) return null;
    return () async {
      final s = await refreshOpenMedia();
      if (s == null) return null;
      final r = await inspectMedia(text);
      if (r['ok'] != true) return null;
      final content = r['content'];
      return [
        text,
        '',
        '[Woi attached the media open in the viewer for this question (${r['summary']}); do not call inspect_media.]',
        if (content is String && content.isNotEmpty) 'Media content: $content',
      ].join('\n');
    }();
  }

  // ------------------------------------------------------------- lifecycle

  bool _inBackground = false;

  /// Desktop window hidden/minimized (only pauses the usage polling).
  bool _windowHidden = false;
  Timer? _backgroundTimer;

  /// How long a phone app may sit in the background, muted or offline,
  /// before the voice session is suspended (no WebRTC audio threads, no
  /// sockets, no timers). Quick app switches keep the session.
  Duration backgroundSuspendDelay = const Duration(seconds: 15);

  /// App lifecycle (phones). Paused: the camera closes (Android denies it in
  /// the background anyway) and a muted or offline session is suspended
  /// after [backgroundSuspendDelay]. A hands-free session keeps listening
  /// (the foreground service). Resumed: a suspended session reconnects.
  void onLifecycle(AppLifecycleState state) {
    if (!_ready) return;
    if (!platform.isMobile) {
      // Desktop: only the usage polling pauses while the window is hidden.
      _windowHidden = state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
      _syncUsagePolling();
      return;
    }
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_inBackground) return;
        _inBackground = true;
        _syncUsagePolling();
        if (cameraOn) unawaited(setCamera(false));
        _scheduleBackgroundSuspend();
      case AppLifecycleState.resumed:
        _inBackground = false;
        _syncUsagePolling();
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        if (pipeline.suspended && !_needsLogin) unawaited(pipeline.resume());
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// How long a dismissed assistant panel keeps the voice session.
  Duration assistantIdleDelay = const Duration(seconds: 3);
  Timer? _assistantTimer;

  /// The floating assistant panel (Android) was dismissed: stop talking now
  /// and drop the voice session shortly after (no mic, no network: idle CPU
  /// back to ~0) unless the panel or the app comes back first. The mic mode
  /// setting is unchanged; the next invocation reconnects.
  void assistantDismissed() {
    if (!_ready) return;
    final ph = pipeline.phase;
    if (ph == AssistantPhase.speaking || ph == AssistantPhase.thinking) pipeline.interrupt();
    _assistantTimer?.cancel();
    _assistantTimer = Timer(assistantIdleDelay, () {
      _assistantTimer = null;
      if (_inBackground && _ready) unawaited(pipeline.suspend());
    });
  }

  void _scheduleBackgroundSuspend() {
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(backgroundSuspendDelay, () {
      _backgroundTimer = null;
      if (!_inBackground || !_ready) return;
      final idle = _settings.micMode == MicMode.muted || pipeline.status != SessionStatus.connected;
      if (idle) unawaited(pipeline.suspend());
    });
  }

  /// Manual compaction from the UI.
  void compactNow() => contextManager.maybeCompress(force: true);

  Future<void> shutdown() async {
    _backgroundTimer?.cancel();
    _assistantTimer?.cancel();
    usage.setActive(false);
    if (ResponsesClient.onQuotaHeaders == usage.updateFromHeaders) ResponsesClient.onQuotaHeaders = null;
    await camera.close();
    await notes.flush();
    if (_ready) await pipeline.shutdown();
    if (platform.audio case final EchoCancellable ec) await ec.disposeEchoCancellation();
    terminals.dispose();
  }
}
