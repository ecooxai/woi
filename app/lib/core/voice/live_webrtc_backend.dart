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
import '../media/media_context.dart' show isMediaQuestion, isScreenQuestion, mediaCaptureCommand;
import '../net/realtime_socket.dart';
import '../notes/pinned_note.dart';
import '../pipeline/vad.dart';
import '../settings/settings.dart' show kLiveVoices, kRealtimeModels, kVoiceModels;
import 'context_images.dart';
import 'context_sync.dart';
import 'delegation_executor.dart';
import 'live_context_delivery.dart';
import 'live_rtc_transport.dart';
import 'pinned_context.dart';
import 'voice_backend.dart';

const kLiveModels = kVoiceModels;

/// Full attachment analysis is retained in chat; Live gets one bounded cue.
/// Long analysis is not copied or silently truncated into the spoken context.
@visibleForTesting
String buildLiveAttachmentReplyCue(WrittenResponse result) {
  if (result.failed) {
    return 'The attachment analysis failed. The written reply explains the problem. '
        'Tell the user to try sending the attachment again. Do not claim success or start another action.';
  }
  final complete =
      'The attachment request produced this actual result: ${result.text}\n'
      'Say this result briefly, once. The complete answer is visible in the written reply. Do not start another action.';
  if (utf8.encode(complete).length <= kLiveContextMaxUtf8Bytes) return complete;
  return 'The app completed the attachment analysis. The full answer is in the written reply. '
      'The analysis details are not included in this live context. '
      'Tell the user once: “The attachment analysis is ready in the written reply.” '
      'Do not invent or summarize unseen details. Do not start another action.';
}

@visibleForTesting
String buildLiveReferenceReplyCue(WrittenResponse result) {
  if (result.failed) {
    return 'The saved-analysis question could not be answered reliably. The written reply explains the problem. '
        'Ask the user to try the question again. Do not claim success or start another action.';
  }
  final complete =
      'The current question produced this written answer: ${result.text}\n'
      'Say this answer briefly, once. The full answer is visible in the written reply. Do not start another action.';
  if (utf8.encode(complete).length <= kLiveContextMaxUtf8Bytes) return complete;
  return 'The answer to the current question is ready in the written reply. Its details are not included in '
      'this live context. Tell the user once that the answer is ready. Do not invent details or start another action.';
}

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
    this.delegationReasoningEffort = 'medium',
    this.delegationReasoningEffortProvider,
    this.vadStopMs = 550,
    this.swapQuiet = const Duration(milliseconds: 1500),
    this.swapPoll = const Duration(milliseconds: 250),
    this.swapAttempts = 3,
  }) : _connectSideband = sideband ?? _connectLiveSideband,
       _createCall = createCall ?? createLiveCallHttp;

  // Do not let the generic missed-Pong watchdog retire an otherwise active
  // live call. Native event-channel loss and reply deadlines still handle loss.
  static Future<RealtimeSocket> _connectLiveSideband(Uri uri, Map<String, String> headers) =>
      IoRealtimeSocket.connect(uri, headers, pingInterval: null);

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

  /// Thinking for text delegations. Pointer control has its own none effort.
  final String? delegationReasoningEffort;
  final String? Function()? delegationReasoningEffortProvider;
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

  // Explicit composer attachments belong to the next typed dispatch. Keep
  // their identity separate from camera/media/screen context and consume once.
  final Map<String, DelegationImage> _pendingAttachmentImages = {};

  @override
  void setContextImage(String slot, DelegationImage? image) {
    if (image == null) {
      _contextImages.remove(slot);
      _pendingAttachmentImages.remove(slot);
    } else {
      _contextImages[slot] = image;
      if (slot.startsWith('attachment:')) _pendingAttachmentImages[slot] = image;
    }
  }

  final Map<String, Completer<String>> _pendingTools = {};
  int _toolSeq = 0;

  // ---- delegation tracking (for spoken-latency metrics)
  final Map<String, (DelegationReport, Stopwatch)> _awaitingSpeech = {};

  late final _ManagedPlayer _player = _ManagedPlayer(this);

  // ---- compaction swap (applySummary)
  _LiveContextApply? _pendingApply;
  String _appliedWrittenContext = '';
  bool Function()? _appliedWrittenCurrent;
  Object? _appliedContextOwner;

  @visibleForTesting
  Duration typedContextPrepareTimeout = const Duration(seconds: 20);
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
  bool get busy =>
      _assistantOpen ||
      _pendingTools.isNotEmpty ||
      _runningActions > 0 ||
      _settleTimers > 0 ||
      _pendingReply != null ||
      _pendingApply?.owner != null ||
      !(_session?.contextDelivery?.isIdle ?? true);

  /// Delegations / typed actions still executing (not yet appended).
  int _runningActions = 0;
  // Stop retires results still waiting on a tool/model, even when the live
  // session is kept for a subsequent question. Session identity alone is not
  // sufficient: a cancelled executor returns a failure report asynchronously.
  int _actionGeneration = 0;

  /// Results handed to the model whose spoken answer has not started yet.
  int _settleTimers = 0;
  int _assistantTurns = 0;
  _LivePendingReply? _pendingReply;
  bool _requiresFreshReplyContext = false;
  bool _discardRetiredReplies = false;
  bool _voiceRecoveryNoticeSent = false;
  bool _nativeCaptureReleaseFailed = false;
  bool _nativeCaptureFailureReported = false;

  @override
  bool get voiceInputNeedsReconnect => _discardRetiredReplies;
  int _typedInputGeneration = 0;

  /// Maximum silence before an accepted outcome is confirmed. Real response
  /// output extends the deadline, allowing long useful answers to finish.
  @visibleForTesting
  Duration responseWaitTimeout = const Duration(seconds: 60);

  @visibleForTesting
  Duration responseCompletionTimeout = const Duration(minutes: 5);

  /// How long after a delegation / typed-action result was appended the
  /// model may stay silent before the turn counts as finished
  /// ([ResponseDone]), so the status line does not stay on "Thinking…" when
  /// the model voices nothing (e.g. after a fast-path action).
  Duration settleAfterResult = const Duration(seconds: 5);

  void _settleLater() {
    final turns = _assistantTurns;
    final session = _session;
    final generation = _actionGeneration;
    final typedGeneration = _typedInputGeneration;
    _settleTimers++;
    Timer(settleAfterResult, () {
      _settleTimers--;
      if (_closed ||
          !identical(_session, session) ||
          generation != _actionGeneration ||
          typedGeneration != _typedInputGeneration ||
          _assistantOpen ||
          _assistantTurns != turns) {
        return;
      }
      if (_pendingReply != null) {
        debugPrint('gpt-live: accepted request is still awaiting a confirmed reply');
        return;
      }
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
      reasoningEffortProvider: delegationReasoningEffortProvider,
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

  void _onSessionEvent(
    _LiveSession session,
    String raw, {
    required bool rtcControl,
  }) {
    if (_closed || session.closed || session.connectionLost) return;
    final Map<String, Object?> event;
    try {
      event = (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    // Either bootstrap notification can establish startup. Native controls
    // still wait for their own channel before this call accepts input.
    if (event['type'] == 'session.started' && !session.started.isCompleted) {
      session.started.complete();
    }
    if (!identical(_session, session)) return;
    if (session.controlSource != null) {
      final media =
          event['type'] == 'session.input_audio.append' ||
          event['type'] == 'session.output_audio.delta';
      // Never merge uncorrelated receipts or duplicate transcripts across
      // transports. This choice is fixed for the whole native session.
      if (rtcControl == media) return;
    }
    try {
      _onSideband(event);
    } catch (error, stack) {
      debugPrint('live event handler: $error\n$stack');
    }
  }

  void _sessionConnectionLost(_LiveSession session, int? code, String? reason, {bool controlFailure = false}) {
    if (session.closed || session.connectionLost) return;
    session.connectionLost = true;
    // Resolve startup without an unobserved error before its await is attached;
    // _openSession checks the lost/closed state before accepting this call.
    if (!session.started.isCompleted) session.started.complete();
    if (!_closed && identical(_session, session)) {
      _onConnectionLost(code, reason, controlFailure: controlFailure);
    }
    unawaited(session.close());
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
    if (model.isEmpty) {
      throw StateError('Choose a nonempty gpt-live audio model in Settings.');
    }
    if (kRealtimeModels.contains(model)) {
      throw StateError(
        '"$model" is a realtime audio model. Select its realtime option in Settings.',
      );
    }
    if (!kLiveVoices.contains(voice)) {
      throw StateError(
        'gpt-live does not support the voice "$voice". Choose a supported live voice in Settings.',
      );
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
      final rtcEvents = s.controlSource;
      if (rtcEvents != null) {
        // Subscribe before createOffer: the native channel can open and emit
        // its bootstrap event while the sideband handshake is in flight.
        s.controlSub = rtcEvents.controlEvents.listen(
          (raw) => _onSessionEvent(s, raw, rtcControl: true),
          onDone: () =>
              _sessionConnectionLost(s, null, 'live event channel closed', controlFailure: true),
          onError: (Object _) =>
              _sessionConnectionLost(s, null, 'live event channel error', controlFailure: true),
        );
      }
      // A held recording can outlive a network reconnect or context swap.
      // Apply capture ownership before the new transport opens any device.
      await s.rtc.setCaptureSuspended(_captureSuspended);
      var sw = Stopwatch()..start();
      final offer = await s.rtc.createOffer();
      if (_closed || s.closed || s.connectionLost) throw LiveCallException('live session closed while preparing offer');
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
        ws = await _connectSideband(
          Uri.parse('$sidebandBase/${call.callId}'),
          headers,
        );
      } catch (e) {
        throw LiveCallException(
          'sideband rejected: ${redactSecrets('$e')} (an invalid session config kills the call silently)',
        );
      }
      if (_closed || s.closed || s.connectionLost) {
        // This socket did not exist when the session's cached close ran.
        // Retire the newly acquired resource before publishing it anywhere.
        try {
          await ws.close();
        } catch (_) {}
        throw LiveCallException('live session retired during sideband connection');
      }
      if (timed) timings.sideband = sw.elapsed;
      s.ws = ws;
      s.contextDelivery = LiveContextDeliveryQueue(
        send: (event) => ws.send(jsonEncode(event)),
        onDiagnostic: Platform.environment['WOI_LIVE_CONTEXT_TRACE'] == '1'
            ? (metadata) => debugPrint(
                'gpt-live context ${jsonEncode({'call_id': s.callId, 'time_ms': DateTime.now().millisecondsSinceEpoch, ...metadata})}',
              )
            : null,
        onError: (message, code, fatal) {
          if (!_closed && identical(_session, s)) {
            _emit(
              BackendError(redactSecrets(message), code: code, fatal: fatal),
            );
          }
        },
      );
      if (s.closed) throw LiveCallException('closed while connecting');
      s.sub = ws.messages.listen(
        (raw) => _onSessionEvent(s, raw, rtcControl: false),
        onDone: () => _sessionConnectionLost(s, ws.closeCode, ws.closeReason),
        onError: (Object _) =>
            _sessionConnectionLost(s, ws.closeCode, 'sideband stream error'),
      );
      await Future.wait<void>([
        s.started.future,
        if (rtcEvents != null) rtcEvents.waitForControlReady(),
      ]).timeout(
        sessionStartTimeout,
        onTimeout: () => throw LiveCallException(
          'live session events not ready within ${sessionStartTimeout.inSeconds}s',
        ),
      );
      if (_closed || s.closed || s.connectionLost) {
        throw LiveCallException('live session closed while connecting');
      }
      return s;
    } catch (_) {
      await s.close();
      rethrow;
    } finally {
      if (identical(_preparing, s)) _preparing = null;
    }
  }

  /// The sideband of the live call closed on its own (e.g. 1006 = the TCP
  /// connection dropped without a close frame). Unblock everything that was
  /// in flight and report a reconnectable loss; the pipeline reconnects with
  /// backoff and restores the context (summary + recent turns).
  void _onConnectionLost(int? code, String? reason, {bool controlFailure = false}) {
    debugPrint('gpt-live ${controlFailure ? 'control channel' : 'sideband'} closed (${code ?? '-'} ${reason ?? ''})');
    if (controlFailure) _retirePendingReply(requireFresh: true);
    _session?.contextDelivery?.close();
    _executor?.cancelPending();
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
        controlFailure
            ? 'Live result delivery disconnected. Reconnect before sending more. Saved results were not replayed.'
            : 'gpt-live connection lost (${code ?? '-'}${reason == null || reason.isEmpty ? '' : ' $reason'})',
        code: controlFailure ? 'live_control_channel_lost' : 'connection_lost',
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
    if (_closed || _config == null || _nativeCaptureReleaseFailed) {
      return Future.value(
        const ContextApplyResult(ContextApplyMethod.skipped, detail: 'not connected or capture release unconfirmed'),
      );
    }
    _summary = summary.trim();
    final owned = _pendingApply?.owner == null ? null : _pendingApply;
    if (_discardRetiredReplies && owned == null) {
      return Future.value(
        const ContextApplyResult(ContextApplyMethod.skipped, detail: 'voice input awaits a fresh request'),
      );
    }
    final written = _guardCurrent(_appliedWrittenCurrent) ? _appliedWrittenContext : '';
    // A normal compaction may update memory while mandatory preparation is
    // pending, but cannot replace its complete payload, ownership or guards.
    _pendingApply = _LiveContextApply(
      summary: _summary!,
      recent: recentTurns,
      written: owned?.written ?? written,
      isCurrent: owned?.isCurrent ?? (written.isEmpty ? null : _appliedWrittenCurrent),
      canApply: owned?.canApply,
      owner: owned?.owner,
    );
    final c = _applyDone ??= Completer<ContextApplyResult>();
    _scheduleApply(Duration.zero);
    return c.future;
  }

  static bool _guardCurrent(bool Function()? guard) {
    try {
      return guard?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  bool _applyCurrent(_LiveContextApply apply) => _guardCurrent(apply.isCurrent) && _guardCurrent(apply.canApply);

  @override
  FutureOr<bool> prepareTypedInputContext({
    required String writtenContext,
    required String recentContext,
    required bool Function() isCurrent,
  }) {
    if (_closed || _config == null || !_guardCurrent(isCurrent)) return false;
    if (_nativeCaptureReleaseFailed) {
      _reportNativeCaptureFailure();
      return false;
    }
    // New input supersedes an unresolved old reply at an owned boundary.
    if (_pendingReply != null) _retirePendingReply(requireFresh: true);
    if (writtenContext == _appliedWrittenContext && !_requiresFreshReplyContext) {
      _appliedWrittenCurrent = isCurrent;
      return true;
    }
    final owner = Object();
    final generation = _actionGeneration;
    var retired = false;
    bool current() => !retired && !_closed && generation == _actionGeneration && _guardCurrent(isCurrent);
    _noteActivity();
    final activity = _activity;
    _pendingApply = _LiveContextApply(
      summary: _summary ?? '',
      recent: _requiresFreshReplyContext
          ? 'Earlier unfinished requests were stopped or superseded. Do not resume them; answer only the next new request.\n$recentContext'
          : recentContext,
      written: writtenContext,
      isCurrent: current,
      // Any intervening user/assistant activity makes this input snapshot
      // ambiguous. Keep the draft instead of guessing which turn it follows.
      canApply: () => _activity == activity,
      owner: owner,
    );
    final c = _applyDone ??= Completer<ContextApplyResult>();
    _scheduleApply(Duration.zero);
    return () async {
      var accepted = false;
      try {
        final result = await c.future.timeout(typedContextPrepareTimeout);
        accepted =
            result.method == ContextApplyMethod.reconnected && identical(_appliedContextOwner, owner) && current();
      } catch (_) {
        // A failed/expired context refresh never turns into a contextless send.
      }
      if (!accepted) {
        retired = true;
        _retireOwnedApply(owner);
        if (_discardRetiredReplies && !_nativeCaptureReleaseFailed) {
          _noticeVoiceRecovery(reason: 'Context preparation did not finish.');
        }
      }
      return accepted;
    }();
  }

  void _retireOwnedApply(Object owner) {
    if (!identical(_pendingApply?.owner, owner)) return;
    _applyTimer?.cancel();
    final preparing = _preparing;
    if (preparing != null) unawaited(preparing.close());
    _finishApply(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'input context retired'));
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
      _pendingReply == null &&
      (_session?.contextDelivery?.isIdle ?? true) &&
      !_player.isPlaying;

  bool get _quiet => _idle && DateTime.now().difference(_lastActivity) >= swapQuiet;

  void _scheduleApply([Duration? delay]) {
    _applyTimer?.cancel();
    _applyTimer = Timer(delay ?? swapPoll, _tryApply);
  }

  void _tryApply() {
    final want = _pendingApply;
    if (want == null || _swapping) return;
    if (_closed || _nativeCaptureReleaseFailed || !_applyCurrent(want)) {
      _finishApply(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'context no longer current'));
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
    final batch = _applyDone;
    var result = const ContextApplyResult(ContextApplyMethod.skipped, detail: 'conversation kept moving');
    try {
      for (var attempt = 0; attempt < swapAttempts; attempt++) {
        while (!_closed && identical(batch, _applyDone) && !_quiet) {
          final waiting = _pendingApply;
          if (waiting == null || !_applyCurrent(waiting)) break;
          await Future<void>.delayed(swapPoll);
        }
        if (!identical(batch, _applyDone)) break;
        final want = _pendingApply;
        final cfg = _config;
        if (_closed || want == null || cfg == null || !_applyCurrent(want)) {
          result = const ContextApplyResult(ContextApplyMethod.skipped, detail: 'context no longer current');
          break;
        }
        final activity = _activity;
        final _LiveSession next;
        try {
          if (want.owner != null) {
            // Mandatory typed preparation owns a replacement, not overlapping
            // native capture. Muting a track alone does not release its device.
            final old = _session;
            _retirePendingReply(requireFresh: true);
            if (old != null) {
              if (!old.closed) {
                try {
                  await old.rtc.setCaptureSuspended(true);
                } catch (_) {
                  // Native teardown can clear its references before failing.
                  // A later retry must not treat that empty state as proof of
                  // release and open a second capture on this backend.
                  _nativeCaptureReleaseFailed = true;
                  if (!_closed && identical(batch, _applyDone) && _applyCurrent(want)) {
                    _reportNativeCaptureFailure();
                  }
                  result = const ContextApplyResult(
                    ContextApplyMethod.skipped,
                    detail: 'native capture release unconfirmed',
                  );
                  break;
                }
              }
              if (_closed || !identical(batch, _applyDone) || !_applyCurrent(want)) {
                await old.close();
                break;
              }
              await old.close();
              if (_closed || !identical(batch, _applyDone) || !_applyCurrent(want)) break;
            }
          }
          final recent = [
            if (want.recent?.trim().isNotEmpty ?? false) want.recent!,
            if (want.written.isNotEmpty) want.written,
          ].join('\n\n');
          next = await _openSession(
            cfg,
            composeInstructions(cfg.instructions, want.summary, recent, note: _pinnedNote),
            activate: false,
          );
        } catch (e) {
          result = ContextApplyResult(ContextApplyMethod.skipped, detail: 'reconnect failed: $e');
          if (want.owner != null) break;
          continue;
        }
        if (_closed || !identical(batch, _applyDone) || !_applyCurrent(want)) {
          await next.close();
          break;
        }
        if (activity != _activity || !_idle || !identical(want, _pendingApply)) {
          await next.close();
          continue;
        }
        _appliedWrittenContext = want.written;
        _appliedWrittenCurrent = want.isCurrent;
        _appliedContextOwner = want.owner;
        _swapTo(next);
        result = ContextApplyResult(ContextApplyMethod.reconnected, detail: 'call ${next.callId}');
        break;
      }
    } finally {
      _swapping = false;
      // Stop can finish this batch immediately while its socket still opens.
      // That retired preparation must not finish or clear a newer request.
      if (identical(batch, _applyDone)) {
        _finishApply(result);
      } else if (_pendingApply != null) {
        _scheduleApply(Duration.zero);
      }
    }
  }

  /// Makes [next] the live call (synchronously, between turns) and closes
  /// the old one.
  void _swapTo(_LiveSession next) {
    final old = _session;
    _session = next;
    _requiresFreshReplyContext = false;
    _discardRetiredReplies = false;
    _voiceRecoveryNoticeSent = false;
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

  void _onSideband(Map<String, Object?> ev) {
    _session?.contextDelivery?.handleEvent(ev);
    final type = ev['type'];
    if (_discardRetiredReplies &&
        (type == 'session.output_audio.delta' ||
            type == 'session.input_audio.append' ||
            type == 'output_transcript.added' ||
            type == 'input_transcript.added' ||
            type == 'turn.created' ||
            type == 'turn.delta' ||
            type == 'turn.done')) {
      return;
    }
    switch (type) {
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
        _touchPendingReply(progress: _itemText(ev).trim().isNotEmpty);
        _openAssistant(_int(ev['start_ms']));
        final t = _itemText(ev);
        if (t.isNotEmpty && !_dropTurn) _emit(AssistantTranscriptDelta(t));
        _markSpoken();
      case 'turn.created':
        final turn = _map(ev['turn']);
        if (turn['role'] == 'user') {
          _bindUserTurn('${turn['id'] ?? ''}');
        } else if (turn['role'] == 'assistant') {
          final reply = _pendingReply;
          final id = '${turn['id'] ?? ''}';
          if (reply != null && !reply.accepted) reply.canAssociate = false;
          if (reply != null && reply.accepted && reply.canAssociate && !_discardRetiredReplies && id.isNotEmpty) {
            if (reply.turnId == null) {
              reply.turnId = id;
              reply.responding = true;
              reply.completeBy = DateTime.now().add(responseCompletionTimeout);
            } else if (reply.turnId != id) {
              reply.canAssociate = false;
            }
          }
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
          final reply = _pendingReply;
          if (reply != null && reply.canAssociate && reply.turnId == '${turn['id'] ?? ''}' && text.isNotEmpty) {
            _retirePendingReply();
            if (_pendingApply != null) _scheduleApply(Duration.zero);
          }
          _closeAssistant(_int(turn['end_ms']), text);
        }
      case 'delegation.created':
        _onDelegation(ev);
      case 'delegation.context.appended':
        final id = '${ev['delegation_item_id'] ?? ''}';
        final w = _awaitingSpeech[id];
        if (w != null) w.$1.appended ??= w.$2.elapsed;
      case 'error':
        final err = _map(ev['error']);
        _emit(BackendError('gpt-live: ${err['message'] ?? 'error'}', code: err['code'] as String?));
      case 'session.context.appended' ||
          'session.usage.updated' ||
          'session.started' ||
          'session.updated' ||
          'turn.delta':
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
    _touchPendingReply(progress: pcm.any((byte) => byte != 0));
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
    _dropTurn = _dropping || _discardRetiredReplies;
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
    final session = _session;
    if (id.isEmpty || ex == null || session == null || session.closed) return;
    // Sideband duplicates must not execute the same tool request twice.
    if (!session.delegationIds.add(id)) return;
    _noteActivity();
    if (_dropping || _discardRetiredReplies) {
      debugPrint('gpt-live: declined delegation "$text" (user said stop)');
      unawaited(
        session.contextDelivery!
            .append(
              'Not done: the user said stop / cancel. Do nothing and say nothing.',
              delegationId: id,
              purpose: LiveTextPurpose.actionResult,
            )
            .then((accepted) {
              if (accepted && !_closed && identical(_session, session)) _settleLater();
            }),
      );
      return;
    }
    final sw = Stopwatch()..start();
    final generation = _actionGeneration;
    final typedGeneration = _typedInputGeneration;
    _pendingDelegations++;
    _runningActions++;
    final precedingReply = _pendingReply;
    final unambiguous =
        precedingReply == null ||
        (precedingReply.canAssociate && precedingReply.accepted && precedingReply.turnId == null);
    // The provider has handed this current request to bounded local work.
    // Running delegation ownership keeps compaction busy until its result is
    // appended; a live-answer silence timer must not expire during that work.
    if (precedingReply != null) _retirePendingReply();
    unawaited(() async {
      final DelegationReport report;
      try {
        report = await ex.execute(text, id: id);
      } finally {
        _runningActions--;
      }
      if (_closed || session.closed || !identical(_session, session) || generation != _actionGeneration) {
        _pendingDelegations--;
        return;
      }
      _awaitingSpeech[id] = (report, sw);
      if (typedGeneration != _typedInputGeneration) {
        _reportDelegation(id);
        return;
      }
      final pendingReply = _beginPendingReply(session, unambiguous: unambiguous);
      final accepted = await session.contextDelivery!.append(
        delegationResultNote(report),
        delegationId: id,
        purpose: LiveTextPurpose.actionResult,
      );
      _acceptPendingReply(pendingReply, accepted);
      debugPrint('live delegation "$text": ${report.timingSummary()}');
      if (!accepted) {
        _reportDelegation(id);
        return;
      }
      if (!_closed && identical(_session, session)) _settleLater();
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
  void sendText(String text) => _sendText(text);

  @override
  bool usesWrittenReferenceAnswer(String text, {required String referenceText}) {
    final ex = _executor;
    return ex != null &&
        referenceText.trim().isNotEmpty &&
        !_hasTypedAction(text.trim(), ex, hasAttachments: _pendingAttachmentImages.isNotEmpty);
  }

  bool _hasTypedAction(String text, DelegationExecutor ex, {required bool hasAttachments}) =>
      hasAttachments ||
      looksLikeAction(text) ||
      (ex.tools.any((tool) => tool.name == 'web_search') && needsWebLookup(text)) ||
      _asksAboutContextImages(text);

  @override
  void sendTextWithWrittenResult(
    String text, {
    required bool Function(WrittenResponse) onResult,
    String? referenceText,
    bool Function()? isReferenceCurrent,
  }) =>
      _sendText(text, onWrittenResult: onResult, referenceText: referenceText, isReferenceCurrent: isReferenceCurrent);

  void _sendText(
    String text, {
    bool Function(WrittenResponse)? onWrittenResult,
    String? referenceText,
    bool Function()? isReferenceCurrent,
  }) {
    _typedInputGeneration++;
    _noteActivity();
    final t = text.trim();
    if (t.isEmpty) return;
    // Typed turn -> "turn open" (first audio) latency in QA logs.
    debugPrint('gpt-live typed turn t=${DateTime.now().millisecondsSinceEpoch}');
    final ex = _executor;
    // Typed text never starts a delegation on gpt-live, so action requests
    // are carried out here and the model only voices the real outcome.
    final attachments = Map<String, DelegationImage>.of(_pendingAttachmentImages);
    if (ex != null && _hasTypedAction(t, ex, hasAttachments: attachments.isNotEmpty)) {
      if (_runTypedAction(t, ex, attachedImages: attachments.values.toList(), onWrittenResult: onWrittenResult)) {
        for (final entry in attachments.entries) {
          if (identical(_pendingAttachmentImages[entry.key], entry.value)) {
            _pendingAttachmentImages.remove(entry.key);
          }
        }
      }
      return;
    }
    if (ex != null && onWrittenResult != null && referenceText != null && referenceText.trim().isNotEmpty) {
      _runReferenceAnswer(t, ex, referenceText, isReferenceCurrent, onWrittenResult);
      return;
    }
    // No user-text item on this transport. Context without a channel makes
    // the model answer (the 'developer' channel is read silently; §3.2).
    _appendContext('The user typed (instead of speaking): $t');
  }

  /// "what do you see?" with the camera on, "what's in this image" with
  /// media open: only the delegation model can look, so it answers.
  /// "what's on my screen?" with a screenshot held (assist gesture, screen
  /// share, auto screenshot) likewise.
  bool _asksAboutContextImages(String t) =>
      isMediaQuestion(t) ||
      (_latestImage != null && isScreenQuestion(t)) ||
      mediaCaptureCommand(t) != null ||
      (_contextImages.containsKey('camera') && DelegationExecutor.needsScreen(t));

  _LivePendingReply _beginPendingReply(_LiveSession session, {bool unambiguous = true}) {
    final canAssociate =
        unambiguous && _pendingReply == null && !_assistantOpen && !_userSpeaking && _openUserKey == null;
    _retirePendingReply();
    final reply = _LivePendingReply(session, canAssociate: canAssociate);
    _pendingReply = reply;
    return reply;
  }

  void _acceptPendingReply(_LivePendingReply reply, bool accepted) {
    if (!identical(_pendingReply, reply)) return;
    if (!accepted || _closed || reply.session.closed || !identical(_session, reply.session)) {
      _retirePendingReply(requireFresh: !accepted);
      return;
    }
    reply.accepted = true;
    reply.deadline = DateTime.now().add(responseWaitTimeout);
    final poll = responseWaitTimeout < const Duration(milliseconds: 250)
        ? responseWaitTimeout
        : const Duration(milliseconds: 250);
    reply.timer = Timer.periodic(poll, (_) {
      if (!identical(_pendingReply, reply) || _closed || !identical(_session, reply.session)) {
        reply.timer?.cancel();
        return;
      }
      final now = DateTime.now();
      if (now.isBefore(reply.deadline!) && (reply.completeBy == null || now.isBefore(reply.completeBy!))) return;
      _retirePendingReply(requireFresh: true);
      _emit(
        BackendError(
          reply.responding
              ? 'The live reply stopped before it could be confirmed complete. Your request and attachments are saved. Reconnect, then resend your request.'
              : 'A live answer could not be confirmed. Your request and attachments are saved. Reconnect, then resend your request.',
          code: 'live_response_timeout',
          fatal: true,
        ),
      );
    });
  }

  void _touchPendingReply({required bool progress}) {
    if (!progress) return;
    final reply = _pendingReply;
    if (reply != null && !reply.accepted) reply.canAssociate = false;
    if (reply != null && reply.turnId != null && reply.canAssociate && !_discardRetiredReplies) {
      reply.deadline = DateTime.now().add(responseWaitTimeout);
    }
  }

  void _retirePendingReply({bool requireFresh = false}) {
    _pendingReply?.timer?.cancel();
    _pendingReply = null;
    if (requireFresh) {
      _requiresFreshReplyContext = true;
      _discardRetiredReplies = true;
      _rtc?.setMicEnabled(false);
      if (_assistantOpen) {
        _dropTurn = true;
        _interrupted = true;
      }
      _mute();
      // This call is intentionally disposable. A retired open turn must not
      // keep the owned fresh-context preparation waiting for its old done event.
      if (_assistantOpen) _finishAssistant();
    }
  }

  void _appendContext(String text, {LiveTextPurpose purpose = LiveTextPurpose.userMessage, String? channel}) {
    final session = _session;
    if (_closed || session == null || session.closed) return;
    final reply = channel == 'developer' ? null : _beginPendingReply(session);
    unawaited(
      session.contextDelivery!.append(text, purpose: purpose, channel: channel).then((accepted) {
        if (reply != null) _acceptPendingReply(reply, accepted);
        if (accepted && channel != 'developer' && !_closed && identical(_session, session)) _settleLater();
      }),
    );
  }

  void _runReferenceAnswer(
    String text,
    DelegationExecutor ex,
    String referenceText,
    bool Function()? isReferenceCurrent,
    bool Function(WrittenResponse) onWrittenResult,
  ) {
    final session = _session;
    if (_closed || session == null || session.closed) return;
    final generation = _actionGeneration;
    final typedGeneration = _typedInputGeneration;
    final userGeneration = _userSeq;
    final note = _pinnedNote;
    final savedReference = note == null || note.trim().isEmpty
        ? referenceText
        : '$referenceText\n\n${pinnedNoteBlock(note)}';
    bool referenceCurrent() {
      try {
        return isReferenceCurrent?.call() ?? false;
      } catch (_) {
        return false;
      }
    }

    _pendingDelegations++;
    _runningActions++;
    unawaited(() async {
      final DelegationReport report;
      try {
        report = referenceCurrent()
            ? await ex.answerFromReference(text, referenceText: savedReference, id: 'reference_${++_toolSeq}')
            : (DelegationReport(id: 'reference_${++_toolSeq}', request: text)
                ..model = ex.fastModel
                ..error = StateError('Saved reference changed.'));
      } finally {
        _pendingDelegations--;
        _runningActions--;
      }
      if (_closed || session.closed || !identical(_session, session) || generation != _actionGeneration) return;
      final current = referenceCurrent();
      if (!current) {
        report
          ..error = StateError('Saved reference changed.')
          ..answerText = ''
          ..resultText = 'The saved analysis changed. Ask the question again.';
      }
      final failed = !current || report.error != null || report.answerText.trim().isEmpty;
      final outcome = WrittenResponse(
        text: !current
            ? 'The saved analysis changed before I could verify the answer. Please ask your question again.'
            : failed
            ? 'I couldn’t answer from the saved analysis. It is still available in chat. Please try the question again.'
            : report.answerText.trim(),
        model: report.model,
        failed: failed,
      );
      debugPrint('live reference answer: ${report.timingSummary()}');
      var accepted = false;
      try {
        accepted = onWrittenResult(outcome);
      } catch (_) {
        _emit(const BackendError('The answer could not be saved. Please try your question again.'));
      }
      if (accepted && typedGeneration == _typedInputGeneration && userGeneration == _userSeq) {
        _appendContext(buildLiveReferenceReplyCue(outcome), purpose: LiveTextPurpose.actionResult);
      }
      if (!_delegations.isClosed) _delegations.add(report);
    }());
  }

  bool _runTypedAction(
    String text,
    DelegationExecutor ex, {
    List<DelegationImage> attachedImages = const [],
    bool Function(WrittenResponse)? onWrittenResult,
  }) {
    final session = _session;
    if (_closed || session == null || session.closed) return false;
    final generation = _actionGeneration;
    final typedGeneration = _typedInputGeneration;
    _pendingDelegations++;
    _runningActions++;
    unawaited(() async {
      final DelegationReport report;
      try {
        report = await ex.execute(
          text,
          id: 'typed_${++_toolSeq}',
          attachedImages: attachedImages,
          writtenImageAnswer: onWrittenResult != null,
        );
      } finally {
        _pendingDelegations--;
        _runningActions--;
      }
      if (_closed || session.closed || !identical(_session, session) || generation != _actionGeneration) return;
      debugPrint('live typed action "$text": ${report.timingSummary()}');
      if (onWrittenResult != null) {
        final answer = report.answerText.trim();
        final failed = report.error != null || answer.isEmpty;
        final written = failed
            ? report.tools.isEmpty
                  ? 'I couldn’t analyze this attachment. Please try sending it again.'
                  : 'I couldn’t finish the attachment analysis. Review the recorded tool results before sending it again.'
            : answer;
        // The result must survive a missing/rejected live narration. Preserve
        // provider diagnostics in the report, never in the user's error text.
        final outcome = WrittenResponse(text: written, model: report.model, failed: failed);
        var accepted = false;
        try {
          accepted = onWrittenResult(outcome);
        } catch (_) {
          _emit(const BackendError('The attachment analysis could not be saved. Please try sending it again.'));
        }
        // The full analysis is already visible under its originating request.
        // A single bounded cue avoids staging a second copy through Live,
        // where a receipt alone does not guarantee response activation.
        if (accepted && typedGeneration == _typedInputGeneration) {
          _appendContext(buildLiveAttachmentReplyCue(outcome), purpose: LiveTextPurpose.actionResult);
        }
        if (!_delegations.isClosed) _delegations.add(report);
        return;
      }
      if (typedGeneration != _typedInputGeneration) {
        if (!_delegations.isClosed) _delegations.add(report);
        return;
      }
      _appendContext(
        'The user typed: "$text". The app processed the request. Result: ${report.resultText}\n'
        'Tell the user the outcome in one short sentence, exactly as reported; if it failed or was not done, '
        'say so plainly. Do not start another action for this request.',
        purpose: LiveTextPurpose.actionResult,
      );
      if (!_delegations.isClosed) _delegations.add(report);
    }());
    return true;
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
      if (_appliedWrittenContext.isNotEmpty && _guardCurrent(_appliedWrittenCurrent)) _appliedWrittenContext,
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
  void cancelPendingTools() {
    _actionGeneration++;
    final session = _session;
    if (session != null && !session.closed) {
      _retirePendingReply(requireFresh: true);
      _noticeVoiceRecovery();
    }
    if (_pendingApply != null) {
      _applyTimer?.cancel();
      final preparing = _preparing;
      if (preparing != null) unawaited(preparing.close());
      _finishApply(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'stopped'));
    }
    _pendingAttachmentImages.clear();
    _executor?.cancelPending();
    _session?.contextDelivery?.cancelPending();
  }

  void _reportNativeCaptureFailure() {
    if (_closed || _nativeCaptureFailureReported) return;
    _nativeCaptureFailureReported = true;
    _emit(
      const BackendError(
        'Microphone capture could not be released safely. Your message and attachments are kept. Reconnect before trying again.',
        code: 'live_capture_release_failed',
        fatal: true,
      ),
    );
  }

  void _noticeVoiceRecovery({String reason = 'Stopped.'}) {
    if (_voiceRecoveryNoticeSent || _closed) return;
    _voiceRecoveryNoticeSent = true;
    _emit(
      BackendError(
        '$reason Voice input is paused. Choose Reconnect before speaking again, or send a typed message to prepare a fresh session.',
        code: 'live_voice_paused',
      ),
    );
  }

  @override
  void cancelResponse() {
    // Ordinary speech/typed barge-in only silences narration. Explicit Stop
    // uses cancelPendingTools, so an approval or new question keeps its task.
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
    if (_nativeCaptureReleaseFailed) {
      throw StateError('Microphone capture release is unconfirmed. Reconnect before trying again.');
    }
    final m = _ManagedMic(this);
    _mics.add(m);
    // Opening the observation stream must preserve the current PTT/mute gate,
    // including a release while native capture is asynchronously resuming.
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
    _rtc?.setMicEnabled(enabled && !_discardRetiredReplies);
    if (enabled && _discardRetiredReplies) _noticeVoiceRecovery();
  }

  @override
  Future<void> setCaptureSuspended(bool suspended) async {
    if (_nativeCaptureReleaseFailed) {
      // Cleanup may request resume after a failed hold. Keep capture paused;
      // another hold cannot turn cleared native references into proof of release.
      if (suspended) {
        throw StateError('Microphone capture release is unconfirmed. Reconnect before trying again.');
      }
      return;
    }
    _captureSuspended = suspended;
    // Update the desired state synchronously. Sessions created during the
    // await inherit it before createOffer and cannot reacquire the device.
    try {
      await Future.wait([for (final session in _sessions.toList()) session.rtc.setCaptureSuspended(suspended)]);
    } catch (_) {
      if (suspended) {
        _nativeCaptureReleaseFailed = true;
        _retirePendingReply(requireFresh: true);
        _applyTimer?.cancel();
        _finishApply(
          const ContextApplyResult(ContextApplyMethod.skipped, detail: 'native capture release unconfirmed'),
        );
        _reportNativeCaptureFailure();
      }
      rethrow;
    }
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
    _retirePendingReply();
    _executor?.cancelPending();
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

class _LivePendingReply {
  _LivePendingReply(this.session, {required this.canAssociate});
  final _LiveSession session;
  bool canAssociate;
  bool accepted = false;
  bool responding = false;
  String? turnId;
  DateTime? deadline;
  DateTime? completeBy;
  Timer? timer;
}

class _LiveContextApply {
  const _LiveContextApply({
    required this.summary,
    required this.recent,
    required this.written,
    this.isCurrent,
    this.canApply,
    this.owner,
  });
  final String summary;
  final String? recent;
  final String written;
  final bool Function()? isCurrent;
  final bool Function()? canApply;
  final Object? owner;
}

// ------------------------------------------------------------------ helpers

/// One gpt-live call: WebRTC media plus its sideband socket.
class _LiveSession {
  _LiveSession(this.rtc, this.model, this.voice)
      : controlSource = rtc is LiveRtcEventSource ? rtc as LiveRtcEventSource : null;
  final LiveRtcEventSource? controlSource;
  final LiveRtcTransport rtc;
  final String model;
  final String voice;
  RealtimeSocket? ws;
  LiveContextDeliveryQueue? contextDelivery;
  final delegationIds = <String>{};
  StreamSubscription<String>? sub;
  StreamSubscription<String>? controlSub;
  bool connectionLost = false;
  String? callId;
  final started = Completer<void>();
  bool closed = false;
  void Function()? onClosed;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    closed = true;
    if (!started.isCompleted) started.complete();
    contextDelivery?.close();
    // Native release must begin even if a socket's close handshake is held.
    // Observe each eager future immediately, and join all cleanup before the
    // session relinquishes ownership. Capture-suspension errors are latched
    // separately by the backend before any replacement is allowed.
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (_) {}
    }
    final nativeClosed = attempt(rtc.close);
    try {
      ws?.send(jsonEncode({'type': 'session.close'}));
    } catch (_) {}
    await attempt(() async { await sub?.cancel(); });
    await attempt(() async { await controlSub?.cancel(); });
    await attempt(() async { await ws?.close(); });
    await nativeClosed;
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
