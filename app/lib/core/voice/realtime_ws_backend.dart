import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../audio/playback_tracker.dart';
import '../auth/auth.dart';
import '../context/context_manager.dart';
import '../context/image_tiers.dart' show kAssistNotePrefix, kRawRecentTurns;
import '../net/realtime_socket.dart';
import '../notes/pinned_note.dart';
import '../util/image_mime.dart';
import 'context_sync.dart';
import 'pinned_context.dart';
import 'voice_backend.dart';

class RealtimeException implements Exception {
  RealtimeException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => code == null ? message : '$message ($code)';
}

/// Error codes that are expected during normal operation and never surfaced.
const _benignErrors = {
  // Generation outruns playback: by the time the user interrupts, the
  // response is usually complete already (REALTIME_API.md §2.6).
  'response_cancel_not_active',
  'item_truncate_invalid_item_id',
  'item_delete_invalid_item_id',
};

/// Path A: OpenAI Realtime over WebSocket (`wss://api.openai.com/v1/realtime`),
/// authenticated with the ChatGPT access token or an API key.
///
/// See research/REALTIME_API.md §2. Highlights:
/// * server VAD + input transcription; audio streamed both ways as pcm16 24 kHz;
/// * function calls → [ToolCall]; [sendToolResult] answers with
///   `function_call_output` and issues `response.create` once every call of the
///   response is answered and no response is active;
/// * barge-in: on `speech_started` (or [cancelResponse]) the not-yet-heard
///   audio is dropped and the item is truncated to the played length, after
///   the cancelled `response.done` when a response is still running;
/// * usage from `response.done` → [Usage];
/// * automatic reconnect that restores the summary and recent turns;
/// * [applySummary]: compaction applied between responses with
///   `conversation.item.delete` (reconnect as a fallback).
class RealtimeWsBackend extends VoiceBackend implements LiveContextSync, PinnedNoteSync {
  RealtimeWsBackend({
    RealtimeConnector? connector,
    this.credentialsProvider,
    Uri? endpoint,
    this.transcriptionModel = 'gpt-4o-mini-transcribe',
    this.vadThreshold = 0.5,
    this.vadPrefixPaddingMs = 300,
    this.vadSilenceMs = 500,
    this.speakingVadThreshold = 0.3,
    this.speakingVadPrefixPaddingMs = 300,
    this.speakingVadSilenceMs = 400,
    this.maxFlushPrefixPaddingMs = 5000,
    this.noiseReduction = 'far_field',
    this.deferInterrupts = true,
    this.maxReconnectAttempts = 5,
    this.reconnectBaseDelay = const Duration(milliseconds: 500),
    this.connectTimeout = const Duration(seconds: 15),
    this.keepRecentTurns = kRawRecentTurns,
    PlaybackTracker? playback,
    void Function(String message)? log,
  }) : _connector = connector ?? IoRealtimeSocket.connect,
       endpoint = endpoint ?? defaultEndpoint,
       playback = playback ?? PlaybackTracker(),
       _log = log ?? ((m) => debugPrint('[realtime] $m'));

  static final defaultEndpoint = Uri.parse('wss://api.openai.com/v1/realtime');

  final RealtimeConnector _connector;

  /// Fresh credentials for every (re)connect (token refresh). Falls back to
  /// [SessionConfig.credentials].
  final Future<Credentials?> Function()? credentialsProvider;
  final Uri endpoint;
  final String transcriptionModel;
  final double vadThreshold;
  final int vadPrefixPaddingMs;
  final int vadSilenceMs;

  /// Server VAD while Woi is audible: more sensitive, so a short "stop" over
  /// the residual echo still raises speech_started. Extra echo starts are
  /// harmless: they are deferred and dropped by the pipeline.
  final double speakingVadThreshold;
  final int speakingVadPrefixPaddingMs;
  final int speakingVadSilenceMs;

  /// In-place compaction: how long each server confirmation may take, and
  /// how often (and how far apart) a failed apply is retried before it waits
  /// for the next reconnect.
  Duration applyConfirmTimeout = const Duration(seconds: 15);
  int maxApplyRetries = 3;
  Duration applyRetryDelay = const Duration(seconds: 30);
  String? _deferredSummary;
  int _applyRetries = 0;
  Timer? _applyRetryTimer;

  /// Upper bound of the widened prefix padding of the first turn after a
  /// pre-connect flush ([beginPreConnectFlush]). The API rejects more than
  /// 10000 ms (`integer above maximum value`), and at 10000 ms gpt-realtime-2.1
  /// failed with a server error and closed the socket; 5000 ms was fine.
  final int maxFlushPrefixPaddingMs;

  /// `far_field`: laptop speakers + built-in mic (no headset detection yet).
  final String noiseReduction;

  /// interrupt_response / create_response false while Woi speaks
  /// ([SpeechStarted.deferred]).
  bool deferInterrupts;
  final int maxReconnectAttempts;
  final Duration reconnectBaseDelay;
  final Duration connectTimeout;

  /// User turns kept verbatim when a compaction summary is applied.
  final int keepRecentTurns;
  final PlaybackTracker playback;
  final void Function(String) _log;

  final _events = StreamController<BackendEvent>.broadcast();

  @override
  ContextAccounting get contextAccounting => ContextAccounting.usage;
  RealtimeSocket? _ws;
  StreamSubscription<String>? _wsSub;
  SessionConfig? _config;
  int _generation = 0;
  bool _closed = false;
  bool _ready = false;
  bool _reconnecting = false;
  Completer<void>? _handshake;
  int _idSeq = 0;

  // Response state
  String? _activeResponseId;
  bool _responseRequested = false;
  bool _wantResponse = false;
  bool _cancelSent = false;
  bool _cancelOnCreate = false;
  bool _userSpeaking = false;
  final Set<String> _pendingCalls = {};
  final Set<String> _emittedCalls = {};
  final Map<String, String> _staleCallNames = {};
  final Map<String, String> _callNames = {};

  // Barge-in state
  String? _suppressResponseId;
  final Set<String> _suppressedItems = {};
  final List<Map<String, Object?>> _truncateAfterDone = [];

  // Server conversation mirror (ids in order + a text rendering of each)
  final List<_Item> _items = [];
  String? _summary;
  String? _summaryItemId;
  String? _pendingSummary;
  Completer<ContextApplyResult>? _pendingSummaryDone;
  bool _applyingSummary = false;
  final List<String> _applyErrors = [];
  final List<(bool Function(Map<String, Object?>), Completer<Map<String, Object?>>)> _waiters = [];

  // Pinned conversation note (part of the instructions; null = no notes).
  String? _pinnedNote;
  bool _pinnedDirty = false;

  /// Diagnostics.
  int pinnedRefreshes = 0;
  int reconnects = 0;
  int truncationsSent = 0;
  int cancelsSent = 0;
  final List<Map<String, Object?>> sentLog = [];
  bool recordSent = false;

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  bool get hasServerVad => true;

  bool get isReady => _ready;
  bool get responseActive => _activeResponseId != null || _responseRequested;

  @override
  bool get busy => responseActive || _reconnecting;
  String? get appliedSummary => _summary;
  List<String> get serverItemIds => [for (final i in _items) i.id];

  void _emit(BackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ------------------------------------------------------------- pinned note

  String _instructions(SessionConfig c) =>
      _pinnedNote == null ? c.instructions : withPinnedNote(c.instructions, _pinnedNote);

  /// The note changed: the instructions are refreshed with `session.update`
  /// right away when no response is running, else right after it (before
  /// the next `response.create`), so every response sees the current note.
  @override
  void setPinnedNote(String? markdown) {
    if (markdown == _pinnedNote) return;
    _pinnedNote = markdown;
    _pinnedDirty = true;
    if (_activeResponseId == null) _refreshPinnedNote();
  }

  void _refreshPinnedNote() {
    final cfg = _config;
    if (!_pinnedDirty || !_ready || cfg == null) return;
    _pinnedDirty = false;
    pinnedRefreshes++;
    _send({
      'type': 'session.update',
      'session': {'type': 'realtime', 'instructions': _instructions(cfg)},
    });
  }

  // ----------------------------------------------------------------- session

  @override
  Future<void> connect(SessionConfig config) async {
    _config = config;
    _closed = false;
    _pinnedNote = config.pinnedNote;
    _summary = config.priorContext?.trim().isEmpty ?? true ? null : config.priorContext!.trim();
    // The credentials sessionConfig just resolved (one auth file read, not
    // two); reconnects fetch fresh ones.
    final c = config.credentials;
    final exp = c?.expiresAt;
    final fresh = c != null && (exp == null || exp.difference(DateTime.now()) > const Duration(minutes: 2));
    await _open(initialContext: _summary == null ? null : _summaryText(_summary!), credentials: fresh ? c : null);
  }

  Map<String, Object?> sessionUpdate(SessionConfig c) => {
    'type': 'session.update',
    'session': {
      'type': 'realtime',
      'instructions': _instructions(c),
      'output_modalities': ['audio'],
      'audio': {
        'input': {
          'format': {'type': 'audio/pcm', 'rate': kVoiceSampleRate},
          'noise_reduction': {'type': noiseReduction},
          'transcription': {'model': transcriptionModel},
          'turn_detection': _turnDetection(speaking: false),
        },
        'output': {
          'format': {'type': 'audio/pcm', 'rate': kVoiceSampleRate},
          'voice': c.voice,
        },
      },
      'tools': [for (final t in c.tools) t.toJson()],
      'tool_choice': 'auto',
    },
  };

  /// Server VAD. While Woi speaks ([deferInterrupts]) it neither cuts the
  /// response nor answers a turn by itself: residual echo would do both.
  Map<String, Object?> _turnDetection({required bool speaking}) => {
    'type': 'server_vad',
    'threshold': speaking && deferInterrupts ? speakingVadThreshold : vadThreshold,
    'prefix_padding_ms': speaking && deferInterrupts
        ? speakingVadPrefixPaddingMs
        : (_flushPaddingMs ?? vadPrefixPaddingMs),
    'silence_duration_ms': speaking && deferInterrupts ? speakingVadSilenceMs : vadSilenceMs,
    'create_response': !speaking,
    'interrupt_response': !speaking,
  };

  /// Prefix padding of the first turn after a pre-connect flush: it reaches
  /// back to the start of the flushed audio. Null otherwise.
  int? _flushPaddingMs;

  @override
  void beginPreConnectFlush(int bufferedMs, {int? firstVoicedMs}) {
    if (!_ready || bufferedMs <= 0) return;
    // From the end of the flushed audio back to just before its first speech
    // (or its start): never into audio before the first utterance.
    final reach = firstVoicedMs == null ? bufferedMs : max(0, bufferedMs - firstVoicedMs);
    _flushPaddingMs = min(maxFlushPrefixPaddingMs, max(vadPrefixPaddingMs, reach + vadPrefixPaddingMs));
    _log(
      'pre-connect flush of $bufferedMs ms (first voiced at ${firstVoicedMs ?? '?'} ms): '
      'first turn prefix padding $_flushPaddingMs ms',
    );
    _sendTurnDetection();
  }

  @override
  void endPreConnectFirstTurn() {
    if (_flushPaddingMs == null) return;
    _log('pre-connect flush: first utterance over, normal prefix padding');
    _endFlushPadding();
  }

  /// The assistant panel is closed and the mic off ([setIdle]).
  bool _panelIdle = false;

  @override
  void setIdle(bool idle) {
    if (_panelIdle == idle) return;
    _panelIdle = idle;
    if (!idle) return;
    _flushPaddingMs = null;
    if (_userSpeaking && _ready) {
      // The mic closed mid-utterance: drop the half turn instead of leaving
      // it open (no more audio comes to end it).
      _send({'type': 'input_audio_buffer.clear'});
      _userSpeaking = false;
    }
  }

  /// The first turn after the flush started: normal padding from now on.
  void _endFlushPadding() {
    if (_flushPaddingMs == null) return;
    _flushPaddingMs = null;
    if (_ready) _sendTurnDetection();
  }

  void _sendTurnDetection() => _send({
    'type': 'session.update',
    'session': {
      'type': 'realtime',
      'audio': {
        'input': {'turn_detection': _turnDetection(speaking: _deferSent)},
      },
    },
  });

  /// What the client asked for last / what the server last confirmed.
  bool _deferSent = false;
  bool _deferActive = false;
  Timer? _deferOffTimer;

  // A turn the server started in defer mode: undecided until [acceptTurn]
  // or [dropEchoTurn]; an accepted one is answered when it ends.
  bool _deferredTurn = false;
  bool _turnAccepted = false;

  void _setDefer(bool on) {
    _deferOffTimer?.cancel();
    _deferOffTimer = null;
    if (!deferInterrupts || !_ready || on == _deferSent) return;
    _deferSent = on;
    _sendTurnDetection();
  }

  /// Back to normal turn taking once the reply's audio and its echo tail
  /// are over.
  void _deferOffLater() {
    if (!_deferSent) return;
    final left = playback.unheard().fold<int>(0, (a, u) => max(a, u.receivedMs - u.playedMs));
    _deferOffTimer?.cancel();
    _deferOffTimer = Timer(Duration(milliseconds: left + 1300), () {
      _deferOffTimer = null;
      if (_activeResponseId == null && !_responseRequested && !_deferredTurn) _setDefer(false);
    });
  }

  @override
  void acceptTurn() {
    if (!_deferredTurn) return;
    _deferredTurn = false;
    _turnAccepted = true;
    if (!_userSpeaking) _answerAccepted();
  }

  void _answerAccepted() {
    _turnAccepted = false;
    if (_pendingCalls.isEmpty) _requestResponse();
    _deferOffLater();
  }

  Future<void> _open({String? initialContext, Credentials? credentials}) async {
    final cfg = _config!;
    final sw = Stopwatch()..start();
    var mark = 0;
    void phase(String name) {
      final now = sw.elapsedMilliseconds;
      _log('connect phase: $name ${now - mark} ms (total $now ms)');
      mark = now;
    }

    final creds = credentials ?? (credentialsProvider != null ? await credentialsProvider!() : cfg.credentials);
    phase('credentials');
    if (creds == null) {
      throw RealtimeException('Not signed in: no Codex login (~/.codex/auth.json) or API key configured');
    }
    final uri = endpoint.replace(queryParameters: {...endpoint.queryParameters, 'model': cfg.model});
    final gen = ++_generation;
    _resetSessionState();
    final RealtimeSocket ws;
    try {
      ws = await _connector(uri, creds.headers()).timeout(connectTimeout);
      phase('socket');
    } catch (e) {
      throw RealtimeException('Cannot connect to ${uri.host}: ${redactSecrets('$e')}');
    }
    if (gen != _generation) {
      await ws.close();
      throw RealtimeException('connect superseded');
    }
    _ws = ws;
    final created = _handshake = Completer<void>();
    _wsSub = ws.messages.listen(
      (m) => _onMessage(gen, m),
      onDone: () => _onSocketDone(gen),
      onError: (Object e) => _log('socket error: ${redactSecrets('$e')}'),
    );
    try {
      await created.future.timeout(connectTimeout);
      phase('session.created');
      // Not awaited: the server applies client events in order, so audio and
      // items sent after this already get the configured session. Waiting
      // for session.updated cost 3-5 s on the phone (gpt-realtime-2.1).
      _pinnedDirty = false;
      _send(sessionUpdate(cfg));
      _updateSentAt = sw.elapsedMilliseconds;
      _updateWatch = sw;
    } catch (e) {
      _handshake = null;
      _generation++;
      await _wsSub?.cancel();
      _wsSub = null;
      _ws = null;
      unawaited(ws.close().catchError((_) {}));
      if (e is RealtimeException) rethrow;
      if (e is TimeoutException) throw RealtimeException('Realtime session setup timed out');
      throw RealtimeException(redactSecrets('$e'));
    }
    _handshake = null;
    _ready = true;
    phase('ready');
    if (initialContext != null && initialContext.isNotEmpty) {
      final id = _newItemId('ctx');
      _summaryItemId = id;
      _send({'type': 'conversation.item.create', 'item': _systemItem(id, initialContext)});
    }
  }

  /// input_audio_buffer.append messages sent on this socket (diagnostics:
  /// where an image went relative to the audio).
  int _audioAppends = 0;

  /// Connect diagnostics: when the first session.update went out.
  Stopwatch? _updateWatch;
  int _updateSentAt = 0;

  void _resetSessionState() {
    _ready = false;
    _audioAppends = 0;
    // A new session counts its input audio from zero.
    _tape.clear();
    _turnStartMs.clear();
    _turnSpanMs.clear();
    _activeResponseId = null;
    _responseRequested = false;
    _wantResponse = false;
    _cancelSent = false;
    _cancelOnCreate = false;
    _userSpeaking = false;
    _deferSent = false;
    _deferActive = false;
    _flushPaddingMs = null;
    _deferOffTimer?.cancel();
    _deferOffTimer = null;
    _deferredTurn = false;
    _turnAccepted = false;
    _staleCallNames.addAll({for (final c in _pendingCalls) c: _callNames[c] ?? 'tool'});
    _pendingCalls.clear();
    _suppressResponseId = null;
    _suppressedItems.clear();
    _truncateAfterDone.clear();
    _items.clear();
    _summaryItemId = null;
    for (final w in _waiters) {
      if (!w.$2.isCompleted) w.$2.completeError(RealtimeException('session closed'));
    }
    _waiters.clear();
  }

  void _onSocketDone(int gen) {
    if (gen != _generation) return;
    final code = _ws?.closeCode, reason = _ws?.closeReason;
    _ready = false;
    final hs = _handshake;
    if (hs != null && !hs.isCompleted) {
      hs.completeError(
        RealtimeException('Realtime socket closed during setup (code $code${reason == null ? '' : ': $reason'})'),
      );
      return;
    }
    if (_closed) return;
    _log('socket closed unexpectedly (code $code)');
    // Unblock the pipeline: whatever was in flight is gone.
    if (_activeResponseId != null || _responseRequested) _emit(const ResponseDone(cancelled: true));
    if (_userSpeaking) _emit(const SpeechStopped());
    unawaited(_reconnect('connection lost (code $code)'));
  }

  Future<void> _reconnect(String why) async {
    if (_reconnecting || _closed) return;
    final deferred = _deferredSummary;
    if (deferred != null && !_panelIdle) {
      // A compaction that could not be applied in place goes in now.
      _deferredSummary = null;
      _applyRetryTimer?.cancel();
      final cut = _cutIndex();
      _summary = deferred;
      return _reconnectWith(why, _restoreContext(fromIndex: cut));
    }
    if (_panelIdle) {
      // Warm but unused: no reconnect storm in the background; the next
      // activation connects.
      _log('idle: not reconnecting ($why)');
      _emit(BackendError('Voice $why while idle', code: kIdleClosedCode, fatal: true));
      return;
    }
    return _reconnectWith(why, _restoreContext());
  }

  Future<void> _reconnectWith(String why, String? context) async {
    _reconnecting = true;
    _emit(BackendError('Voice $why; reconnecting…', code: 'reconnecting'));
    Object? last;
    try {
      for (var attempt = 0; attempt < maxReconnectAttempts && !_closed; attempt++) {
        await Future<void>.delayed(reconnectBaseDelay * (1 << attempt));
        if (_closed) return;
        try {
          await _open(initialContext: context);
          reconnects++;
          _log('reconnected after ${attempt + 1} attempt(s)');
          return;
        } catch (e) {
          last = e;
          _log('reconnect attempt ${attempt + 1} failed: $e');
        }
      }
      if (!_closed) {
        _emit(BackendError('Could not reconnect to the voice service: $last', code: 'reconnect_failed', fatal: true));
      }
    } finally {
      _reconnecting = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _ready = false;
    _applyRetryTimer?.cancel();
    _applyRetryTimer = null;
    _generation++;
    final sub = _wsSub, ws = _ws;
    _wsSub = null;
    _ws = null;
    await sub?.cancel();
    try {
      await ws?.close();
    } catch (_) {}
    _resetSessionState();
    final p = _pendingSummaryDone;
    _pendingSummaryDone = null;
    if (p != null && !p.isCompleted) p.complete(const ContextApplyResult(ContextApplyMethod.skipped));
    for (final op in _imageOps) {
      if (!op.done.isCompleted) op.done.complete(null);
    }
    _imageOps.clear();
    await _events.close();
  }

  // ------------------------------------------------------------- client API

  void _send(Map<String, Object?> event) {
    final ws = _ws;
    if (ws == null) return;
    if (recordSent && event['type'] != 'input_audio_buffer.append') sentLog.add(event);
    ws.send(jsonEncode(event));
  }

  String _newItemId(String kind) => 'woi_${kind}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_idSeq++}';

  Map<String, Object?> _systemItem(String id, String text) => {
    'id': id,
    'type': 'message',
    'role': 'system',
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  };

  @override
  void sendAudio(Uint8List pcm16) {
    if (!_ready || pcm16.isEmpty) return;
    // Built by hand (12-25 times a second): base64 needs no JSON escaping,
    // and jsonEncode would scan and copy the whole payload again.
    _ws?.send('{"type":"input_audio_buffer.append","audio":"${base64Encode(pcm16)}"}');
    _audioAppends++;
    _tape.add(pcm16);
  }

  // Input audio of this session (the server's audio_start_ms/audio_end_ms
  // count from its first byte), for the user turns' clips ([turnAudio]).
  final _InputTape _tape = _InputTape(kVoiceBytesPerSecond * 120);
  final Map<String, int> _turnStartMs = {};
  final Map<String, (int, int)> _turnSpanMs = {};

  @override
  Uint8List? turnAudio(String? itemId) {
    final span = itemId == null ? null : _turnSpanMs[itemId];
    if (span == null) return null;
    const bytesPerMs = kVoiceBytesPerSecond ~/ 1000;
    // A little of the trailing silence, so the last word is not cut.
    return _tape.slice(span.$1 * bytesPerMs, (span.$2 + 250) * bytesPerMs);
  }

  void _noteTurnStart(Map<String, Object?> ev) {
    final id = ev['item_id'] as String?;
    final at = (ev['audio_start_ms'] as num?)?.toInt();
    if (id != null && at != null) _turnStartMs[id] = at;
  }

  // The silence that ends a turn as the server last confirmed it, and the
  // smoothed lag of its speech_stopped behind the audio sent.
  int? _activeSilenceMs;
  double? _uplinkLagMs;

  @override
  int? get uplinkLagMs => _uplinkLagMs?.round();

  /// speech_stopped comes [_activeSilenceMs] after the speech ended
  /// (audio_end_ms); whatever more of the audio was sent by then is still
  /// queued on the way (or in the server's backlog).
  void _noteUplinkLag(Map<String, Object?> ev) {
    final end = (ev['audio_end_ms'] as num?)?.toInt();
    final silence = _activeSilenceMs ?? vadSilenceMs;
    if (end == null || _tape.endMs < end) return;
    final lag = max(0, _tape.endMs - end - silence).toDouble();
    final prev = _uplinkLagMs;
    _uplinkLagMs = prev == null ? lag : prev * 0.5 + lag * 0.5;
  }

  void _noteTurnEnd(Map<String, Object?> ev) {
    final id = ev['item_id'] as String?;
    final end = (ev['audio_end_ms'] as num?)?.toInt();
    final start = id == null ? null : _turnStartMs.remove(id);
    if (id == null || start == null || end == null || end <= start) return;
    _turnSpanMs[id] = (start, end);
    while (_turnSpanMs.length > 64) {
      _turnSpanMs.remove(_turnSpanMs.keys.first);
    }
  }

  @override
  void sendText(String text) {
    if (!_ready) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    _requestResponse();
  }

  /// Adds an image to the conversation. Does not trigger a response: the turn
  /// it belongs to is answered by server VAD (or by the tool round trip).
  @override
  String? sendImage(Uint8List png, {String? note}) {
    if (!_ready) return null;
    final id = _newItemId('img');
    _send({'type': 'conversation.item.create', 'item': _imageItem(id, png, note)});
    _log(
      'send order: conversation.item.create input_image $id (${png.length ~/ 1024} KB) after $_audioAppends audio appends this session',
    );
    return id;
  }

  Map<String, Object?> _imageItem(String id, Uint8List png, String? note) => {
    'id': id,
    'type': 'message',
    'role': 'user',
    'content': [
      {'type': 'input_image', 'image_url': 'data:${imageMimeOf(png)};base64,${base64Encode(png)}'},
      if (note != null && note.isNotEmpty) {'type': 'input_text', 'text': note},
    ],
  };

  final _imageOps = <({String itemId, Uint8List? png, String? text, Completer<String?> done})>[];

  /// Screenshot tiers: inserts the smaller copy (or a system note with the
  /// description) right after [itemId] and deletes [itemId], between
  /// responses, exactly like the summary swap.
  @override
  Future<String?> replaceImage(String itemId, {Uint8List? png, String? text}) {
    if (_closed) return Future.value(null);
    final done = Completer<String?>();
    _imageOps.add((itemId: itemId, png: png, text: text, done: done));
    scheduleMicrotask(_maybeApplySummary);
    return done.future;
  }

  /// Image items replaced so far (diagnostics/tests).
  int imagesReplaced = 0;

  Future<void> _applyImageOpsNow() async {
    _applyingSummary = true;
    _applyErrors.clear();
    try {
      while (_imageOps.isNotEmpty && !_closed) {
        final op = _imageOps.removeAt(0);
        try {
          op.done.complete(await _replaceItem(op.itemId, op.png, op.text));
        } catch (e) {
          _log('image replace failed: $e');
          _applyErrors.clear();
          op.done.complete(null);
        }
      }
    } finally {
      _applyingSummary = false;
      _applyErrors.clear();
      _maybeCreateResponse();
      _maybeApplySummary();
    }
  }

  Future<String?> _replaceItem(String itemId, Uint8List? png, String? text) async {
    if (_itemById(itemId) == null) return null; // compacted or from an old socket
    final newId = _newItemId(png != null ? 'img' : 'ctx');
    final item = png != null
        ? _imageItem(newId, png, text)
        : _systemItem(newId, text ?? 'Earlier screenshot (removed).');
    final added = _waitFor(
      (e) =>
          (e['type'] == 'conversation.item.added' || e['type'] == 'conversation.item.created') &&
          (e['item'] as Map?)?['id'] == newId,
      const Duration(seconds: 8),
    );
    _send({'type': 'conversation.item.create', 'previous_item_id': itemId, 'item': item});
    await added;
    if (_applyErrors.isNotEmpty) throw RealtimeException(_applyErrors.join('; '));
    final deleted = _waitFor(
      (e) => e['type'] == 'conversation.item.deleted' && e['item_id'] == itemId,
      const Duration(seconds: 5),
    );
    _send({'type': 'conversation.item.delete', 'item_id': itemId});
    await deleted;
    imagesReplaced++;
    return newId;
  }

  @override
  void sendToolResult(String callId, String jsonOutput) {
    if (!_ready) return;
    if (_pendingCalls.remove(callId)) {
      _send({
        'type': 'conversation.item.create',
        'item': {'type': 'function_call_output', 'call_id': callId, 'output': jsonOutput},
      });
    } else {
      // The call belongs to a previous socket (reconnect): its id is unknown
      // to this session, so pass the result as context instead.
      final name = _staleCallNames.remove(callId) ?? _callNames[callId] ?? 'tool';
      _send({
        'type': 'conversation.item.create',
        'item': _systemItem(_newItemId('res'), 'Result of the earlier $name call: $jsonOutput'),
      });
    }
    _requestResponse();
  }

  @override
  void playbackPaused(bool paused) => paused ? playback.pause() : playback.resume();

  @override
  void cancelResponse() {
    _interruptPlayback();
    _wantResponse = false;
    if (_activeResponseId != null) {
      if (!_cancelSent) {
        _cancelSent = true;
        cancelsSent++;
        _send({'type': 'response.cancel'});
      }
    } else if (_responseRequested) {
      _cancelOnCreate = true;
    }
  }

  /// "Stop": cancel what runs now and any response the server creates for
  /// the stop utterance itself during the next few seconds.
  @override
  void stopAndDrop() {
    cancelResponse();
    _dropResponsesUntil = DateTime.now().add(const Duration(seconds: 3));
  }

  DateTime? _dropResponsesUntil;

  @override
  void dropEchoTurn({String? itemId, List<String> callIds = const []}) {
    // The reply to the echo is normally under way (or done) by the time its
    // transcript is final: cancel it; only a reply not created yet is caught
    // by the short drop window.
    if (_deferredTurn) {
      // Defer mode: nothing was cut and nothing answers the echo; Woi
      // talks on. Only the server's user item goes.
      _deferredTurn = false;
      _deferOffLater();
    } else {
      final pending = _activeResponseId != null || _responseRequested;
      cancelResponse();
      _dropResponsesUntil = pending ? null : DateTime.now().add(const Duration(milliseconds: 1500));
    }
    if (!_ready) return;
    for (final c in callIds) {
      if (!_pendingCalls.remove(c)) continue;
      _send({
        'type': 'conversation.item.create',
        'item': {
          'type': 'function_call_output',
          'call_id': c,
          'output': '{"skipped":"not run: the user turn was Woi\'s own voice heard back (echo)"}',
        },
      });
    }
    if (itemId != null && _itemById(itemId) != null) _send({'type': 'conversation.item.delete', 'item_id': itemId});
    echoTurnsDropped++;
  }

  /// User turns deleted as echo (diagnostics).
  int echoTurnsDropped = 0;

  void _requestResponse() {
    _dropResponsesUntil = null;
    _wantResponse = true;
    _maybeCreateResponse();
  }

  /// Never creates a response while one is active, tool calls are pending,
  /// the user is talking (server VAD will respond) or a compaction is applied.
  void _maybeCreateResponse() {
    if (!_wantResponse || !_ready) return;
    if (_activeResponseId != null || _responseRequested || _pendingCalls.isNotEmpty) return;
    if (_userSpeaking || _applyingSummary) return;
    _refreshPinnedNote();
    _wantResponse = false;
    _responseRequested = true;
    _send({'type': 'response.create'});
  }

  /// Local playback stops now: forget what has not been heard, suppress the
  /// rest of the running response and truncate the server items to what was
  /// actually played (after the cancelled response.done, if one is running).
  void _interruptPlayback() {
    final unheard = playback.unheard();
    playback.reset();
    if (_activeResponseId != null) _suppressResponseId = _activeResponseId;
    for (final u in unheard) {
      _suppressedItems.add(u.itemId);
      final ev = <String, Object?>{
        'type': 'conversation.item.truncate',
        'item_id': u.itemId,
        'content_index': 0,
        'audio_end_ms': u.playedMs,
      };
      if (_activeResponseId != null || _responseRequested) {
        _truncateAfterDone.add(ev);
      } else {
        _sendTruncate(ev);
      }
    }
  }

  void _sendTruncate(Map<String, Object?> ev) {
    truncationsSent++;
    _log('truncate ${ev['item_id']} at ${ev['audio_end_ms']} ms');
    _send(ev);
    _itemById(ev['item_id'] as String?)?.truncatedAtMs = ev['audio_end_ms'] as int;
  }

  // --------------------------------------------------------- server events

  void _onMessage(int gen, String raw) {
    if (gen != _generation) return;
    Map<String, Object?> ev;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return;
      ev = j.cast<String, Object?>();
    } catch (_) {
      return;
    }
    try {
      handleServerEvent(ev);
    } catch (e, st) {
      _log('event handling failed for ${ev['type']}: $e\n$st');
    }
    _onMessageWaiters(ev);
  }

  void _onMessageWaiters(Map<String, Object?> ev) {
    if (_waiters.isEmpty) return;
    for (final w in List.of(_waiters)) {
      if (w.$1(ev)) {
        _waiters.remove(w);
        if (!w.$2.isCompleted) w.$2.complete(ev);
      }
    }
  }

  /// Visible for tests.
  @visibleForTesting
  void handleServerEvent(Map<String, Object?> ev) {
    final type = ev['type'] as String? ?? '';
    switch (type) {
      case 'session.created':
      case 'session.updated':
        final td = (((ev['session'] as Map?)?['audio'] as Map?)?['input'] as Map?)?['turn_detection'];
        if (td is Map && td['interrupt_response'] is bool) _deferActive = td['interrupt_response'] == false;
        if (td is Map && type == 'session.updated') {
          _log(
            'turn detection: prefix ${td['prefix_padding_ms']} ms, threshold ${td['threshold']}, silence ${td['silence_duration_ms']} ms',
          );
        }
        if (td is Map && td['silence_duration_ms'] is num) {
          _activeSilenceMs = (td['silence_duration_ms'] as num).toInt();
        }
        final hs = _handshake;
        if (hs != null && !hs.isCompleted) hs.complete();
        final uw = _updateWatch;
        if (type == 'session.updated' && uw != null) {
          _updateWatch = null;
          _log(
            'connect phase: session.updated ack ${uw.elapsedMilliseconds - _updateSentAt} ms after session.update (not awaited)',
          );
        }

      case 'input_audio_buffer.speech_started' when _deferActive && !_deferredTurn && !_turnAccepted:
        // The server did not cut Woi off: the pipeline decides whether this
        // is the user (local detector / transcript) or Woi's echo.
        _noteTurnStart(ev);
        _dropResponsesUntil = null;
        _userSpeaking = true;
        _deferredTurn = true;
        _emit(SpeechStarted(itemId: ev['item_id'] as String?, deferred: true));
      case 'input_audio_buffer.speech_started':
        _log('speech_started at ${ev['audio_start_ms']} ms of the input stream (sent ${_tape.endMs} ms)');
        _noteTurnStart(ev);
        // Stop local playback first (the pipeline does it on SpeechStarted);
        // the played position is frozen right now.
        _interruptPlayback();
        _dropResponsesUntil = null;
        _userSpeaking = true;
        _emit(SpeechStarted(itemId: ev['item_id'] as String?));
      case 'input_audio_buffer.speech_stopped':
        _noteUplinkLag(ev);
        _log(
          'speech_stopped at ${ev['audio_end_ms']} ms of the input stream (sent ${_tape.endMs} ms, '
          'uplink lag ${_uplinkLagMs?.round()} ms)',
        );
        _noteTurnEnd(ev);
        _endFlushPadding();
        _userSpeaking = false;
        // Server VAD creates the response, which includes any tool output.
        if (_pendingCalls.isEmpty) _wantResponse = false;
        _emit(SpeechStopped(itemId: ev['item_id'] as String?));
        // In defer mode the server does not answer: an accepted turn is
        // answered here.
        if (_turnAccepted && _deferActive) {
          _answerAccepted();
        } else if (_turnAccepted) {
          _turnAccepted = false;
        }

      case 'conversation.item.added' || 'conversation.item.created':
        _onItemAdded(ev);
      case 'conversation.item.done':
        final item = (ev['item'] as Map?)?.cast<String, Object?>();
        if (item != null) _itemById(item['id'] as String?)?.update(item);
      case 'conversation.item.deleted':
        _items.removeWhere((i) => i.id == ev['item_id']);
      case 'conversation.item.truncated':
        final it = _itemById(ev['item_id'] as String?);
        if (it != null) it.text = '${it.text} [interrupted]';

      case 'conversation.item.input_audio_transcription.delta':
        // Transcription runs asynchronously and usually finishes after the
        // response (or its function call) has started; item_id ties it back
        // to the user's turn.
        final d = ev['delta'] as String? ?? '';
        if (d.isNotEmpty) _emit(UserTranscriptDelta(d, itemId: ev['item_id'] as String?));
      case 'conversation.item.input_audio_transcription.completed':
        final t = (ev['transcript'] as String? ?? '').trim();
        _itemById(ev['item_id'] as String?)?.text = t;
        _emit(UserTranscriptDone(t, itemId: ev['item_id'] as String?));
      case 'conversation.item.input_audio_transcription.failed':
        _emit(UserTranscriptDone('', itemId: ev['item_id'] as String?));

      case 'response.created':
        final r = (ev['response'] as Map?)?.cast<String, Object?>();
        _activeResponseId = r?['id'] as String? ?? 'resp';
        _responseRequested = false;
        _cancelSent = false;
        _setDefer(true);
        final drop = _dropResponsesUntil;
        if (drop != null && DateTime.now().isBefore(drop)) _cancelOnCreate = true;
        if (_cancelOnCreate) {
          _cancelOnCreate = false;
          _suppressResponseId = _activeResponseId;
          _cancelSent = true;
          cancelsSent++;
          _send({'type': 'response.cancel'});
        }

      case 'response.output_audio.delta' || 'response.audio.delta':
        if (_suppressed(ev)) return;
        final b64 = ev['delta'] as String? ?? '';
        if (b64.isEmpty) return;
        final pcm = base64Decode(b64);
        playback.onAudio(ev['item_id'] as String? ?? '', pcm.length);
        _emit(AssistantAudioDelta(pcm));
      case 'response.output_audio_transcript.delta' ||
          'response.audio_transcript.delta' ||
          'response.output_text.delta':
        if (_suppressed(ev)) return;
        final d = ev['delta'] as String? ?? '';
        if (d.isNotEmpty) _emit(AssistantTranscriptDelta(d));
      case 'response.output_audio_transcript.done' || 'response.audio_transcript.done' || 'response.output_text.done':
        final t = ev['transcript'] as String? ?? ev['text'] as String? ?? '';
        final it = _itemById(ev['item_id'] as String?);
        if (it != null && it.text.isEmpty) it.text = t;
        if (_suppressed(ev)) return;
        _emit(AssistantTranscriptDone(t));

      case 'response.function_call_arguments.done':
        if (_suppressed(ev)) return;
        _emitToolCall(ev['call_id'] as String?, ev['name'] as String?, ev['arguments'] as String?);

      case 'response.done':
        _onResponseDone((ev['response'] as Map?)?.cast<String, Object?>() ?? const {});

      case 'error':
        _onError((ev['error'] as Map?)?.cast<String, Object?>() ?? const {});
    }
  }

  bool _suppressed(Map<String, Object?> ev) {
    final rid = ev['response_id'] as String?;
    if (rid != null && rid == _suppressResponseId) return true;
    final iid = ev['item_id'] as String?;
    return iid != null && _suppressedItems.contains(iid);
  }

  void _emitToolCall(String? callId, String? name, String? args) {
    if (callId == null || name == null || _emittedCalls.contains(callId)) return;
    _emittedCalls.add(callId);
    _callNames[callId] = name;
    _pendingCalls.add(callId);
    _emit(ToolCall(callId, name, args ?? '{}'));
  }

  void _onResponseDone(Map<String, Object?> r) {
    final id = r['id'] as String?;
    final status = r['status'] as String? ?? 'completed';
    final cancelled = status == 'cancelled';
    final suppressed = id != null && id == _suppressResponseId;
    if (!cancelled && !suppressed) {
      // Fallback in case function_call_arguments.done was missed.
      for (final o in (r['output'] as List? ?? const [])) {
        if (o is Map && o['type'] == 'function_call') {
          _emitToolCall(o['call_id'] as String?, o['name'] as String?, o['arguments'] as String?);
        }
      }
    }
    final u = (r['usage'] as Map?)?.cast<String, Object?>();
    if (u != null) {
      final inTok = (u['input_tokens'] as num?)?.toInt() ?? 0;
      final outTok = (u['output_tokens'] as num?)?.toInt() ?? 0;
      // input_tokens is the whole context the model saw; the reply joins it.
      _emit(Usage(inTok, outTok, inTok + outTok));
    }
    _activeResponseId = null;
    _responseRequested = false;
    _cancelSent = false;
    if (suppressed) _suppressResponseId = null;
    // Truncate only after the cancelled response.done (§2.6 ordering gotcha).
    final pending = List.of(_truncateAfterDone);
    _truncateAfterDone.clear();
    pending.forEach(_sendTruncate);
    _emit(ResponseDone(cancelled: cancelled || suppressed));
    _deferOffLater();
    _refreshPinnedNote();
    _maybeCreateResponse();
    _maybeApplySummary();
  }

  void _onError(Map<String, Object?> err) {
    final code = err['code'] as String?;
    final message = err['message'] as String? ?? 'unknown realtime error';
    _log('server error ${code ?? '-'}: ${redactSecrets(message)}');
    final hs = _handshake;
    if (hs != null && !hs.isCompleted) {
      hs.completeError(RealtimeException(redactSecrets(message), code: code));
      return;
    }
    if (code == 'item_delete_invalid_item_id') {
      // Already gone: as good as deleted (message names the id).
      final id = RegExp(r"id '([^']+)'").firstMatch(message)?.group(1);
      if (id != null) {
        _items.removeWhere((i) => i.id == id);
        _onMessageWaiters({'type': 'conversation.item.deleted', 'item_id': id});
      }
      return;
    }
    if (_applyingSummary && code != null && !_benignErrors.contains(code)) {
      _applyErrors.add('$code: $message');
      // Fail the pending confirmations now instead of waiting for timeouts.
      for (final w in List.of(_waiters)) {
        if (!w.$2.isCompleted) w.$2.completeError(RealtimeException('$code: $message', code: code));
      }
      _waiters.clear();
      return;
    }
    switch (code) {
      case final c? when _benignErrors.contains(c):
        _log('ignored $c');
        _cancelSent = false;
        return;
      case 'conversation_already_has_active_response':
        _responseRequested = false;
        _wantResponse = true;
        return;
      case 'invalid_tool_call_id':
        _log('server rejected a tool call id: $message');
        return;
    }
    // An expired session (the 60-minute cap) is not fatal: this backend
    // reconnects on its own with the summary and recent turns.
    final fatal = code == 'invalid_api_key';
    _emit(BackendError(redactSecrets(message), code: code, fatal: fatal));
    if (code == 'session_expired' && !_closed) {
      _generation++;
      unawaited(_ws?.close());
      unawaited(_reconnect('session expired'));
    }
  }

  // ----------------------------------------------------- conversation mirror

  _Item? _itemById(String? id) {
    if (id == null) return null;
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  void _onItemAdded(Map<String, Object?> ev) {
    final item = (ev['item'] as Map?)?.cast<String, Object?>();
    final id = item?['id'] as String?;
    if (item == null || id == null || _itemById(id) != null) return;
    final it = _Item(id)..update(item);
    // Verified: the server reports the preceding item, and null only for an
    // item at the very beginning (first item or previous_item_id "root").
    final prev = ev['previous_item_id'] as String?;
    final idx = prev == null ? -1 : _items.indexWhere((i) => i.id == prev);
    if (prev == null) {
      _items.insert(0, it);
    } else if (idx >= 0) {
      _items.insert(idx + 1, it);
    } else {
      _items.add(it);
    }
  }

  /// Text rendering of the current server conversation, used to restore
  /// context after a reconnect.
  String? _restoreContext({int fromIndex = 0, int maxChars = 8000}) {
    final lines = <String>[];
    for (var i = fromIndex; i < _items.length; i++) {
      final it = _items[i];
      if (it.id == _summaryItemId) continue;
      final l = it.render();
      if (l != null) lines.add(l);
    }
    var recent = lines.join('\n');
    if (recent.length > maxChars) recent = '…${recent.substring(recent.length - maxChars)}';
    final parts = [
      if (_summary != null) _summaryText(_summary!),
      if (recent.isNotEmpty)
        'Most recent turns (the voice connection was re-established; continue naturally):\n$recent',
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  static String _summaryText(String s) => 'Summary of the earlier conversation (older turns were compacted):\n$s';

  // ------------------------------------------------------------ compaction

  bool get _idle =>
      _ready &&
      !_closed &&
      !_reconnecting &&
      _activeResponseId == null &&
      !_responseRequested &&
      _pendingCalls.isEmpty &&
      !_userSpeaking &&
      !_applyingSummary;

  @override
  Future<ContextApplyResult> applySummary(String summary, {String? recentTurns}) {
    if (_closed) return Future.value(const ContextApplyResult(ContextApplyMethod.skipped, detail: 'closed'));
    _pendingSummary = summary;
    final c = _pendingSummaryDone ??= Completer<ContextApplyResult>();
    // Defer to the next idle moment (between responses).
    scheduleMicrotask(_maybeApplySummary);
    return c.future;
  }

  void _maybeApplySummary() {
    if (!_idle) return;
    if (_pendingSummary == null) {
      if (_imageOps.isNotEmpty) unawaited(_applyImageOpsNow());
      return;
    }
    final summary = _pendingSummary!;
    final done = _pendingSummaryDone!;
    _pendingSummary = null;
    _pendingSummaryDone = null;
    _applySummaryNow(summary).then(
      done.complete,
      onError: (Object e) {
        done.complete(ContextApplyResult(ContextApplyMethod.skipped, detail: '$e'));
      },
    );
  }

  /// Index of the first item kept verbatim: the start of the
  /// [keepRecentTurns]-th last user turn, never splitting a function call
  /// from its output and keeping a turn's screenshot with it.
  int _cutIndex() {
    // Same rule as rawTurnsStart (local compaction): an assist activation
    // screenshot (possibly without speech) starts a turn,
    // unless the next turn boundary is a user turn it belongs to.
    final turnStarts = <int>[];
    var absorb = false;
    for (var i = _items.length - 1; i >= 0; i--) {
      final it = _items[i];
      if (it.id == _summaryItemId) continue;
      if (it.isUserTurn) {
        turnStarts.add(i);
        absorb = true;
      } else if (it.isImageOnly && it.text.contains(kAssistNotePrefix)) {
        if (absorb) {
          turnStarts[turnStarts.length - 1] = i;
          absorb = false;
        } else {
          turnStarts.add(i);
        }
      }
    }
    if (turnStarts.length <= keepRecentTurns) return 0;
    var cut = turnStarts[keepRecentTurns - 1];
    var moved = true;
    while (moved) {
      moved = false;
      final keptOutputs = {
        for (final it in _items.skip(cut))
          if (it.type == 'function_call_output') it.callId,
      };
      for (var i = 0; i < cut; i++) {
        if (_items[i].type == 'function_call' && keptOutputs.contains(_items[i].callId)) {
          cut = i;
          moved = true;
          break;
        }
      }
    }
    return cut;
  }

  Future<Map<String, Object?>> _waitFor(bool Function(Map<String, Object?>) pred, Duration timeout) {
    final c = Completer<Map<String, Object?>>();
    _waiters.add((pred, c));
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.removeWhere((w) => identical(w.$2, c));
        throw TimeoutException('no server confirmation');
      },
    );
  }

  Future<ContextApplyResult> _applySummaryNow(String summary) async {
    _applyingSummary = true;
    _applyErrors.clear();
    try {
      final cut = _cutIndex();
      final toDelete = [
        for (var i = 0; i < cut; i++) _items[i].id,
        if (_summaryItemId != null && _items.indexWhere((x) => x.id == _summaryItemId) >= cut) _summaryItemId!,
      ];
      final newId = _newItemId('ctx');
      final added = _waitFor(
        (e) =>
            (e['type'] == 'conversation.item.added' || e['type'] == 'conversation.item.created') &&
            (e['item'] as Map?)?['id'] == newId,
        applyConfirmTimeout,
      );
      // Insert the summary right before the first kept item.
      final prevId = cut > 0 ? _items[cut - 1].id : 'root';
      _send({
        'type': 'conversation.item.create',
        'previous_item_id': prevId,
        'item': _systemItem(newId, _summaryText(summary)),
      });
      try {
        await added;
      } on TimeoutException {
        throw RealtimeException('summary item not confirmed (${_applyErrors.join('; ')})');
      }
      if (_applyErrors.isNotEmpty) throw RealtimeException(_applyErrors.join('; '));
      // The summary is in: a retry after a failed deletion replaces it
      // instead of adding a second one.
      final oldSummaryId = _summaryItemId;
      _summary = summary;
      _summaryItemId = newId;
      if (oldSummaryId != null && !toDelete.contains(oldSummaryId) && _itemById(oldSummaryId) != null) {
        toDelete.add(oldSummaryId);
      }
      final deletions = <Future<Map<String, Object?>>>[];
      for (final id in toDelete) {
        deletions.add(
          _waitFor((e) => e['type'] == 'conversation.item.deleted' && e['item_id'] == id, applyConfirmTimeout),
        );
        _send({'type': 'conversation.item.delete', 'item_id': id});
      }
      try {
        await Future.wait(deletions);
      } on TimeoutException {
        throw RealtimeException('item deletion not confirmed (${_applyErrors.join('; ')})');
      }
      if (_applyErrors.isNotEmpty) throw RealtimeException(_applyErrors.join('; '));
      _deferredSummary = null;
      _applyRetries = 0;
      _log('compaction applied: summary item added, ${toDelete.length} items deleted');
      return ContextApplyResult(ContextApplyMethod.deletedItems, removedItems: toDelete.length);
    } catch (e) {
      if (_closed) return const ContextApplyResult(ContextApplyMethod.skipped, detail: 'closed');
      // Never cut the conversation for this: the session goes on as it is,
      // the apply is retried in the background, and any reconnect (network,
      // idle standby) starts from the summary anyway.
      _deferredSummary = summary;
      if (_applyRetries < maxApplyRetries) {
        _applyRetries++;
        _log('in-place compaction failed ($e); retry $_applyRetries in ${applyRetryDelay.inSeconds} s');
        _applyRetryTimer?.cancel();
        _applyRetryTimer = Timer(applyRetryDelay, () {
          _applyRetryTimer = null;
          if (_closed || _deferredSummary != summary || _pendingSummary != null) return;
          _pendingSummary = summary;
          _pendingSummaryDone ??= Completer<ContextApplyResult>();
          _maybeApplySummary();
        });
      } else {
        _log('in-place compaction failed ($e); applied at the next reconnect');
      }
      return ContextApplyResult(ContextApplyMethod.skipped, detail: 'deferred: $e');
    } finally {
      _applyingSummary = false;
      _applyErrors.clear();
      _maybeCreateResponse();
    }
  }
}

/// Mirror of one server-side conversation item.
class _Item {
  _Item(this.id);
  final String id;
  String type = 'message';
  String? role;
  String? callId;
  String? name;
  String text = '';
  bool hasAudio = false;
  bool hasImage = false;
  bool hasText = false;
  int? truncatedAtMs;

  void update(Map<String, Object?> item) {
    type = item['type'] as String? ?? type;
    role = item['role'] as String? ?? role;
    callId = item['call_id'] as String? ?? callId;
    name = item['name'] as String? ?? name;
    if (type == 'function_call') {
      final a = item['arguments'] as String?;
      if (a != null && a.isNotEmpty) text = a;
    } else if (type == 'function_call_output') {
      final o = item['output'] as String?;
      if (o != null) text = o;
    }
    final content = item['content'];
    if (content is List) {
      final parts = <String>[];
      for (final c in content) {
        if (c is! Map) continue;
        switch (c['type']) {
          case 'input_audio' || 'output_audio' || 'audio':
            hasAudio = true;
            final t = c['transcript'] as String?;
            if (t != null && t.isNotEmpty) parts.add(t);
          case 'input_image':
            hasImage = true;
          case 'input_text' || 'output_text' || 'text':
            hasText = true;
            final t = c['text'] as String?;
            if (t != null && t.isNotEmpty) parts.add(t);
        }
      }
      if (parts.isNotEmpty) text = parts.join(' ');
    }
  }

  bool get isUserTurn => type == 'message' && role == 'user' && (hasAudio || (hasText && !hasImage));
  bool get isImageOnly => type == 'message' && role == 'user' && hasImage && !hasAudio;

  String? render() {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
    switch (type) {
      case 'function_call':
        return 'Tool call: $name(${clip(text, 300)})';
      case 'function_call_output':
        return 'Tool result: ${clip(text, 400)}';
      case 'message':
        if (role == 'user' && isImageOnly) return 'User: [screenshot] ${clip(text, 200)}'.trimRight();
        if (text.isEmpty) return null;
        final who = switch (role) {
          'user' => 'User',
          'assistant' => 'Assistant',
          _ => 'Note',
        };
        return '$who: ${clip(text, 600)}';
    }
    return null;
  }
}

/// The last [capBytes] of a session's input audio, addressed by byte offset
/// from the session's first byte.
class _InputTape {
  _InputTape(this.capBytes);

  final int capBytes;
  final List<Uint8List> _chunks = [];
  int _start = 0; // offset of _chunks.first
  int _end = 0;

  int get endMs => _end * 1000 ~/ kVoiceBytesPerSecond;

  void add(Uint8List pcm) {
    _chunks.add(pcm);
    _end += pcm.length;
    while (_end - _start - _chunks.first.length >= capBytes) {
      _start += _chunks.removeAt(0).length;
    }
  }

  void clear() {
    _chunks.clear();
    _start = 0;
    _end = 0;
  }

  /// Bytes [from, to) (clamped to what was sent), or null when the start is
  /// no longer (or not yet) on the tape.
  Uint8List? slice(int from, int to) {
    from &= ~1;
    to = min(to, _end) & ~1;
    if (from < _start || from >= to) return null;
    final out = BytesBuilder(copy: false);
    var off = _start;
    for (final c in _chunks) {
      final cEnd = off + c.length;
      if (cEnd > from && off < to) {
        out.add(Uint8List.sublistView(c, max(0, from - off), min(c.length, to - off)));
      }
      if (cEnd >= to) break;
      off = cEnd;
    }
    return out.takeBytes();
  }
}
