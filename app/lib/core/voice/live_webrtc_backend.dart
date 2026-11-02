import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';
import '../audio/playback_clock.dart';
import '../audio/wav.dart';
import '../auth/auth.dart';
import '../net/realtime_socket.dart';
import '../pipeline/vad.dart';
import 'delegation_executor.dart';
import 'live_rtc_transport.dart';
import 'voice_backend.dart';

const kLiveModels = ['gpt-live-1.1', 'gpt-live-1', 'gpt-live-1-codex'];

/// v3 voices accepted by gpt-live (§3.1). Realtime voices (marin, alloy...)
/// make the call die silently, so anything else maps to [kLiveDefaultVoice].
const kLiveVoices = [
  'cove', 'juniper', 'maple', 'spruce', 'ember', 'vale', 'breeze', 'arbor', 'sol', 'aube', 'bubbie', 'haetsal', //
  'hanul', 'himari', 'leher', 'miko', 'neer', 'porto', 'rindo', 'rio', 'rivage', 'selva', 'sonna', 'tinta', 'viola',
];
const kLiveDefaultVoice = 'cove';

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
class LiveWebRtcBackend implements VoiceBackend, ManagedAudioBackend {
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
    this.vadStopMs = 550,
  }) : _connectSideband = sideband ?? IoRealtimeSocket.connect,
       _createCall = createCall ?? createLiveCallHttp;

  final LiveRtcTransportFactory transportFactory;
  final RealtimeConnector _connectSideband;
  final LiveCallCreator _createCall;

  /// Builds the Responses client for delegations (default: [CodexResponsesModel]).
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
  final int vadStopMs;

  final _events = StreamController<BackendEvent>.broadcast();
  final _delegations = StreamController<DelegationReport>.broadcast();
  LiveRtcTransport? _rtc;
  RealtimeSocket? _ws;
  StreamSubscription<String>? _wsSub;
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

  // ---- user speech state
  late final EnergyVad _vad = EnergyVad(stopMs: vadStopMs);
  bool _userSpeaking = false;
  final Set<_ManagedMic> _mics = {};
  bool _inputEnabled = true;

  // ---- images (for delegation) and pending tool calls
  DelegationImage? _latestImage;
  final Map<String, Completer<String>> _pendingTools = {};
  int _toolSeq = 0;

  // ---- delegation tracking (for spoken-latency metrics)
  final Map<String, (DelegationReport, Stopwatch)> _awaitingSpeech = {};

  late final _ManagedPlayer _player = _ManagedPlayer(this);

  @override
  Stream<BackendEvent> get events => _events.stream;

  /// Completed delegations with timings (`spoken` filled when the assistant
  /// starts talking after the result was appended).
  Stream<DelegationReport> get delegations => _delegations.stream;

  @override
  bool get hasServerVad => true;

  String get transportDescription => _rtc?.description ?? '-';

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
    final model = kLiveModels.contains(config.model) ? config.model : kLiveModels.first;
    final voice = kLiveVoices.contains(config.voice) ? config.voice : kLiveDefaultVoice;
    final headers = creds.headers(live: true);
    final total = Stopwatch()..start();

    final rtc = transportFactory();
    _rtc = rtc;
    var sw = Stopwatch()..start();
    final offer = await rtc.createOffer();
    timings.offer = sw.elapsed;

    var instructions = config.instructions;
    final prior = config.priorContext;
    if (prior != null && prior.trim().isNotEmpty) {
      instructions = '$instructions\n\nEarlier in this conversation (summary):\n${prior.trim()}';
    }
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
    timings.callCreate = sw.elapsed;
    callId = call.callId;
    await rtc.setAnswer(call.answerSdp);

    sw = Stopwatch()..start();
    final RealtimeSocket ws;
    try {
      ws = await _connectSideband(Uri.parse('$sidebandBase/${call.callId}'), headers);
    } catch (e) {
      throw LiveCallException(
        'sideband rejected: ${redactSecrets('$e')} (an invalid session config kills the call silently)',
      );
    }
    timings.sideband = sw.elapsed;
    _ws = ws;
    final started = Completer<void>();
    _wsSub = ws.messages.listen(
      (raw) {
        Map<String, Object?> ev;
        try {
          ev = (jsonDecode(raw) as Map).cast<String, Object?>();
        } catch (_) {
          return;
        }
        if (ev['type'] == 'session.started' && !started.isCompleted) started.complete();
        try {
          _onSideband(ev);
        } catch (e, st) {
          debugPrint('live sideband handler: $e\n$st');
        }
      },
      onDone: () {
        if (!started.isCompleted) {
          started.completeError(LiveCallException('sideband closed before session.started (${ws.closeCode})'));
        }
        if (!_closed) {
          _emit(BackendError('gpt-live session ended (${ws.closeCode ?? '-'} ${ws.closeReason ?? ''})', fatal: true));
        }
      },
      onError: (Object e) {
        if (!started.isCompleted) started.completeError(e);
      },
    );
    await started.future.timeout(
      sessionStartTimeout,
      onTimeout: () => throw LiveCallException('no session.started within ${sessionStartTimeout.inSeconds}s'),
    );
    timings.sessionStarted = total.elapsed;
    rtc.setMicEnabled(_inputEnabled);

    final dm = delegationModelFactory?.call(creds) ?? ResponsesDelegationModel(credentialsProvider ?? () async => creds);
    _delegationModel = dm;
    if (dm is ResponsesDelegationModel) unawaited(dm.warmUp());
    _executor = DelegationExecutor(
      model: dm,
      tools: config.tools,
      runTool: toolRunner ?? _runToolViaPipeline,
      latestScreenshot: () => _latestImage,
      fastModel: delegationFastModel,
    );
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
        _userStarted();
        final t = _itemText(ev);
        if (t.isNotEmpty) _emit(UserTranscriptDelta(t));
      case 'output_transcript.added':
        _openAssistant(_int(ev['start_ms']));
        final t = _itemText(ev);
        if (t.isNotEmpty) _emit(AssistantTranscriptDelta(t));
        _markSpoken();
      case 'turn.created':
        final turn = _map(ev['turn']);
        if (turn['role'] == 'user') {
          _userStarted();
        } else if (turn['role'] == 'assistant') {
          _openAssistant(_int(turn['start_ms']));
        }
      case 'turn.done':
        final turn = _map(ev['turn']);
        final text = '${turn['transcript'] ?? ''}'.trim();
        if (turn['role'] == 'user') {
          if (_userSpeaking) _userStopped();
          _emit(UserTranscriptDone(text));
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
    _assistantOpen = true;
    _assistantCloseAtMs = null;
    _assistantStartMs = startMs;
    _emittedUntilMs = startMs;
    _interrupted = false;
    if (_speakerMuted) {
      _speakerMuted = false;
      _rtc?.setSpeakerEnabled(true);
    }
    // Full duplex: once the assistant takes the floor the user turn is over.
    if (_userSpeaking) _userStopped();
    _flushAssistantAudio();
  }

  void _flushAssistantAudio() {
    final until = _assistantCloseAtMs ?? _outEndMs;
    if (until > _emittedUntilMs) {
      final pcm = _out.slice(_emittedUntilMs, until);
      _emittedUntilMs = until;
      if (pcm.isNotEmpty && !_speakerMuted) _emit(AssistantAudioDelta(pcm));
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
    _closeTimer?.cancel();
    _assistantOpen = false;
    _assistantCloseAtMs = null;
    _emit(AssistantTranscriptDone(_assistantClosingText));
    _emit(ResponseDone(cancelled: _interrupted));
    _interrupted = false;
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

  void _userStarted() {
    if (_userSpeaking) return;
    _userSpeaking = true;
    _emit(const SpeechStarted());
  }

  void _userStopped() {
    _userSpeaking = false;
    _emit(const SpeechStopped());
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
    final sw = Stopwatch()..start();
    unawaited(() async {
      final report = await ex.execute(text, id: id);
      if (_closed) return;
      _send({
        'type': 'delegation.context.append',
        'delegation_item_id': id,
        'content': [
          {'type': 'input_text', 'text': report.resultText},
        ],
      });
      debugPrint('live delegation "$text": ${report.timingSummary()}');
      _awaitingSpeech[id] = (report, sw);
      // Report even if the model never speaks.
      Timer(const Duration(seconds: 12), () => _reportDelegation(id));
    }());
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
    if (w != null && !_delegations.isClosed) _delegations.add(w.$1);
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
    // No user-text item on this transport: inject it as context the model
    // reacts to (§3.2 session.context.append).
    _send({
      'type': 'session.context.append',
      'channel': 'developer',
      'content': [
        {'type': 'input_text', 'text': 'The user typed: $text'},
      ],
    });
  }

  @override
  void sendImage(Uint8List png, {String? note}) {
    // gpt-live context is text only; images are kept for delegations.
    _latestImage = DelegationImage(png: png, capturedAt: DateTime.now(), note: note);
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
    if (!_assistantOpen && !_player.isPlaying) return;
    _interrupted = true;
    _speakerMuted = true;
    _rtc?.setSpeakerEnabled(false);
    _player.clock.reset();
  }

  // ------------------------------------------------------- managed audio

  @override
  Future<MicStream> openManagedMic() async {
    final m = _ManagedMic(this);
    _mics.add(m);
    setInputEnabled(true);
    return m;
  }

  @override
  PcmPlayer get managedPlayer => _player;

  @override
  void setInputEnabled(bool enabled) {
    _inputEnabled = enabled;
    _rtc?.setMicEnabled(enabled);
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
    try {
      _send({'type': 'session.close'});
    } catch (_) {}
    for (final c in _pendingTools.values) {
      if (!c.isCompleted) c.complete('{"ok":false,"error":"session closed"}');
    }
    _pendingTools.clear();
    await _wsSub?.cancel();
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      await _rtc?.close();
    } catch (_) {}
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

/// Sparse PCM store keyed by session milliseconds (200 ms frames).
class _PcmTimeline {
  _PcmTimeline({required this.maxMs});
  final int maxMs;
  final SplayTreeMap<int, Uint8List> _frames = SplayTreeMap();

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
