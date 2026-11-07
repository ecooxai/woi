import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';
import '../audio/playback_clock.dart';
import '../audio/wav.dart';
import '../auth/auth.dart';
import '../context/context_manager.dart';
import '../media/media_context.dart' show isMediaQuestion, isScreenQuestion, cameraCommand;
import '../net/realtime_socket.dart';
import '../notes/pinned_note.dart';
import '../pipeline/vad.dart';
import '../settings/settings.dart' show kLiveVoices, kRealtimeModels, kVoiceModels;
import 'context_images.dart';
import 'context_sync.dart';
import 'delegation_executor.dart';
import 'live_rtc_transport.dart';
import 'pinned_context.dart';
import 'voice_backend.dart';

const kLiveModels = kVoiceModels;

// ------------------------------------------------------------- call creation

class LiveCall {
  const LiveCall({required this.callId, required this.answerSdp});
  final String callId;
  final String answerSdp;
}

/// POSTs the SDP offer; returns the call id (from `Location`) and SDP answer.
typedef LiveCallCreator = Future<LiveCall> Function(Uri uri, Map<String, String> headers, Map<String, Object?> body);

class LiveCallException implements Exception {
  LiveCallException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'gpt-live call failed${status == null ? '' : ' (HTTP $status)'}: $message';
}

Future<LiveCall> createLiveCallHttp(Uri uri, Map<String, String> headers, Map<String, Object?> body) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await http.postUrl(uri);
    headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decodeStream(res);
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw LiveCallException(redactSecrets(text.length > 300 ? text.substring(0, 300) : text), status: res.statusCode);
    }
    final loc = res.headers.value('location') ?? '';
    final id = loc.split('/').where((s) => s.isNotEmpty).lastOrNull;
    if (id == null || !text.trimLeft().startsWith('v=')) {
      throw LiveCallException('unexpected reply (location="$loc")', status: res.statusCode);
    }
    return LiveCall(callId: id, answerSdp: text);
  } finally {
    http.close();
  }
}

// ------------------------------------------------------------------ metrics

/// Wall-clock phases of [LiveWebRtcBackend.connect].
class LiveConnectTimings {
  Duration? offer, callCreate, sideband, sessionStarted;
  @override
  String toString() =>
      'offer=${offer?.inMilliseconds}ms call=${callCreate?.inMilliseconds}ms '
      'sideband=${sideband?.inMilliseconds}ms session.started=${sessionStarted?.inMilliseconds}ms';
}

// ------------------------------------------------------------------- backend

/// gpt-live-* over WebRTC "AVAS" (research/REALTIME_API.md §3).
///
/// * Media: a [LiveRtcTransport] (flutter_webrtc in the app) owns the mic and
///   speaker, so the pipeline must not capture or play ([ManagedAudioBackend]).
/// * Events: sideband WebSocket `wss://api.openai.com/v1/live/{call_id}`.
///   Its continuous output stream feeds [AssistantAudioDelta] (levels and
///   reply clips) during assistant turns, and the server's echo of the mic
///   feeds a local VAD ([SpeechStarted]/[SpeechStopped], ~0.3 s earlier than
///   `turn.*`) plus utterance clips via [openManagedMic].
/// * No function tools: `delegation.created` is resolved on the client by a
///   [DelegationExecutor]; registry tools are run by the pipeline (emitted as
///   [ToolCall], answered with [sendToolResult]) so confirmations and the
///   transcript UI work as usual; the result goes back with
///   `delegation.context.append` and the voice model speaks it.
class LiveWebRtcBackend extends VoiceBackend
    implements ManagedAudioBackend, LiveContextSync, PinnedNoteSync, ContextImageSink {
  LiveWebRtcBackend({
    required this.transportFactory,
    RealtimeConnector? sideband,
    LiveCallCreator? createCall,
    this.delegationModelFactory,
    this.credentialsProvider,
    this.toolRunner,
    this.callsUrl = 'https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas',
    this.sidebandBase = 'wss://api.openai.com/v1/live',
    this.sessionStartTimeout = const Duration(seconds: 15),
    this.delegationFastModel = 'gpt-6-luna',
    this.delegationReasoningEffort = 'low',
    this.vadStopMs = 550,
    this.swapQuiet = const Duration(milliseconds: 1500),
    this.swapPoll = const Duration(milliseconds: 250),
    this.swapAttempts = 3,
  }) : _connectSideband = sideband ?? IoRealtimeSocket.connect,
       _createCall = createCall ?? createLiveCallHttp;

  final LiveRtcTransportFactory transportFactory;
  final RealtimeConnector _connectSideband;
  final LiveCallCreator _createCall;

  /// Builds the Responses client for delegations (default: [ResponsesDelegationModel]).
  final DelegationModel Function(Credentials? creds)? delegationModelFactory;

  /// Fresh credentials per delegation request (token refresh); defaults to
  /// the ones from [SessionConfig].
  final Future<Credentials?> Function()? credentialsProvider;

  /// Runs tools directly instead of round-tripping through the pipeline
  /// ([ToolCall] → [sendToolResult]). Used by headless tests.
  final DelegationToolRunner? toolRunner;
  final String callsUrl;
  final String sidebandBase;
  final Duration sessionStartTimeout;
  final String delegationFastModel;

  /// Reasoning effort of the delegation model (`none` is ~0.2 s faster).
  final String? delegationReasoningEffort;
  final int vadStopMs;

  /// Compaction swap ([applySummary]): how long the call must have been idle,
  /// how often to check, and how many prepared sessions may be discarded
  /// because the conversation moved on before giving up.
  final Duration swapQuiet;
  final Duration swapPoll;
  final int swapAttempts;

  final _events = StreamController<BackendEvent>.broadcast();
  final _delegations = StreamController<DelegationReport>.broadcast();
  _LiveSession? _session;
  // Includes prepared and retiring calls until their native capture closes.
  final _sessions = <_LiveSession>{};
  LiveRtcTransport? get _rtc => _session?.rtc;
  RealtimeSocket? get _ws => _session?.ws;
  SessionConfig? _config;
  String? _summary;
  String? _pinnedNote;
  DelegationExecutor? _executor;
  DelegationModel? _delegationModel;
  bool _closed = false;
  String? callId;
  final timings = LiveConnectTimings();

  // ---- audio timeline (session ms → output stream)
  int? _firstOutMs;
  final _out = _PcmTimeline(maxMs: 30000);
  int _outEndMs = 0;

  // ---- assistant turn state
  bool _assistantOpen = false;
  int _assistantStartMs = 0;
  int _emittedUntilMs = 0;
  int? _assistantCloseAtMs;
  String _assistantClosingText = '';
  Timer? _closeTimer;
  bool _speakerMuted = false;
  bool _interrupted = false;
  // Pipeline is deciding whether an interruption was just "stop": a new
  // assistant turn stays muted meanwhile.
  bool _replyHeld = false;
  // After "stop": the model's reply to it stays muted and hidden, and
  // delegations it starts are declined.
  DateTime? _dropUntil;
  String? _dropKey;
  bool _dropTurn = false;

  // ---- user speech state
  late final EnergyVad _vad = EnergyVad(stopMs: vadStopMs);
  bool _userSpeaking = false;
  // Client key of the user turn the pipeline is filling. It stays open across
  // VAD pauses until the server finishes the turn or the assistant takes the
  // floor, so one spoken turn is one message.
  String? _openUserKey;
  int _userSeq = 0;
  // Server user turn id → client key; transcripts can complete after the
  // assistant started answering.
  final Map<String, String> _keyByTurn = {};
  String? _transcriptKey;
  final Set<_ManagedMic> _mics = {};
  bool _inputEnabled = true;
  bool _captureSuspended = false;

  // ---- images (for delegation) and pending tool calls
  DelegationImage? _latestImage;

  /// Camera frame / media image per slot, for delegations.
  final Map<String, DelegationImage> _contextImages = {};

  @override
  void setContextImage(String slot, DelegationImage? image) =>
      image == null ? _contextImages.remove(slot) : _contextImages[slot] = image;
  final Map<String, Completer<String>> _pendingTools = {};
  int _toolSeq = 0;

  // ---- delegation tracking (for spoken-latency metrics)
  final Map<String, (DelegationReport, Stopwatch)> _awaitingSpeech = {};

  late final _ManagedPlayer _player = _ManagedPlayer(this);

  // ---- compaction swap (applySummary)
  ({String summary, String? recent})? _pendingApply;
  Completer<ContextApplyResult>? _applyDone;
  _LiveSession? _preparing;
  bool _swapping = false;
  Timer? _applyTimer;
  int _activity = 0;
  DateTime _lastActivity = DateTime.now();

  @override
  Stream<BackendEvent> get events => _events.stream;

  /// Completed delegations with timings (`spoken` filled when the assistant
  /// starts talking after the result was appended).
  Stream<DelegationReport> get delegations => _delegations.stream;

  @override
  bool get hasServerVad => true;

  @override
  ContextAccounting get contextAccounting => ContextAccounting.textEstimate;

  /// An assistant turn is open, a tool or delegation (or typed action) runs,
  /// or the model was just handed a result it has not voiced yet.
  @override
  bool get busy => _assistantOpen || _pendingTools.isNotEmpty || _runningActions > 0 || _settleTimers > 0;

  /// Delegations / typed actions still executing (not yet appended).
  int _runningActions = 0;

  /// Results handed to the model whose spoken answer has not started yet.
  int _settleTimers = 0;
  int _assistantTurns = 0;

  /// How long after a delegation / typed-action result was appended the
  /// model may stay silent before the turn counts as finished
  /// ([ResponseDone]), so the status line does not stay on "Thinking…" when
  /// the model voices nothing (e.g. after a fast-path action).
  Duration settleAfterResult = const Duration(seconds: 5);

  void _settleLater() {
    final turns = _assistantTurns;
    _settleTimers++;
    Timer(settleAfterResult, () {
      _settleTimers--;
      if (_closed || _assistantOpen || _assistantTurns != turns) return;
      debugPrint('gpt-live: result not voiced within ${settleAfterResult.inSeconds}s; turn settled');
      _emit(const ResponseDone());
    });
  }

  String get transportDescription => _rtc?.description ?? '-';

  /// Delegations received but not yet reported on [delegations].
  int get pendingDelegations => _pendingDelegations;
  int _pendingDelegations = 0;

  void _emit(BackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ------------------------------------------------------------- connect

  @override
  Future<void> connect(SessionConfig config) async {
    final creds = config.credentials;
    if (creds == null) {
      throw StateError('gpt-live needs a ChatGPT (Codex) login: run `codex login`');
    }
    if (creds.mode != AuthMode.codex) {
      throw StateError('gpt-live is only available with the Codex ChatGPT login (not an API key)');
    }
    _config = config;
    final prior = config.priorContext?.trim();
    _summary = prior == null || prior.isEmpty ? null : prior;
    _pinnedNote = config.pinnedNote;
    final total = Stopwatch()..start();
    final s = await _openSession(
      config,
      composeInstructions(config.instructions, _summary, config.recentContext, note: _pinnedNote),
      activate: true,
      timed: true,
    );
    timings.sessionStarted = total.elapsed;
    s.rtc.setMicEnabled(_inputEnabled);
    debugPrint('gpt-live connected: ${s.model} voice=${s.voice} call=${s.callId} $timings via ${s.rtc.description}');

    final dm =
        delegationModelFactory?.call(creds) ?? ResponsesDelegationModel(credentialsProvider ?? () async => creds);
    _delegationModel = dm;
    if (dm is ResponsesDelegationModel) unawaited(dm.warmUp());
    _executor = DelegationExecutor(
      model: dm,
      tools: config.tools,
      runTool: toolRunner ?? _runToolViaPipeline,
      latestScreenshot: () => _latestImage,
      contextImages: () => _contextImages.values.toList(),
      contextNote: _delegationNote,
      environment: () => config.environment,
      pinnedNote: () => _pinnedNote,
      fastModel: delegationFastModel,
      reasoningEffort: delegationReasoningEffort,
      speculativeCapture: !config.phone,
    );
  }

  /// gpt-live instructions are immutable: the note reaches the voice model
  /// at startup and on every compaction swap, and every delegation gets the
  /// current note in its input.
  @override
  void setPinnedNote(String? markdown) => _pinnedNote = markdown;

  /// Startup instructions: the session's instructions are immutable and
  /// `session.initial_items` does not exist (§3.2), so earlier context goes
  /// here as text.
  static String composeInstructions(String base, String? summary, String? recent, {String? note}) {
    final b = StringBuffer(note == null ? base : withPinnedNote(base, note));
    if (summary != null && summary.trim().isNotEmpty) {
      b.write('\n\nEarlier in this conversation (summary):\n${summary.trim()}');
    }
    if (recent != null && recent.trim().isNotEmpty) {
      b.write('\n\nMost recent turns, verbatim (continue from here; do not greet again):\n${recent.trim()}');
    }
    return b.toString();
  }

  /// Creates a call (offer → call → answer → sideband → session.started).
  /// With [activate] its events drive the backend at once; otherwise the
  /// session is prepared muted and only [_swapTo] makes it live.
  Future<_LiveSession> _openSession(
    SessionConfig config,
    String instructions, {
    required bool activate,
    bool timed = false,
  }) async {
    final creds = config.credentials!;
    final model = config.model.trim();
    final voice = config.voice.trim();
    if (model.isEmpty) throw StateError('Choose a nonempty gpt-live audio model in Settings.');
    if (kRealtimeModels.contains(model)) {
      throw StateError('"$model" is a realtime audio model. Select its realtime option in Settings.');
    }
    if (!kLiveVoices.contains(voice)) {
      throw StateError('gpt-live does not support the voice "$voice". Choose a supported live voice in Settings.');
    }
    // Forward explicit custom model IDs. The provider can reject them visibly;
    // silently using another model would misrepresent the user's selection.
    final headers = creds.headers(live: true);
    if (_closed) throw StateError('Live backend is closed');
    final s = _LiveSession(transportFactory(), model, voice);
    _sessions.add(s);
    s.onClosed = () => _sessions.remove(s);
    if (activate) {
      _session = s;
      // Muted / push-to-talk: no mic audio leaves while connecting either.
      s.rtc.setMicEnabled(_inputEnabled);
    } else {
      _preparing = s;
      s.rtc
        ..setMicEnabled(false)
        ..setSpeakerEnabled(false);
    }
    try {
      // A held recording can outlive a network reconnect or context swap.
      // Apply capture ownership before the new transport opens any device.
      await s.rtc.setCaptureSuspended(_captureSuspended);
      var sw = Stopwatch()..start();
      final offer = await s.rtc.createOffer();
      if (timed) timings.offer = sw.elapsed;
      sw = Stopwatch()..start();
      final call = await _createCall(Uri.parse(callsUrl), headers, {
        'sdp': offer,
        'session': {
          'model': model,
          'instructions': instructions,
          'audio': {
            'output': {'voice': voice},
          },
          'delegation': {'type': 'client'},
        },
      });
      if (timed) timings.callCreate = sw.elapsed;
      s.callId = call.callId;
      if (activate) callId = call.callId;
      await s.rtc.setAnswer(call.answerSdp);
      if (s.closed) throw LiveCallException('closed while connecting');

      sw = Stopwatch()..start();
      final RealtimeSocket ws;
      try {
        ws = await _connectSideband(Uri.parse('$sidebandBase/${call.callId}'), headers);
      } catch (e) {
        throw LiveCallException(
          'sideband rejected: ${redactSecrets('$e')} (an invalid session config kills the call silently)',
        );
      }
      if (timed) timings.sideband = sw.elapsed;
      s.ws = ws;
      if (s.closed) throw LiveCallException('closed while connecting');
      s.sub = ws.messages.listen(
        (raw) {
          Map<String, Object?> ev;
          try {
            ev = (jsonDecode(raw) as Map).cast<String, Object?>();
          } catch (_) {
            return;
          }
          if (ev['type'] == 'session.started' && !s.started.isCompleted) s.started.complete();
          // A prepared or replaced session never touches the turn state.
          if (!identical(_session, s)) return;
          try {
            _onSideband(ev);
          } catch (e, st) {
            debugPrint('live sideband handler: $e\n$st');
          }
        },
        onDone: () {
          if (!s.started.isCompleted) {
            s.started.completeError(LiveCallException('sideband closed before session.started (${ws.closeCode})'));
          }
          if (!_closed && identical(_session, s)) {
            _onConnectionLost(ws.closeCode, ws.closeReason);
          }
        },
        onError: (Object e) {
          if (!s.started.isCompleted) s.started.completeError(e);
        },
      );
      await s.started.future.timeout(
        sessionStartTimeout,
        onTimeout: () => throw LiveCallException('no session.started within ${sessionStartTimeout.inSeconds}s'),
      );
      return s;
    } catch (_) {
      if (!activate) unawaited(s.close());
      rethrow;
    } finally {
      if (identical(_preparing, s)) _preparing = null;
    }
  }

  /// The sideband of the live call closed on its own (e.g. 1006 = the TCP
  /// connection dropped without a close frame). Unblock everything that was
  /// in flight and report a reconnectable loss; the pipeline reconnects with
  /// backoff and restores the context (summary + recent turns).
  void _onConnectionLost(int? code, String? reason) {
    debugPrint('gpt-live sideband closed (${code ?? '-'} ${reason ?? ''})');
    if (_userSpeaking) _userStopped();
    if (_assistantOpen) {
      _interrupted = true;
      _finishAssistant();
    }
    for (final c in _pendingTools.values) {
      if (!c.isCompleted) c.complete('{"ok":false,"error":"voice connection lost"}');
    }
    _pendingTools.clear();
    _emit(
      BackendError(
        'gpt-live connection lost (${code ?? '-'}${reason == null || reason.isEmpty ? '' : ' $reason'})',
        code: 'connection_lost',
        fatal: true,
      ),
    );
  }

  // ------------------------------------------------- compaction (§3.2)

  /// Applies a compaction to the live call. gpt-live keeps its own growing
  /// context and its instructions are immutable, so "apply" means: the next
  /// delegation gets [summary] as memory right away, and once the call is
  /// idle (no user speech, no assistant turn or audio, no delegation or
  /// tool in flight, quiet for [swapQuiet]) a new call is prepared with
  /// instructions + [summary] + [recentTurns], muted, while the old one keeps
  /// serving. It is swapped in only if nothing happened meanwhile (otherwise
  /// it is discarded and prepared again), so no response is interrupted.
  @override
  Future<ContextApplyResult> applySummary(String summary, {String? recentTurns}) {
    if (_closed || _config == null) {
      return Future.value(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'not connected'));
    }
    _summary = summary.trim();
    _pendingApply = (summary: summary.trim(), recent: recentTurns);
    final c = _applyDone ??= Completer<ContextApplyResult>();
    _scheduleApply(Duration.zero);
    return c.future;
  }

  void _noteActivity() {
    _activity++;
    _lastActivity = DateTime.now();
  }

  bool get _idle =>
      !_assistantOpen &&
      !_userSpeaking &&
      _openUserKey == null &&
      _keyByTurn.isEmpty &&
      _pendingTools.isEmpty &&
      _pendingDelegations == 0 &&
      !_player.isPlaying;

  bool get _quiet => _idle && DateTime.now().difference(_lastActivity) >= swapQuiet;

  void _scheduleApply([Duration? delay]) {
    _applyTimer?.cancel();
    _applyTimer = Timer(delay ?? swapPoll, _tryApply);
  }

  void _tryApply() {
    if (_pendingApply == null || _swapping) return;
    if (_closed) {
      _finishApply(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'closed'));
      return;
    }
    if (!_quiet) return _scheduleApply();
    unawaited(_swap());
  }

  void _finishApply(ContextApplyResult r) {
    final c = _applyDone;
    _applyDone = null;
    _pendingApply = null;
    if (c != null && !c.isCompleted) c.complete(r);
  }

  Future<void> _swap() async {
    _swapping = true;
    var result = const ContextApplyResult(ContextApplyMethod.skipped, detail: 'conversation kept moving');
    try {
      for (var attempt = 0; attempt < swapAttempts; attempt++) {
        while (!_closed && !_quiet) {
          await Future<void>.delayed(swapPoll);
        }
        final want = _pendingApply;
        final cfg = _config;
        if (_closed || want == null || cfg == null) {
          result = const ContextApplyResult(ContextApplyMethod.skipped, detail: 'closed');
          break;
        }
        final activity = _activity;
        final _LiveSession next;
        try {
          next = await _openSession(
            cfg,
            composeInstructions(cfg.instructions, want.summary, want.recent, note: _pinnedNote),
            activate: false,
          );
        } catch (e) {
          result = ContextApplyResult(ContextApplyMethod.skipped, detail: 'reconnect failed: $e');
          continue;
        }
        if (_closed) {
          await next.close();
          break;
        }
        if (activity != _activity || !_idle || !identical(want, _pendingApply)) {
          // The user or the assistant spoke meanwhile (the new call would miss
          // that turn), or a newer summary arrived: prepare again.
          await next.close();
          continue;
        }
        _swapTo(next);
        result = ContextApplyResult(ContextApplyMethod.reconnected, detail: 'call ${next.callId}');
        break;
      }
    } finally {
      _swapping = false;
      _finishApply(result);
    }
  }

  /// Makes [next] the live call (synchronously, between turns) and closes
  /// the old one.
  void _swapTo(_LiveSession next) {
    final old = _session;
    _session = next;
    callId = next.callId;
    _closeTimer?.cancel();
    _out.clear();
    _firstOutMs = null;
    _outEndMs = 0;
    _emittedUntilMs = 0;
    _assistantStartMs = 0;
    _assistantCloseAtMs = null;
    _interrupted = false;
    _speakerMuted = false;
    _transcriptKey = null;
    _vad.reset();
    _player.clock.reset();
    next.rtc
      ..setSpeakerEnabled(true)
      ..setMicEnabled(_inputEnabled);
    debugPrint('gpt-live: compacted context, switched call ${old?.callId} -> ${next.callId}');
    if (old != null) unawaited(old.close());
  }

  // -------------------------------------------------------------- sideband

  void _send(Map<String, Object?> ev) => _ws?.send(jsonEncode(ev));

  void _onSideband(Map<String, Object?> ev) {
    switch (ev['type']) {
      case 'session.output_audio.delta':
        _onOutputAudio(ev);
      case 'session.input_audio.append':
        final a = ev['audio'];
        if (a is String) _onInputEcho(base64Decode(a));
      case 'input_transcript.added':
        // Words of the user turn in progress (no turn id on this event).
        final key = _transcriptKey ?? _openUserKey ?? _userStarted();
        final t = _itemText(ev);
        if (t.isNotEmpty) _emit(UserTranscriptDelta(t, itemId: key));
      case 'output_transcript.added':
        _openAssistant(_int(ev['start_ms']));
        final t = _itemText(ev);
        if (t.isNotEmpty && !_dropTurn) _emit(AssistantTranscriptDelta(t));
        _markSpoken();
      case 'turn.created':
        final turn = _map(ev['turn']);
        if (turn['role'] == 'user') {
          _bindUserTurn('${turn['id'] ?? ''}');
        } else if (turn['role'] == 'assistant') {
          _openAssistant(_int(turn['start_ms']));
        }
      case 'turn.done':
        _noteActivity();
        final turn = _map(ev['turn']);
        final text = '${turn['transcript'] ?? ''}'.trim();
        if (text.isNotEmpty) debugPrint('gpt-live ${turn['role']}: $text');
        if (turn['role'] == 'user') {
          final id = '${turn['id'] ?? ''}';
          final key = _keyByTurn.remove(id) ?? _transcriptKey ?? _openUserKey ?? 'user_${++_userSeq}';
          if (_userSpeaking && key == _openUserKey) _userStopped();
          if (_transcriptKey == key) _transcriptKey = null;
          if (_openUserKey == key) _openUserKey = null;
          _emit(UserTranscriptDone(text, itemId: key));
        } else if (turn['role'] == 'assistant') {
          _closeAssistant(_int(turn['end_ms']), text);
        }
      case 'delegation.created':
        _onDelegation(ev);
      case 'delegation.context.appended':
        final id = '${ev['delegation_item_id'] ?? ''}';
        final w = _awaitingSpeech[id];
        if (w != null) w.$1.appended = w.$2.elapsed;
      case 'error':
        final err = _map(ev['error']);
        _emit(BackendError('gpt-live: ${err['message'] ?? 'error'}', code: err['code'] as String?));
      case 'session.usage.updated' || 'session.started' || 'session.updated' || 'turn.delta':
        break;
    }
  }

  static Map<String, Object?> _map(Object? o) => o is Map ? o.cast<String, Object?>() : const {};
  static int _int(Object? o) => o is num ? o.toInt() : 0;
  static String _itemText(Map<String, Object?> ev) => '${_map(ev['item'])['text'] ?? ''}';

  // ---- output audio / assistant turns

  void _onOutputAudio(Map<String, Object?> ev) {
    final d = ev['delta'];
    if (d is! String) return;
    final pcm = base64Decode(d);
    final start = _int(ev['start_ms']);
    _firstOutMs ??= start;
    _out.add(start, pcm);
    _outEndMs = start + pcmDurationMs(pcm.length);
    if (_assistantOpen) _flushAssistantAudio();
  }

  void _openAssistant(int startMs) {
    if (_assistantOpen) return;
    _noteActivity();
    _assistantOpen = true;
    _assistantTurns++;
    _assistantCloseAtMs = null;
    _assistantStartMs = startMs;
    _emittedUntilMs = startMs;
    _interrupted = false;
    _dropTurn = _dropping;
    debugPrint(
      'gpt-live turn open (muted=$_speakerMuted held=$_replyHeld drop=$_dropTurn) t=${DateTime.now().millisecondsSinceEpoch}',
    );
    if (_dropTurn) {
      _interrupted = true;
      _mute();
    } else if (_replyHeld) {
      _mute();
    } else if (_speakerMuted) {
      _speakerMuted = false;
      _speaker(true, 'new assistant turn');
    }
    // Full duplex: once the assistant takes the floor the user turn is over.
    if (_userSpeaking) _userStopped();
    final open = _openUserKey;
    _openUserKey = null;
    if (open != null && !_keyByTurn.containsValue(open)) {
      // Local VAD fired but the server never opened a user turn (echo or
      // noise): close the empty message.
      _emit(UserTranscriptDone('', itemId: open, noSpeech: true));
    }
    _flushAssistantAudio();
  }

  void _flushAssistantAudio() {
    final until = _assistantCloseAtMs ?? _outEndMs;
    if (until > _emittedUntilMs) {
      final pcm = _out.slice(_emittedUntilMs, until);
      _emittedUntilMs = until;
      if (pcm.isNotEmpty && !_speakerMuted && !_dropTurn) _emit(AssistantAudioDelta(pcm));
    }
    final closeAt = _assistantCloseAtMs;
    if (closeAt != null && _outEndMs >= closeAt) _finishAssistant();
  }

  void _closeAssistant(int endMs, String text) {
    if (!_assistantOpen) _openAssistant(endMs);
    _assistantCloseAtMs = endMs < _assistantStartMs ? _assistantStartMs : endMs;
    _assistantClosingText = text;
    _flushAssistantAudio();
    if (_assistantOpen) {
      // Audio for the last frame may still be in flight.
      _closeTimer?.cancel();
      _closeTimer = Timer(const Duration(milliseconds: 600), _finishAssistant);
    }
  }

  void _finishAssistant() {
    if (!_assistantOpen) return;
    _noteActivity();
    _closeTimer?.cancel();
    _assistantOpen = false;
    _assistantCloseAtMs = null;
    if (!_dropTurn) _emit(AssistantTranscriptDone(_assistantClosingText));
    _emit(ResponseDone(cancelled: _interrupted));
    _interrupted = false;
    _dropTurn = false;
  }

  /// Saves the session timeline slice of an assistant turn (§3.5).
  Uint8List outputAudio(int startMs, int endMs) => _out.slice(startMs, endMs);

  // ---- input echo / user speech

  void _onInputEcho(Uint8List pcm) {
    const chunk = kVoiceBytesPerSecond ~/ 50; // 20 ms
    for (var o = 0; o + 1 < pcm.length; o += chunk) {
      final c = Uint8List.sublistView(pcm, o, (o + chunk).clamp(0, pcm.length));
      switch (_vad.process(c)) {
        case VadEvent.speechStarted:
          _userStarted();
        case VadEvent.speechStopped:
          if (_userSpeaking) _userStopped();
        case null:
      }
      for (final m in _mics) {
        m.push(c);
      }
    }
  }

  /// Starts (or resumes) the open user turn; returns its key.
  String _userStarted() {
    final key = _openUserKey ??= 'user_${++_userSeq}';
    _noteActivity();
    if (_userSpeaking) return key;
    _userSpeaking = true;
    if (key != _dropKey) _dropUntil = null;
    final dm = _delegationModel;
    if (dm is ResponsesDelegationModel) unawaited(dm.warmUpIfIdle());
    _emit(SpeechStarted(itemId: key));
    return key;
  }

  void _userStopped() {
    _noteActivity();
    _userSpeaking = false;
    _emit(SpeechStopped(itemId: _openUserKey));
  }

  /// Ties server user turn [turnId] to the open client turn (opening one if
  /// needed). A second server turn while the first is still unfinished gets
  /// its own key/message.
  String _bindUserTurn(String turnId) {
    final existing = _keyByTurn[turnId];
    if (existing != null) return existing;
    final open = _openUserKey;
    if (open != null && _keyByTurn.containsValue(open)) {
      if (_userSpeaking) _userStopped();
      _openUserKey = null;
    }
    final key = _userStarted();
    if (turnId.isNotEmpty) _keyByTurn[turnId] = key;
    _transcriptKey = key;
    return key;
  }

  // ---- delegation

  void _onDelegation(Map<String, Object?> ev) {
    final item = _map(ev['item']);
    final id = '${item['id'] ?? ''}';
    final content = item['content'];
    final text = content is List
        ? content.whereType<Map>().where((c) => c['type'] == 'input_text').map((c) => c['text'] ?? '').join(' ').trim()
        : '';
    final ex = _executor;
    if (id.isEmpty || ex == null) return;
    _noteActivity();
    if (_dropping) {
      debugPrint('gpt-live: declined delegation "$text" (user said stop)');
      _send({
        'type': 'delegation.context.append',
        'delegation_item_id': id,
        'content': [
          {'type': 'input_text', 'text': 'Not done: the user said stop / cancel. Do nothing and say nothing.'},
        ],
      });
      _settleLater();
      return;
    }
    final sw = Stopwatch()..start();
    _pendingDelegations++;
    _runningActions++;
    unawaited(() async {
      final DelegationReport report;
      try {
        report = await ex.execute(text, id: id);
      } finally {
        _runningActions--;
      }
      if (_closed) return;
      _send({
        'type': 'delegation.context.append',
        'delegation_item_id': id,
        'content': [
          {'type': 'input_text', 'text': delegationResultNote(report)},
        ],
      });
      debugPrint('live delegation "$text": ${report.timingSummary()}');
      _settleLater();
      _awaitingSpeech[id] = (report, sw);
      // Report even if the model never speaks.
      Timer(const Duration(seconds: 12), () => _reportDelegation(id));
    }());
  }

  /// What the model is told when a delegation finishes: the real outcome
  /// (failures included) and how to voice it, without repeating filler.
  static String delegationResultNote(DelegationReport report) {
    final failed =
        report.error != null ||
        report.resultText.startsWith('Not fully done') ||
        report.resultText.startsWith('Failed');
    return '${report.resultText}\n'
        '${failed ? 'This did NOT fully succeed. ' : ''}'
        'Tell the user the actual outcome above in one short sentence. Do not repeat any earlier "on it" '
        'acknowledgement and do not claim anything the result does not show.';
  }

  void _markSpoken() {
    for (final id in _awaitingSpeech.keys.toList()) {
      final (r, sw) = _awaitingSpeech[id]!;
      if (r.appended == null) continue;
      r.spoken = sw.elapsed;
      _reportDelegation(id);
    }
  }

  void _reportDelegation(String id) {
    final w = _awaitingSpeech.remove(id);
    if (w == null) return;
    _pendingDelegations--;
    if (!_delegations.isClosed) _delegations.add(w.$1);
  }

  Future<String> _runToolViaPipeline(String callId, String name, String argsJson) {
    final id = 'dlg_${++_toolSeq}_$callId';
    final c = Completer<String>();
    _pendingTools[id] = c;
    _emit(ToolCall(id, name, argsJson));
    return c.future.timeout(
      const Duration(minutes: 6),
      onTimeout: () {
        _pendingTools.remove(id);
        return jsonEncode({'ok': false, 'error': 'tool timed out'});
      },
    );
  }

  // ------------------------------------------------------------ client API

  @override
  void sendAudio(Uint8List pcm16) {
    // Mic audio must travel over RTP (the WebRTC track); see openManagedMic.
  }

  @override
  void sendText(String text) {
    _noteActivity();
    final t = text.trim();
    if (t.isEmpty) return;
    // Typed turn -> "turn open" (first audio) latency in QA logs.
    debugPrint('gpt-live typed turn t=${DateTime.now().millisecondsSinceEpoch}');
    final ex = _executor;
    // Typed text never starts a delegation on gpt-live, so action requests
    // are carried out here and the model only voices the real outcome.
    if (ex != null && (looksLikeAction(t) || _asksAboutContextImages(t))) {
      _runTypedAction(t, ex);
      return;
    }
    // No user-text item on this transport. Context without a channel makes
    // the model answer (the 'developer' channel is read silently; §3.2).
    _appendContext('The user typed (instead of speaking): $t');
    _settleLater();
  }

  /// "what do you see?" with the camera on, "what's in this image" with
  /// media open: only the delegation model can look, so it answers.
  /// "what's on my screen?" with a screenshot held (assist gesture, screen
  /// share, auto screenshot) likewise.
  bool _asksAboutContextImages(String t) =>
      isMediaQuestion(t) ||
      (_latestImage != null && isScreenQuestion(t)) ||
      cameraCommand(t) != null ||
      (_contextImages.containsKey('camera') && DelegationExecutor.needsScreen(t));

  void _appendContext(String text) => _send({
    'type': 'session.context.append',
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  });

  void _runTypedAction(String text, DelegationExecutor ex) {
    _pendingDelegations++;
    _runningActions++;
    unawaited(() async {
      final DelegationReport report;
      try {
        report = await ex.execute(text, id: 'typed_${++_toolSeq}');
      } finally {
        _pendingDelegations--;
        _runningActions--;
      }
      if (_closed) return;
      debugPrint('live typed action "$text": ${report.timingSummary()}');
      _appendContext(
        'The user typed: "$text". The app already carried it out. Result: ${report.resultText}\n'
        'Tell the user the outcome in one short sentence, exactly as reported; if it failed or was not done, '
        'say so plainly. Do not start another action for this request.',
      );
      _settleLater();
      if (!_delegations.isClosed) _delegations.add(report);
    }());
  }

  @override
  String? sendImage(Uint8List png, {String? note}) {
    // gpt-live context is text only; images are kept for delegations.
    _latestImage = DelegationImage(png: png, capturedAt: DateTime.now(), note: note);
    return null;
  }

  String _screenMemory = '';

  /// Descriptions of older screenshots; delegations get them with the summary.
  @override
  void updateScreenMemory(String text) => _screenMemory = text.trim();

  String? _delegationNote() {
    final parts = [
      if (_summary != null && _summary!.trim().isNotEmpty) _summary!.trim(),
      if (_screenMemory.isNotEmpty) 'Earlier screens (described):\n$_screenMemory',
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  @override
  void sendToolResult(String callId, String jsonOutput) {
    final c = _pendingTools.remove(callId);
    if (c != null && !c.isCompleted) c.complete(jsonOutput);
  }

  /// Stop / barge-in: gpt-live is full duplex and yields by itself when the
  /// user talks; locally we silence the remote track until the next turn.
  @override
  void cancelResponse() {
    // The caller heard the assistant: mute even when no turn is tracked as
    // open (turn events can lag the audio); the next turn unmutes.
    if (_assistantOpen || _player.isPlaying) _interrupted = true;
    _mute();
  }

  void _mute() {
    _speakerMuted = true;
    _speaker(false, 'mute');
    _player.clock.reset();
  }

  bool get _dropping {
    final u = _dropUntil;
    return u != null && DateTime.now().isBefore(u);
  }

  /// "Stop": silence now and swallow the model's answer to it (full duplex,
  /// so there is nothing to cancel server-side; the model yields by itself).
  @override
  void stopAndDrop() {
    _dropKey = _openUserKey;
    _dropUntil = DateTime.now().add(const Duration(seconds: 4));
    if (_assistantOpen) {
      _interrupted = true;
      _dropTurn = true;
    }
    _mute();
  }

  @override
  void setReplyHold(bool hold) {
    if (_replyHeld == hold) return;
    _replyHeld = hold;
    if (!hold && _assistantOpen && _speakerMuted && !_interrupted && !_dropTurn) {
      _speakerMuted = false;
      _speaker(true, 'hold released');
    }
  }

  /// Remote track on/off, logged with wall-clock ms (barge-in timing in QA).
  void _speaker(bool on, String why) {
    _rtc?.setSpeakerEnabled(on);
    debugPrint('gpt-live speaker ${on ? 'on' : 'off'} ($why) t=${DateTime.now().millisecondsSinceEpoch}');
  }

  // ------------------------------------------------------- managed audio

  @override
  Future<MicStream> openManagedMic() async {
    final m = _ManagedMic(this);
    _mics.add(m);
    setInputEnabled(true);
    try {
      // Resume may need a new native stream after exclusive held capture.
      // Do not report an open managed mic before that operation completes.
      await _rtc?.setCaptureSuspended(_captureSuspended);
      return m;
    } catch (_) {
      await m.close();
      rethrow;
    }
  }

  @override
  PcmPlayer get managedPlayer => _player;

  @override
  void setInputEnabled(bool enabled) {
    _inputEnabled = enabled;
    _rtc?.setMicEnabled(enabled);
  }

  @override
  Future<void> setCaptureSuspended(bool suspended) async {
    _captureSuspended = suspended;
    // Update the desired state synchronously. Sessions created during the
    // await inherit it before createOffer and cannot reacquire the device.
    await Future.wait([for (final session in _sessions.toList()) session.rtc.setCaptureSuspended(suspended)]);
  }

  void _micClosed(_ManagedMic m) {
    _mics.remove(m);
    if (_mics.isEmpty) setInputEnabled(false);
  }

  // ----------------------------------------------------------------- close

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeTimer?.cancel();
    _applyTimer?.cancel();
    _finishApply(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'closed'));
    for (final c in _pendingTools.values) {
      if (!c.isCompleted) c.complete('{"ok":false,"error":"session closed"}');
    }
    _pendingTools.clear();
    await Future.wait([for (final session in _sessions.toList()) session.close()]);
    _delegationModel?.close();
    for (final m in _mics.toList()) {
      await m.close();
    }
    _player.clock.dispose();
    await _events.close();
    await _delegations.close();
  }
}

// ------------------------------------------------------------------ helpers

/// One gpt-live call: WebRTC media plus its sideband socket.
class _LiveSession {
  _LiveSession(this.rtc, this.model, this.voice);
  final LiveRtcTransport rtc;
  final String model;
  final String voice;
  RealtimeSocket? ws;
  StreamSubscription<String>? sub;
  String? callId;
  final started = Completer<void>();
  bool closed = false;
  void Function()? onClosed;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    closed = true;
    try {
      ws?.send(jsonEncode({'type': 'session.close'}));
    } catch (_) {}
    await sub?.cancel();
    try {
      await ws?.close();
    } catch (_) {}
    try {
      await rtc.close();
    } catch (_) {}
    onClosed?.call();
  }
}

/// Sparse PCM store keyed by session milliseconds (200 ms frames).
class _PcmTimeline {
  _PcmTimeline({required this.maxMs});
  final int maxMs;
  final SplayTreeMap<int, Uint8List> _frames = SplayTreeMap();

  void clear() => _frames.clear();

  void add(int startMs, Uint8List pcm) {
    _frames[startMs] = pcm;
    final cutoff = startMs - maxMs;
    while (_frames.isNotEmpty && _frames.firstKey()! < cutoff) {
      _frames.remove(_frames.firstKey());
    }
  }

  /// PCM for [fromMs, toMs); gaps are filled with silence.
  Uint8List slice(int fromMs, int toMs) {
    if (toMs <= fromMs) return Uint8List(0);
    final bpm = kVoiceBytesPerSecond ~/ 1000; // 48 bytes per ms
    final out = Uint8List((toMs - fromMs) * bpm);
    for (final e in _frames.entries) {
      final s = e.key, pcm = e.value;
      final end = s + pcmDurationMs(pcm.length);
      if (end <= fromMs || s >= toMs) continue;
      final a = (fromMs > s ? fromMs : s), b = (toMs < end ? toMs : end);
      out.setRange((a - fromMs) * bpm, (b - fromMs) * bpm, pcm, (a - s) * bpm);
    }
    return out;
  }
}

/// The server's echo of what the WebRTC mic sent, in 20 ms chunks.
class _ManagedMic implements MicStream {
  _ManagedMic(this._owner);
  final LiveWebRtcBackend _owner;
  final _chunks = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  bool _closed = false;

  void push(Uint8List c) {
    if (_closed) return;
    final target = rmsToMeter(pcm16Rms(c));
    _level.value = target > _level.value ? target : _level.value * 0.85 + target * 0.15;
    _chunks.add(c);
  }

  @override
  Stream<Uint8List> get chunks => _chunks.stream;
  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _owner._micClosed(this);
    await _chunks.close();
    _level.dispose();
  }
}

/// WebRTC already plays the reply; this only tracks levels / audibility of
/// the [AssistantAudioDelta] stream for the orb and barge-in logic.
class _ManagedPlayer implements PcmPlayer {
  _ManagedPlayer(this._owner);
  final LiveWebRtcBackend _owner;
  final clock = PlaybackClock(outputLatency: const Duration(milliseconds: 120));

  @override
  void write(Uint8List pcm16) {
    if (!_owner._speakerMuted) clock.onWrite(pcm16);
  }

  @override
  Future<void> stop() async => clock.reset();
  @override
  bool get isPlaying => clock.isPlaying;
  @override
  ValueListenable<double> get level => clock.level;
  @override
  Future<void> close() async => clock.reset();
}
