import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';
import '../../platform/screen_capture.dart';
import '../../tools/tool_registry.dart';
import '../audio/earcon.dart';
import '../audio/wav.dart';
import '../context/context_manager.dart';
import '../models/message.dart';
import '../settings/settings.dart';
import '../storage/history_store.dart';
import '../voice/context_sync.dart';
import '../voice/delegation_executor.dart';
import '../voice/voice_backend.dart';
import 'vad.dart';

enum SessionStatus { disconnected, connecting, connected, error }

enum AssistantPhase { offline, idle, listening, userSpeaking, thinking, toolRunning, speaking }

/// Fixed context of a session: instructions and tool definitions, plus the
/// delegation prompt for gpt-live (whose tools run in a delegation model).
int contextOverhead(SessionConfig cfg, ContextAccounting accounting) {
  var t = ContextManager.textTokens(cfg.instructions);
  t += ContextManager.textTokens(jsonEncode([for (final s in cfg.tools) s.toJson()]));
  if (accounting == ContextAccounting.textEstimate) {
    t += ContextManager.textTokens(DelegationExecutor.instructions);
  }
  return t;
}

/// Runtime knobs read on every turn (backed by AppSettings in the app).
class PipelineOptions {
  const PipelineOptions({
    this.autoScreenshot = true,
    this.screenshotDelay = const Duration(milliseconds: 1200),
    this.maxScreenshotWidth = 1280,
    this.micMode = MicMode.handsFree,
    this.thinkingEarcon = false,
  });
  final bool autoScreenshot;
  final Duration screenshotDelay;
  final int maxScreenshotWidth;
  final MicMode micMode;

  /// Play [thinkingEarconPcm] when the user stops speaking and the reply
  /// has not started yet.
  final bool thinkingEarcon;
}

typedef SessionConfigBuilder = Future<SessionConfig> Function(Conversation c);

/// The live loop: mic → backend, backend events → conversation/playback/tools,
/// speech-triggered screenshots, barge-in, and context tracking.
class TurnPipeline extends ChangeNotifier {
  TurnPipeline({
    required this.backendFactory,
    required this.audio,
    required this.screen,
    required this.tools,
    required this.context,
    required this.store,
    required Conversation conversation,
    required this.sessionConfig,
    required this.options,
    this.onScreenshotCaptured,
  }) : _conv = conversation {
    context.attach(conversation);
    _compactionSub = context.compactions.listen(_onCompacted);
  }

  final VoiceBackend Function() backendFactory;
  final AudioIO audio;
  final ScreenCapture screen;
  final ToolRegistry tools;
  final ContextManager context;
  final HistoryStore store;
  final SessionConfigBuilder sessionConfig;
  PipelineOptions Function() options;
  void Function(Screenshot shot)? onScreenshotCaptured;

  Conversation _conv;
  VoiceBackend? _backend;
  StreamSubscription<BackendEvent>? _eventSub;
  StreamSubscription<ContextCompacted>? _compactionSub;
  MicStream? _mic;
  StreamSubscription<Uint8List>? _micSub;
  PcmPlayer? _player;
  final _levelsChanged = ValueNotifier<int>(0);

  SessionStatus _status = SessionStatus.disconnected;
  String? statusDetail;
  MicMode _micMode = MicMode.handsFree;
  bool _pttHeld = false;

  // Turn state
  bool _userSpeaking = false;
  Message? _currentUtterance;
  final PcmBuffer _utterancePcm = PcmBuffer();
  final PcmRing _preRoll = PcmRing(kVoiceBytesPerSecond * 3 ~/ 10); // 300 ms
  final List<Message> _awaitingTranscript = [];
  // User turn id (backend item id) → its message, so late transcripts and
  // resumed speech land in the right message.
  final Map<String, Message> _userByItem = {};
  // Audio of the latest utterance, kept so a resumed turn gets one clip.
  String? _lastUtteranceId;
  Uint8List? _lastUtterancePcm;
  final Set<String> _screenshotStarted = {};
  Timer? _screenshotTimer;
  Timer? _earconTimer;
  PcmPlayer? _earconPlayer;
  Message? _assistantMsg;
  final PcmBuffer _assistantPcm = PcmBuffer();
  bool _awaitingResponse = false;
  bool _discardUntilDone = false;
  int _toolsRunning = 0;
  final EnergyVad _localVad = EnergyVad();
  Timer? _phaseTicker;
  AssistantPhase _lastPhase = AssistantPhase.offline;

  /// Counters for diagnostics/tests.
  int bargeIns = 0;
  int screenshotsSent = 0;

  final _compactionEvents = StreamController<ContextCompacted>.broadcast();
  Stream<ContextCompacted> get compactionEvents => _compactionEvents.stream;

  Conversation get conversation => _conv;
  SessionStatus get status => _status;
  MicMode get micMode => _micMode;
  bool get pttHeld => _pttHeld;
  VoiceBackend? get backend => _backend;

  ValueListenable<double>? get micLevel => _mic?.level;
  ValueListenable<double>? get outputLevel => _out?.level;

  /// Backend that captures/plays audio itself (WebRTC); null for PCM backends.
  ManagedAudioBackend? get _managed {
    final b = _backend;
    return b is ManagedAudioBackend ? b as ManagedAudioBackend : null;
  }

  /// Where assistant audio goes: the managed backend's level tracker (audio
  /// already audible via WebRTC) or the platform player.
  PcmPlayer? get _out => _managed?.managedPlayer ?? _player;
  bool _micManaged = false;

  /// Bumps when the mic or player (and so the level listenables) change.
  ValueListenable<int> get levelSourcesChanged => _levelsChanged;

  bool get _assistantAudible => _out?.isPlaying ?? false;

  AssistantPhase get phase {
    if (_status != SessionStatus.connected) return AssistantPhase.offline;
    if (_userSpeaking) return AssistantPhase.userSpeaking;
    if (_toolsRunning > 0) return AssistantPhase.toolRunning;
    if (_assistantAudible || (_assistantMsg?.streaming ?? false)) return AssistantPhase.speaking;
    if (_awaitingResponse) return AssistantPhase.thinking;
    return _micMode == MicMode.muted ? AssistantPhase.idle : AssistantPhase.listening;
  }

  bool _disposed = false;

  void _changed() {
    if (_disposed) return;
    _lastPhase = phase;
    notifyListeners();
  }

  // ---------------------------------------------------------------- session

  Future<void> start() async {
    _player ??= await audio.openPlayer();
    _levelsChanged.value++;
    await connect();
    await setMicMode(options().micMode);
    _phaseTicker ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (phase != _lastPhase) _changed();
    });
  }

  Future<void> connect() async {
    if (_micManaged) await _closeMic();
    await _disconnectBackend();
    _status = SessionStatus.connecting;
    statusDetail = null;
    _changed();
    final b = backendFactory();
    _backend = b;
    _eventSub = b.events.listen(
      _onEvent,
      onError: (Object e) {
        _addSystem('Voice backend error: $e', meta: {'type': 'error'});
      },
    );
    try {
      final cfg = await sessionConfig(_conv);
      context.configure(accounting: b.contextAccounting, overheadTokens: contextOverhead(cfg, b.contextAccounting));
      await b.connect(cfg);
      if (!identical(_backend, b)) return;
      _status = SessionStatus.connected;
      if (b is ManagedAudioBackend) {
        // The backend owns the mic: swap the platform capture for its stream.
        await _closeMic();
        if (_micMode != MicMode.muted) await _openMic();
        _levelsChanged.value++;
      }
    } catch (e) {
      _status = SessionStatus.error;
      statusDetail = '$e';
    }
    _changed();
  }

  Future<void> _disconnectBackend() async {
    _resetTurnState();
    await _eventSub?.cancel();
    _eventSub = null;
    final b = _backend;
    _backend = null;
    if (b != null) {
      try {
        await b.close();
      } catch (_) {}
    }
    _status = SessionStatus.disconnected;
  }

  void _resetTurnState() {
    _earconTimer?.cancel();
    _earconTimer = null;
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _userSpeaking = false;
    _currentUtterance?.streaming = false;
    _currentUtterance = null;
    _utterancePcm.clear();
    _awaitingTranscript.clear();
    _userByItem.clear();
    _lastUtteranceId = null;
    _lastUtterancePcm = null;
    _finishAssistant(interrupted: _assistantMsg != null);
    _awaitingResponse = false;
    _discardUntilDone = false;
    _localVad.reset();
    _out?.stop();
  }

  /// Switches to another conversation; reconnects so the model gets its
  /// context (summary) fresh.
  Future<void> switchConversation(Conversation c) async {
    if (_conv.messages.isNotEmpty) await store.save(_conv);
    _conv = c;
    context.attach(c);
    _changed();
    if (_status != SessionStatus.disconnected || _backend != null) await connect();
  }

  // -------------------------------------------------------------------- mic

  Future<void> setMicMode(MicMode mode) async {
    _micMode = mode;
    _pttHeld = false;
    if (mode == MicMode.muted) {
      await _closeMic();
      if (_userSpeaking) _onSpeechStopped();
    } else {
      await _openMic();
      _managed?.setInputEnabled(_forwarding);
    }
    _changed();
  }

  Future<void> _openMic() async {
    if (_mic != null) return;
    try {
      final managed = _managed;
      final mic = managed != null ? await managed.openManagedMic() : await audio.openMic();
      _micManaged = managed != null;
      managed?.setInputEnabled(_forwarding);
      _mic = mic;
      _micSub = mic.chunks.listen(_onMicChunk);
      _levelsChanged.value++;
    } catch (e) {
      _addSystem('Microphone unavailable: $e', meta: {'type': 'error'});
    }
  }

  Future<void> _closeMic() async {
    await _micSub?.cancel();
    _micSub = null;
    final m = _mic;
    _mic = null;
    _micManaged = false;
    await m?.close();
    _levelsChanged.value++;
  }

  bool get _forwarding => _micMode == MicMode.handsFree || (_micMode == MicMode.pushToTalk && _pttHeld);

  void _onMicChunk(Uint8List chunk) {
    final b = _backend;
    if (b == null || _status != SessionStatus.connected || !_forwarding) return;
    if (!_micManaged) b.sendAudio(chunk);
    if (_userSpeaking) {
      _utterancePcm.add(chunk);
    } else {
      _preRoll.add(chunk);
    }
    if (!b.hasServerVad && _micMode == MicMode.handsFree) {
      _localVad.sensitivityScale = _assistantAudible ? 2.5 : 1.0;
      switch (_localVad.process(chunk)) {
        case VadEvent.speechStarted:
          _onSpeechStarted();
        case VadEvent.speechStopped:
          _onSpeechStopped();
        case null:
      }
    }
  }

  /// Push-to-talk pressed.
  void pttDown() {
    if (_micMode != MicMode.pushToTalk || _pttHeld) return;
    _pttHeld = true;
    _managed?.setInputEnabled(true);
    // Holding the talk button is an explicit interruption.
    _bargeIn();
    if (!(_backend?.hasServerVad ?? true)) _onSpeechStarted();
    _changed();
  }

  /// Push-to-talk released.
  void pttUp() {
    if (!_pttHeld) return;
    _pttHeld = false;
    _managed?.setInputEnabled(false);
    final b = _backend;
    if (b != null && _status == SessionStatus.connected) {
      // Trailing silence lets server VAD close the turn promptly.
      b.sendAudio(Uint8List(kVoiceBytesPerSecond * 8 ~/ 10));
      if (!b.hasServerVad) _onSpeechStopped();
    }
    _changed();
  }

  // ------------------------------------------------------------ user turns

  void _bargeIn() {
    final speaking = _assistantAudible || _assistantMsg != null;
    if (!speaking) return;
    bargeIns++;
    _out?.stop();
    if (_assistantMsg != null) {
      _backend?.cancelResponse();
      _discardUntilDone = true;
    }
    _finishAssistant(interrupted: true);
  }

  void _onSpeechStarted({String? itemId}) {
    if (_userSpeaking) return;
    _earconTimer?.cancel();
    _earconTimer = null;
    _bargeIn();
    _userSpeaking = true;
    _utterancePcm.clear();
    // A known item id continues that turn (the backend saw one turn across a
    // pause): keep one message with one clip and one screenshot.
    final resumed = itemId == null ? null : _userByItem[itemId];
    final msg = resumed != null && _conv.messages.contains(resumed)
        ? resumed
        : Message(kind: MessageKind.user, streaming: true);
    if (identical(msg, resumed)) {
      msg.streaming = true;
      final prev = _lastUtteranceId == msg.id ? _lastUtterancePcm : null;
      if (prev != null) _utterancePcm.add(prev);
      if (!_awaitingTranscript.contains(msg)) _awaitingTranscript.add(msg);
    } else {
      if (itemId != null) _userByItem[itemId] = msg;
      _awaitingTranscript.add(msg);
      _addMessage(msg);
    }
    _utterancePcm.add(_preRoll.drain());
    _currentUtterance = msg;
    final opts = options();
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    if (opts.autoScreenshot && msg.image == null && !_screenshotStarted.contains(msg.id)) {
      _screenshotTimer = Timer(opts.screenshotDelay, () {
        _screenshotTimer = null;
        _captureFor(msg);
      });
    }
    _changed();
  }

  /// Optional latency mask: a soft chime shortly after the end of speech,
  /// unless the reply already started (or the user resumed). Played on its
  /// own player so it never counts as assistant audio.
  void _scheduleThinkingEarcon() {
    if (!options().thinkingEarcon) return;
    _earconTimer?.cancel();
    _earconTimer = Timer(const Duration(milliseconds: 120), () async {
      _earconTimer = null;
      if (_disposed || phase != AssistantPhase.thinking) return;
      try {
        final p = _earconPlayer ??= await audio.openPlayer();
        if (!_disposed) p.write(thinkingEarconPcm());
        earconsPlayed++;
      } catch (e) {
        debugPrint('thinking earcon: $e');
      }
    });
  }

  /// Number of thinking earcons played (tests/diagnostics).
  int earconsPlayed = 0;

  void _onSpeechStopped() {
    if (!_userSpeaking) return;
    _userSpeaking = false;
    // The orb switches to "thinking" right here, before any server event.
    _awaitingResponse = true;
    _scheduleThinkingEarcon();
    final msg = _currentUtterance;
    _currentUtterance = null;
    // Utterance shorter than the delay: grab the screen now so the image
    // still arrives with the turn.
    if (_screenshotTimer != null && msg != null) {
      _screenshotTimer!.cancel();
      _screenshotTimer = null;
      _captureFor(msg);
    }
    final pcm = _utterancePcm.takeBytes();
    if (msg != null) {
      _lastUtteranceId = msg.id;
      _lastUtterancePcm = pcm;
    }
    if (msg != null && pcm.isNotEmpty) {
      store
          .saveAudio(msg.id, pcm)
          .then((clip) {
            msg.audio = clip;
            _persistSoon();
            context.onConversationChanged();
            _changed();
          })
          .catchError((Object e) {
            debugPrint('saving utterance failed: $e');
          });
    }
    _changed();
  }

  Future<void> _captureFor(Message msg) async {
    _screenshotStarted.add(msg.id);
    try {
      final shot = await screen.capture(maxWidth: options().maxScreenshotWidth);
      await attachScreenshot(shot, note: 'Screen when the user spoke.', to: msg);
    } catch (e) {
      _addSystem('Screenshot failed: $e', meta: {'type': 'error'});
    }
  }

  /// Saves [shot], attaches it to [to] (or a new system message) and sends
  /// it to the model.
  Future<void> attachScreenshot(Screenshot shot, {required String note, Message? to}) async {
    onScreenshotCaptured?.call(shot);
    final target = to ?? _addMessage(Message(kind: MessageKind.system, text: note, meta: {'type': 'screenshot'}));
    final path = await store.saveImage(target.id, shot.png);
    target.image = ImageAttachment(
      path: path,
      width: shot.width,
      height: shot.height,
      originalWidth: shot.originalWidth,
      originalHeight: shot.originalHeight,
    );
    _backend?.sendImage(
      shot.png,
      note:
          '$note Image is ${shot.width}x${shot.height} of a '
          '${shot.originalWidth}x${shot.originalHeight} screen; '
          'click_screen uses image pixel coordinates.',
    );
    screenshotsSent++;
    context.onConversationChanged();
    _persistSoon();
    _changed();
  }

  /// Typed input (text fallback).
  void sendText(String text) {
    final t = text.trim();
    final b = _backend;
    if (t.isEmpty || b == null || _status != SessionStatus.connected) return;
    _bargeIn();
    _addMessage(Message(kind: MessageKind.user, text: t));
    _conv.touch();
    _awaitingResponse = true;
    b.sendText(t);
    _persistSoon();
    _changed();
  }

  /// Stops the assistant (button / Esc).
  void interrupt() {
    _bargeIn();
    _awaitingResponse = false;
    _changed();
  }

  // ---------------------------------------------------------------- events

  void _onEvent(BackendEvent e) {
    try {
      _handle(e);
    } catch (err, st) {
      debugPrint('pipeline event error: $err\n$st');
    }
  }

  void _handle(BackendEvent e) {
    switch (e) {
      case SpeechStarted(:final itemId):
        _onSpeechStarted(itemId: itemId);
      case SpeechStopped():
        _onSpeechStopped();
      case UserTranscriptDelta(:final text, :final itemId):
        final m = _userForTranscript(itemId);
        m.text += text;
        _persistSoon();
        _changed();
      case UserTranscriptDone(:final text, :final itemId, :final noSpeech):
        final m = _userForTranscript(itemId);
        if (text.isNotEmpty) m.text = text;
        _awaitingTranscript.remove(m);
        if (!identical(m, _currentUtterance)) m.streaming = false;
        if (noSpeech && m.text.isEmpty && m.image == null && !identical(m, _currentUtterance)) {
          // The server never heard a user turn here (echo/noise picked up
          // by the local VAD): drop the empty bubble.
          _conv.messages.remove(m);
          _userByItem.removeWhere((_, v) => identical(v, m));
        }
        _conv.touch();
        context.onConversationChanged();
        _persistSoon();
        _changed();
      case AssistantTranscriptDelta(:final text):
        if (_discardUntilDone) return;
        _assistant().text += text;
        _awaitingResponse = false;
        _persistSoon();
        _changed();
      case AssistantTranscriptDone(:final text):
        if (_discardUntilDone) return;
        if (text.isNotEmpty) _assistant().text = text;
        _changed();
      case AssistantAudioDelta(:final pcm16):
        if (_discardUntilDone || _userSpeaking) return;
        _assistant();
        _awaitingResponse = false;
        _out?.write(pcm16);
        _assistantPcm.add(pcm16);
      case ToolCall(:final callId, :final name, :final argsJson):
        _runTool(callId, name, argsJson);
      case Usage(:final totalContextTokens):
        context.onUsage(totalContextTokens);
      case BackendError(:final message, :final fatal):
        _addSystem(message, meta: {'type': 'error'});
        if (fatal) {
          _status = SessionStatus.error;
          statusDetail = message;
        }
        _awaitingResponse = false;
        _changed();
      case ResponseDone():
        if (_discardUntilDone) {
          _discardUntilDone = false;
          return;
        }
        _finishAssistant();
        if (_toolsRunning == 0) _awaitingResponse = false;
        _changed();
    }
  }

  /// The user message a transcript belongs to: the one bound to [itemId],
  /// else the oldest unbound one still waiting (speech_started without an id,
  /// or a missed event), else a new message.
  Message _userForTranscript(String? itemId) {
    if (itemId != null) {
      final bound = _userByItem[itemId];
      if (bound != null && _conv.messages.contains(bound)) return bound;
      final bindable = _awaitingTranscript.where((m) => !_userByItem.containsValue(m));
      if (bindable.isNotEmpty) return _userByItem[itemId] = bindable.first;
    } else if (_awaitingTranscript.isNotEmpty) {
      return _awaitingTranscript.first;
    }
    final m = Message(kind: MessageKind.user, streaming: true);
    _awaitingTranscript.add(m);
    if (itemId != null) _userByItem[itemId] = m;
    return _addMessage(m);
  }

  Message _assistant() => _assistantMsg ??= _addMessage(Message(kind: MessageKind.assistant, streaming: true));

  void _finishAssistant({bool interrupted = false}) {
    final m = _assistantMsg;
    _assistantMsg = null;
    final pcm = _assistantPcm.takeBytes();
    if (m == null) return;
    m.streaming = false;
    m.interrupted = interrupted;
    if (m.text.isEmpty && pcm.isEmpty) {
      _conv.messages.remove(m);
    } else if (pcm.isNotEmpty) {
      store
          .saveAudio(m.id, pcm)
          .then((clip) {
            m.audio = clip;
            _persistSoon();
            _changed();
          })
          .catchError((Object e) {
            debugPrint('saving reply audio failed: $e');
          });
    }
    context.onConversationChanged();
    _persistSoon();
  }

  Future<void> _runTool(String callId, String name, String argsJson) async {
    final info = ToolCallInfo(callId: callId, name: name, argsJson: argsJson);
    _addMessage(Message(kind: MessageKind.tool, tool: info));
    _toolsRunning++;
    _awaitingResponse = true;
    _changed();
    final b = _backend;
    final outcome = await tools.dispatch(
      name,
      argsJson,
      callId: callId,
      onStatus: (s) {
        info.status = s;
        _changed();
      },
    );
    info.status = outcome.status;
    info.resultJson = outcome.json;
    info.finishedAt = DateTime.now();
    _toolsRunning--;
    if (_disposed) return;
    if (identical(b, _backend)) b?.sendToolResult(callId, outcome.json);
    context.onConversationChanged();
    await _persistNow();
    _changed();
  }

  // ------------------------------------------------------------ context

  void _onCompacted(ContextCompacted c) {
    if (_disposed) return;
    final images = c.describedImages == 0
        ? ''
        : ', ${c.describedImages} screenshot${c.describedImages == 1 ? '' : 's'} replaced by descriptions';
    _addSystem(
      'Context compacted: ${formatTokenCount(c.tokensBefore)} → ${formatTokenCount(c.tokensAfter)} tokens '
      '(${c.compactedMessages} messages summarised$images)',
      meta: {'type': 'compaction', 'before': c.tokensBefore, 'after': c.tokensAfter},
    );
    _compactionEvents.add(c);
    _persistNow();
    _applyCompactionToSession(c);
  }

  /// Replaces the compacted turns in the live session too. The backend
  /// defers this to the next moment with no active response, so it never
  /// interrupts playback or a reply.
  void _applyCompactionToSession(ContextCompacted c) {
    final Object? b = _backend;
    if (b is! LiveContextSync) return;
    b
        .applySummary(c.summary, recentTurns: context.recentTurns())
        .then((r) {
          lastContextApply = r;
          debugPrint('compaction applied to live session: $r');
          if (r.method == ContextApplyMethod.reconnected) {
            notice('Voice session restarted with the compacted context.');
          }
        })
        .catchError((Object e) {
          debugPrint('applying compaction to the live session failed: $e');
        });
  }

  /// Result of the last [LiveContextSync.applySummary] (diagnostics/tests).
  ContextApplyResult? lastContextApply;

  /// Shows an informational line in the conversation (e.g. backend fallback).
  void notice(String text) {
    if (_disposed) return;
    _addSystem(text, meta: {'type': 'notice'});
  }

  // ------------------------------------------------------------ helpers

  Message _addMessage(Message m) {
    _conv.add(m);
    context.onConversationChanged();
    _persistSoon();
    return m;
  }

  Message _addSystem(String text, {Map<String, Object?>? meta}) {
    final last = _conv.messages.isEmpty ? null : _conv.messages.last;
    if (last != null && last.kind == MessageKind.system && last.text == text) return last;
    final m = _addMessage(Message(kind: MessageKind.system, text: text, meta: meta));
    _changed();
    return m;
  }

  void _persistSoon() => store.saveSoon(_conv);
  Future<void> _persistNow() =>
      store.save(_conv).catchError((Object e) => debugPrint('saving conversation failed: $e'));

  /// Stops audio, closes the session and flushes history.
  Future<void> shutdown() async {
    _phaseTicker?.cancel();
    _screenshotTimer?.cancel();
    await _compactionSub?.cancel();
    await _closeMic();
    await _disconnectBackend();
    await _player?.close();
    await _earconPlayer?.close();
    await store.flush(_conv);
    await _compactionEvents.close();
    _levelsChanged.dispose();
    _disposed = true;
    dispose();
  }
}
