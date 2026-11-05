import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileMode, IOSink, Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';
import '../../platform/screen_capture.dart';
import '../../tools/tool_registry.dart';
import '../audio/earcon.dart';
import '../audio/stop_word_spotter.dart';
import '../audio/wav.dart';
import '../context/context_manager.dart';
import '../context/image_tiers.dart';
import '../media/media_context.dart';
import '../models/message.dart';
import '../util/usage_limit.dart';
import '../settings/settings.dart';
import '../storage/history_store.dart';
import '../voice/context_images.dart';
import '../voice/context_sync.dart';
import '../voice/delegation_executor.dart';
import '../voice/voice_backend.dart';
import 'barge_in.dart';
import 'echo_guard.dart';
import 'echo_transcript.dart';
import 'pre_connect_buffer.dart';
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
    this.localBargeIn = true,
    this.cameraReplacesScreenshot = false,
    this.onsetMicWithManagedAudio = true,
    this.bargeInFloor = 0.02,
    this.halfDuplexWhileSpeaking = false,
    this.stopWordDetection = false,
    this.stopWords = const ['stop'],
  });

  /// Offline stop-word spotting while Woi speaks or is paused: a hit on the
  /// mic (not in Woi's own audio) pauses and cuts locally (`kws`).
  final bool stopWordDetection;

  /// Keywords for [stopWordDetection] (mapped to model tokens).
  final List<String> stopWords;

  /// Android media route: while Woi's audio plays (and briefly after), send
  /// silence to the server instead of the mic, so residual echo of Woi's
  /// own voice can neither trigger server VAD (auto-interrupt) nor become a
  /// user turn. The local onset detector still sees the real mic; when it
  /// fires, playback stops and the real audio (with ~160 ms of lead-in)
  /// flows again.
  final bool halfDuplexWhileSpeaking;

  /// Minimum mic RMS for a local barge-in onset while Woi speaks. Android's
  /// platform echo canceller removes the echo almost completely but leaves
  /// 30-70 ms residual bursts up to ~0.05 (measured on a Xiaomi MI 8), above
  /// the desktop floor; a voice near the phone is 0.06-0.3.
  final double bargeInFloor;

  /// With a backend that captures the mic itself (WebRTC), also open the
  /// platform mic for the local barge-in detector. Off on phones: a second
  /// concurrent AudioRecord costs ~10% CPU while listening, and the WebRTC
  /// echo canceller plus server VAD already handle interruptions there.
  final bool onsetMicWithManagedAudio;

  /// While the camera is on, its frame replaces the turn's screenshot
  /// instead of being attached next to it.
  final bool cameraReplacesScreenshot;
  final bool autoScreenshot;
  final Duration screenshotDelay;
  final int maxScreenshotWidth;
  final MicMode micMode;

  /// Play [thinkingEarconPcm] when the user stops speaking and the reply
  /// has not started yet.
  final bool thinkingEarcon;

  /// Cut playback on a local mic onset (echo-robust energy detector) instead
  /// of waiting for the server to notice the interruption.
  final bool localBargeIn;
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
    this.imageCompactor,
    this.onTurnStart,
    this.localCommand,
    this.onSelfTalk,
    this.stopWordSpotter,
    @visibleForTesting EchoGuard? echoGuard,
  }) : _conv = conversation,
       _guard = echoGuard ?? EchoGuard() {
    context.attach(conversation);
    _compactionSub = context.compactions.listen(_onCompacted);
  }

  final VoiceBackend Function() backendFactory;

  /// Creates the offline stop-word spotter (null: none). Started lazily the
  /// first time Woi is audible with [PipelineOptions.stopWordDetection] on.
  final StopWordSpotter Function()? stopWordSpotter;
  StopWordSpotter? _kws;
  StreamSubscription<KwsHit>? _kwsSub;
  String? _kwsWords;
  int kwsCuts = 0;
  int kwsIgnored = 0;
  final AudioIO audio;
  final ScreenCapture screen;
  final ToolRegistry tools;
  final ContextManager context;
  final HistoryStore store;
  final SessionConfigBuilder sessionConfig;
  PipelineOptions Function() options;
  void Function(Screenshot shot)? onScreenshotCaptured;

  /// A user turn starts (speech or typed text), e.g. to remember the app
  /// the user was in as the default `send_keys` target.
  void Function()? onTurnStart;

  /// User text handled locally without the model ("apply" / "reject" while
  /// an edit preview is pending, typed "undo that"). Returns true when
  /// handled; a spoken one then also drops the model's reply to it.
  bool Function(String text, {required bool typed})? localCommand;

  /// Woi kept hearing itself ([selfTalkLimit] echo turns in a row): pause
  /// hands-free listening (the app switches the mic setting; without a
  /// callback the pipeline mutes itself). A notice is added either way.
  void Function()? onSelfTalk;

  /// Screenshot tiers (newest full, then ⅕ size, then described).
  final ImageCompactor? imageCompactor;

  /// The camera frame to attach to a user turn; null while the camera is off.
  ContextImage? Function()? cameraImage;

  /// Runs before a typed turn is sent (media context for "what's in this
  /// image"). Returns null synchronously when there is nothing to do;
  /// otherwise the future's text (if any) is what the model receives.
  Future<String?>? Function(String text)? beforeTypedTurn;

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

  // ---- pre-connect capture: the platform mic opens together with connect
  // (launch, assistant activation, auto-reconnect); its chunks wait here and
  // go out in order once the session is ready.
  final PreConnectBuffer _pending = PreConnectBuffer();
  static const bool _kDumpPreConnect = bool.fromEnvironment('WOI_DUMP_PRECONNECT');
  // Screen grabbed when the buffered audio first turned voiced; attached to
  // the turn the server opens for it after the flush.
  Future<Screenshot?>? _preShot;
  // The flushed audio, for the turn's clip.
  Uint8List? _flushedClip;
  DateTime? _flushedAt;

  /// Bytes of pre-connect audio flushed to the backend (tests/diagnostics).
  int preConnectFlushedBytes = 0;

  /// Pre-connect audio dropped by the ~15 s cap (tests/diagnostics).
  int get preConnectDropped => _pending.dropped;

  /// The mic records while the session is (re)connecting: what the user says
  /// now is sent once it is ready ("Listening… connecting").
  bool get capturingWhileConnecting =>
      _mic != null && !_micManaged && _status != SessionStatus.connected && _forwarding && !_suspended;
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

  // Local barge-in, self-echo gate and "stop" handling.
  final EchoGuard _guard;
  // Mic audio held back while the gate is closed: sent as the onset's
  // pre-roll when the user turns out to be talking over Woi.
  /// Send silence instead of the mic while Woi's echo may be in it (until a
  /// local onset). Off: it cost real barge-ins.
  bool echoGate = false;

  /// How long a deferred server turn ([SpeechStarted.deferred]) waits for
  /// its transcript before it interrupts Woi anyway.
  Duration deferWindow = const Duration(milliseconds: 600);
  bool _deferPending = false;
  DateTime? _deferredAt;
  Message? _deferMsg;
  Timer? _deferTimer;

  /// Deferred turns: interrupted Woi (local detector, timeout, transcript)
  /// / dropped as echo without cutting Woi.
  int deferredInterrupts = 0;
  int deferredEchoDrops = 0;
  final List<int> deferredDecisionMs = [];

  /// The deferred turn is the user: the usual cut + hold, then the backend
  /// answers it.
  void _confirmDeferred(String why) {
    _deferTimer?.cancel();
    _deferTimer = null;
    final m = _deferMsg;
    if (!_deferPending || m == null) return;
    _deferPending = false;
    _deferMsg = null;
    deferredInterrupts++;
    final at = _deferredAt;
    if (at != null) deferredDecisionMs.add(DateTime.now().difference(at).inMilliseconds);
    debugPrint('deferred turn: interrupting ($why)');
    _turnDecision[m.id] = 'kept (deferred: $why)';
    final interrupted = _bargeIn();
    _backend?.acceptTurn();
    if (interrupted || _echoSuspects.containsKey(m.id) || (_holding && _holdMsg == null)) _beginHold(m);
    _changed();
  }

  /// No transcript within [deferWindow] and no local onset: no evidence it
  /// is the user (an echo burst the server VAD took for speech often has an
  /// empty transcript), so Woi plays on. The turn stays undecided: a later
  /// local onset or a non-echo transcript interrupts then; an empty or
  /// echo-like one drops it unanswered ([_checkDeferred]).
  void _deferTimeout() {
    _deferTimer = null;
    if (!_deferPending) return;
    debugPrint('deferred turn: no transcript yet and no local onset: Woi plays on');
  }

  /// Transcript of a deferred turn: echo → drop it (Woi was never cut);
  /// clearly not echo (or "stop") → interrupt now.
  void _checkDeferred(Message m, {required bool done}) {
    if (!_deferPending || !identical(m, _deferMsg)) return;
    final text = m.text.trim();
    // The reply Woi is still speaking is not in [_spoken] yet: its words
    // heard so far are the likeliest echo.
    final a = _assistantMsg;
    final cur = a == null || a.text.trim().isEmpty
        ? null
        : (_Spoken(a, DateTime.now(), _stretchBytes <= 0 ? 1.0 : (1 - _unheard().length / _stretchBytes).clamp(0.0, 1.0)))
              .window();
    final prior = _echoSuspects[m.id];
    final said = cur == null ? prior : [...?prior, cur];
    if (text.isEmpty) {
      if (done) _dropDeferred(m);
      return;
    }
    if (isStopPhrase(text) || couldBecomeStopPhrase(text) && done) return _confirmDeferred('stop');
    if (done && _shortEcho(m, text, said ?? const [])) return _dropDeferred(m);
    if (said == null) return _confirmDeferred('no reference');
    if (done) {
      if (isEchoOf(text, said)) {
        _turnDecision[m.id] = 'dropped (deferred echo match)';
        return _dropDeferred(m);
      }
      return _confirmDeferred('transcript');
    }
    final words = RegExp(r'\S+').allMatches(text).length;
    if (words >= 4 && echoScore(text, said) < echoThreshold - 0.3) _confirmDeferred('transcript');
  }

  void _dropDeferred(Message m) {
    _deferTimer?.cancel();
    _deferTimer = null;
    _deferPending = false;
    _deferMsg = null;
    deferredEchoDrops++;
    final at = _deferredAt;
    if (at != null) deferredDecisionMs.add(DateTime.now().difference(at).inMilliseconds);
    _cutTail = null;
    _onEchoTurn(m);
    // Woi's reply was never cut: it plays on.
    _dropUntil = null;
  }
  final PcmRing _gatedPcm = PcmRing(kVoiceBytesPerSecond * 4 ~/ 10); // 400 ms
  bool _gating = false;
  // Soft barge-in: a local onset pauses Woi (keeping what was not heard yet
  // and what keeps arriving); the server's speech start confirms the
  // interruption, otherwise playback resumes ([_onsetConfirmWindow]). A
  // residual-echo burst then costs a short pause instead of the reply.
  final List<Uint8List> _stretch = []; // audio written since playback started
  int _stretchBytes = 0;
  BytesBuilder? _paused;
  Timer? _pauseTimer;
  static const _onsetConfirmWindow = Duration(milliseconds: 900);

  /// Local hold: a strong, voice-like onset (peak excess RMS over the echo
  /// at least [onsetHoldMinRms]) is not resumed after [_onsetConfirmWindow];
  /// it stays paused up to [onsetHoldExtra] more for the server's speech
  /// start (the server VAD can lag ~2.5 s or miss a short "stop" over the
  /// echo). An echo / empty transcript then resumes from where it paused.
  double onsetHoldMinRms = 0.012;
  Duration onsetHoldExtra = const Duration(milliseconds: 1500);
  int onsetsHeld = 0;

  /// Local stop cut: an unconfirmed onset whose peak excess RMS is at least
  /// this marks the user (used to keep a cut reply stopped after a filler /
  /// echo transcript). Measured on the PipeWire E2E (echo27/28): real speech
  /// (stop / question / barge fixtures) peaked at 0.067-0.141, echo false
  /// onsets at 0.018 and 0.062. Peak alone never cuts (see [_pauseDecide]).
  static const onsetCutMinRms = 0.04;
  double onsetCutRms = onsetCutMinRms;

  /// Voice in the pause: while Woi is paused nothing plays, so once the echo
  /// tail has passed any mic energy above the noise floor is the user. The
  /// E2E echo path is 150 ms delay + a 300 ms room tail (60 ms decay, -8 dB),
  /// plus ~60 ms output latency; on laptops the platform AEC tail is shorter.
  static const pauseEchoTail = Duration(milliseconds: 450);

  /// Window after [pauseEchoTail] in which the raw mic level is measured.
  static const pauseVoiceWindow = Duration(milliseconds: 250);

  /// Voiced mic time in that window that means "the user keeps talking"
  /// (~1/3 of it: syllable gaps are allowed).
  static const pauseVoiceMinMs = 80;

  /// A mic chunk is voiced at >= floor + 10 dB (x3.16 RMS) and at least
  /// this absolute RMS (-50 dBFS; fixture speech reaches the virtual mic at
  /// -15..-25 dBFS, digital silence in between). Broadband only: the
  /// guard's per-band noise floor adapts to the user once the pause has no
  /// reference left, so its bands are no help here.
  static const pauseVoiceMinRms = 0.003;

  /// Short word ("stop" is ~0.4 s, mostly over before the onset is even
  /// detected ~0.3-0.4 s in, so the pause is quiet after the tail): cut
  /// without voice in the pause only when the onset peak is high AND the
  /// near-end excess was still there at the firing frame. E2E data
  /// (excess at firing / peak): echo false onsets 0.000 / 0.062 (e28b) and
  /// 0.013 / 0.018 (e27a); real speech 0.018-0.129 / 0.067-0.141 (stop: 0.024
  /// / 0.083, 0.029 / 0.067, 0.051 / 0.089). Otherwise the server's speech
  /// start / transcript decides.
  static const onsetShortCutRms = 0.06;
  static const onsetShortCutFireRms = 0.015;
  double onsetShortCutRmsValue = onsetShortCutRms;
  double onsetShortCutFireRmsValue = onsetShortCutFireRms;
  double _onsetFireRms = 0;
  DateTime? _pausedAt;
  int _pauseVoicedMs = 0;
  double _pauseMicPeak = 0;
  /// QA only (`WOI_QA_IGNORE_SERVER_SPEECH=1`, read once at startup): a
  /// server speech start that arrives while Woi is speaking (playing or
  /// paused; a deferred turn) is held back together with that turn's
  /// stop / transcript events, so the pause is decided by the local rules
  /// alone ([_pauseDecide]). After a local cut the held events are replayed
  /// and the turn is processed normally; after a resume the turn is dropped
  /// ([VoiceBackend.dropEchoTurn]) and its later events ignored; if Woi just
  /// finishes without an onset they are replayed. Unset (the default) or
  /// any other value: no effect. Used by `qa/aec/e2e_echo.sh` to exercise
  /// the local cut paths, which the server's confirmation otherwise preempts.
  static final bool qaIgnoreServerSpeechEnv = Platform.environment['WOI_QA_IGNORE_SERVER_SPEECH'] == '1';
  bool qaIgnoreServerSpeech = qaIgnoreServerSpeechEnv;
  final List<BackendEvent> _qaHeld = [];
  final Set<String> _qaIgnoredItems = {};
  Timer? _qaHeldTimer;
  int qaServerStartsHeld = 0;

  // Raw mic RMS floor (tracked while nothing plays and the user is quiet).
  double _micFloorRms = 0;
  int localCuts = 0;
  int onsetsQuietResumed = 0;
  DateTime? _strongOnsetAt;
  // Raw platform mic used only for onset detection when the backend owns the
  // real mic (its stream is a delayed server echo, too late for barge-in).
  MicStream? _onsetMic;
  StreamSubscription<Uint8List>? _onsetSub;

  /// The mic before the AEC ([RawMicCapable]), feeding only the stop-word
  /// spotter; null: the spotter takes the normal mic.
  MicStream? _kwsRawMic;
  StreamSubscription<Uint8List>? _kwsRawSub;
  // After an interruption (or a short utterance) the next reply is held until
  // we know the user did not just say "stop".
  bool _holding = false;
  Message? _holdMsg;
  final List<BackendEvent> _held = [];
  Timer? _holdTimer;
  // The reply to a "stop" is dropped until then.
  DateTime? _dropUntil;
  final Set<String> _stopHandled = {};
  Timer? _phaseTicker;
  AssistantPhase _lastPhase = AssistantPhase.offline;
  // Last sign of life of the turn (backend event, typed text, end of speech,
  // tool result): "thinking" with nothing in flight settles after a while.
  DateTime _lastTurnActivity = DateTime.now();

  /// How long "Thinking…" may last with nothing in flight (no tool, no reply,
  /// backend not busy) before the phase settles back to listening/idle. A
  /// local fast-path turn whose outcome the model chose not to voice would
  /// otherwise keep it forever.
  Duration settleAfter = const Duration(seconds: 10);

  // ---- automatic reconnect (the live connection dropped, e.g. WS 1006)
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// Reconnect attempts after a dropped or failed connection, with
  /// exponential backoff from [reconnectBaseDelay] (capped at 30 s). Woi keeps
  /// trying by default (practically unlimited); context is restored by
  /// [connect] (summary + recent turns in the new session config).
  int maxAutoReconnects = 1 << 30;

  /// A usage limit (429) without a reset time is retried this often.
  Duration usageLimitRetry = const Duration(minutes: 30);
  Duration reconnectBaseDelay = const Duration(seconds: 1);

  /// Error codes of a [BackendError] that mean "the connection dropped" (as
  /// opposed to a configuration or auth problem), so a reconnect may help.
  static const reconnectableCodes = {'connection_lost', 'reconnect_failed'};

  /// Reconnecting on its own after a drop (the status line says so).
  bool get reconnecting => _reconnecting;

  /// Reconnecting and waiting out the backoff (no attempt in flight).
  bool get reconnectWaiting => _reconnecting && _reconnectTimer != null;

  /// Number of successful automatic reconnects (diagnostics/tests).
  int autoReconnects = 0;

  int onsetsResumed = 0;

  /// User turns dropped because the transcript was Woi's own reply heard back.
  int echoTurnsDropped = 0;

  /// Times hands-free listening was paused for self-talk.
  int selfTalkBreaks = 0;

  /// Echo turns in a row (within [_selfTalkSpan]) that pause hands-free.
  static const selfTalkLimit = 3;
  static const _selfTalkSpan = Duration(seconds: 90);
  int _echoStreak = 0;
  DateTime? _lastEchoTurn;

  // Transcript guard: a user turn that starts while Woi is audible (or up to
  // 2 s after) is held until its transcript shows it is not Woi's own
  // speech. Message id -> Woi's replies it may be an echo of.
  final Map<String, List<String>> _echoSuspects = {};
  final List<_Spoken> _spoken = [];
  DateTime _echoWindowUntil = DateTime.fromMillisecondsSinceEpoch(0);
  // What a barge-in cut off (unheard audio), replayed when it was echo.
  Uint8List? _cutTail;
  Message? _cutMsg;
  double _cutHeard = 1;
  DateTime? _lastOnsetAt;
  DateTime? _cutAt;
  int bargeIns = 0;
  int localOnsets = 0;
  int stopsHandled = 0;
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

  /// True while the backend captures the microphone itself (gpt-live's
  /// WebRTC): capture settings then need a new call, not [reopenMic].
  bool get backendManagesAudio => _managed != null;
  bool _micManaged = false;

  /// Bumps when the mic or player (and so the level listenables) change.
  ValueListenable<int> get levelSourcesChanged => _levelsChanged;

  /// Woi's audio is queued or playing (the player's clock: from the first
  /// write until everything written has been played; false once stopped).
  bool get _playing => _out?.isPlaying ?? false;

  /// Woi may be heard in the mic now: from the first chunk handed to the
  /// player until the queued audio has played, plus [_echoTail] (the room's
  /// tail after playback ends or is cut). Turn suspicion and the local VAD
  /// use this; the phase, barge-in, local onset (pause) and the half-duplex
  /// gate use [_playing] (nothing to cut in the tail; the gate has its own
  /// hangover).
  bool get _assistantAudible => _playing || DateTime.now().isBefore(_audibleUntil);
  DateTime _audibleUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const _echoTail = Duration(milliseconds: 300);

  /// For the per-turn log: playing (y), paused by a local onset (p), only the
  /// echo tail (t), or silent (n).
  String get _audibleTag => _playing
      ? 'y'
      : _paused != null
      ? 'p'
      : _assistantAudible
      ? 't'
      : 'n';

  AssistantPhase get phase {
    if (_status != SessionStatus.connected) return AssistantPhase.offline;
    if (_userSpeaking) return AssistantPhase.userSpeaking;
    if (_toolsRunning > 0) return AssistantPhase.toolRunning;
    if (_playing || (_assistantMsg?.streaming ?? false)) return AssistantPhase.speaking;
    if (_awaitingResponse) return AssistantPhase.thinking;
    return _micMode == MicMode.muted ? AssistantPhase.idle : AssistantPhase.listening;
  }

  bool _disposed = false;

  void _touchTurn() => _lastTurnActivity = DateTime.now();

  /// Ends a "Thinking…" that nothing will end: no tool running, no reply
  /// streaming or audible, the user not talking, no reply held back and the
  /// backend has nothing in flight, for [settleAfter].
  void _settleIfStale() {
    if (!_awaitingResponse || _status != SessionStatus.connected) return;
    if (_toolsRunning > 0 || _userSpeaking || _assistantMsg != null || _playing || _holding || _paused != null) {
      return;
    }
    if (_backend?.busy ?? false) {
      _touchTurn();
      return;
    }
    if (DateTime.now().difference(_lastTurnActivity) < settleAfter) return;
    debugPrint('phase: no reply after ${settleAfter.inSeconds}s with nothing in flight; settling');
    _awaitingResponse = false;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    _deltaNotify?.cancel();
    _deltaNotify = null;
    _lastPhase = phase;
    notifyListeners();
  }

  /// Transcript deltas arrive 20-60 times a second while a reply streams;
  /// each notification rebuilt the transcript and the input bar and drew a
  /// frame. For deltas the listeners hear at most every
  /// [transcriptNotifyInterval] (any other change, or a phase change, still
  /// notifies at once and takes the pending delta along).
  Duration transcriptNotifyInterval = const Duration(milliseconds: 66);
  Timer? _deltaNotify;

  void _changedSoon() {
    if (_disposed) return;
    if (phase != _lastPhase || transcriptNotifyInterval == Duration.zero) return _changed();
    _deltaNotify ??= Timer(transcriptNotifyInterval, _changed);
  }

  // ---------------------------------------------------------------- session

  Future<void> start() async {
    _player ??= await audio.openPlayer();
    _levelsChanged.value++;
    _micMode = options().micMode;
    await connect();
    _retryIfFailed();
  }

  /// After a failed connect (launch, resume, fatal error): try again on its
  /// own: with backoff, or once the usage limit resets.
  void _retryIfFailed() {
    if (_disposed || _suspended || _status != SessionStatus.error) return;
    if (usageLimit != null) {
      _scheduleLimitRetry();
    } else if (maxAutoReconnects > 0) {
      _reconnecting = true;
      _scheduleReconnect(statusDetail ?? 'connect failed', keepStatus: true);
    }
  }

  /// One retry when the ChatGPT usage limit resets (no storm meanwhile).
  void _scheduleLimitRetry() {
    final at = usageLimit?.resetsAt;
    var delay = at == null ? usageLimitRetry : at.difference(DateTime.now()) + const Duration(seconds: 5);
    if (delay < const Duration(minutes: 1)) delay = const Duration(minutes: 1);
    debugPrint('voice: usage limit; retrying in ${delay.inMinutes} min');
    _reconnectTimer?.cancel();
    _reconnecting = false;
    _reconnectAttempt = 0;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || _suspended || _status == SessionStatus.connected) return;
      _reconnecting = true;
      unawaited(_autoReconnect());
    });
  }

  /// The 120 ms phase poll (audible playback, stale "thinking") only runs
  /// while a session is connected: an offline or suspended Woi has no timers.
  void _syncPhaseTicker() {
    final want = _status == SessionStatus.connected && !_disposed;
    if (want && _phaseTicker == null) {
      _phaseTicker = Timer.periodic(const Duration(milliseconds: 120), (_) {
        _settleIfStale();
        if (phase != _lastPhase) _changed();
      });
    } else if (!want && _phaseTicker != null) {
      _phaseTicker!.cancel();
      _phaseTicker = null;
    }
  }

  /// The ChatGPT usage limit (HTTP 429) that made the last connect fail, or
  /// null. While it is set nothing reconnects on its own.
  UsageLimit? usageLimit;

  /// Called once per [connect] when it failed on the usage limit. Returns
  /// true when the app changed something worth one immediate retry (e.g. it
  /// switched gpt-live to Direct realtime because the user allows that).
  Future<bool> Function(UsageLimit limit)? onUsageLimit;

  /// Disconnected on purpose (app in the background, muted or offline);
  /// [resume] connects again.
  bool get suspended => _suspended;
  bool _suspended = false;

  Future<void> connect() => _connect(allowFallback: true);

  Future<void> _connect({required bool allowFallback}) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _suspended = false;
    // A platform mic stays open across the reconnect (its audio is buffered
    // meanwhile); a backend-owned one (WebRTC) goes with its session.
    if (_micManaged) await _closeMic();
    await _disconnectBackend(keepMic: true);
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
    // Open the platform mic now, not after the handshake (1-3 s): what the
    // user says meanwhile is buffered and flushed once the session is ready.
    // WebRTC captures through its own media track, created by connect; its
    // mic opens as soon as the call is up (the handshake gap stays there).
    if (b is ManagedAudioBackend) {
      // Switching to WebRTC: the platform mic kept from before goes.
      if (_mic != null) await _closeMic();
      if (!identical(_backend, b)) return;
    } else if (_micMode != MicMode.muted) {
      // Concurrently with the handshake: connect never waits for the mic (a
      // slow device or AEC module load), and a failed open does not stop it.
      unawaited(_openMicWhileConnecting(b));
    }
    UsageLimit? limit;
    try {
      debugPrint('pre-connect: connect start');
      final cfg = await sessionConfig(_conv);
      context.configure(accounting: b.contextAccounting, overheadTokens: contextOverhead(cfg, b.contextAccounting));
      await b.connect(cfg);
      debugPrint('pre-connect: connect end');
      if (!identical(_backend, b)) return;
      _status = SessionStatus.connected;
      usageLimit = null;
      // Synchronously with the switch to connected: no live chunk can slip
      // in between the buffered audio and the live stream.
      _flushPreConnect(b);
      _pushScreenMemory();
      _flushPendingImages();
      // The mic only runs while connected (offline it would capture for
      // nothing): the backend's own (WebRTC), or the platform capture, whose
      // open (started with connect) is not awaited: a slow one must not hold
      // the session up.
      if (_micMode != MicMode.muted) {
        if (b is ManagedAudioBackend) {
          await _openMic();
        } else {
          unawaited(_openMic());
        }
      }
      _levelsChanged.value++;
    } catch (e) {
      if (!identical(_backend, b)) return;
      limit = UsageLimit.parse(e);
      usageLimit = limit;
      // A failed session must not keep its media alive (a half-built WebRTC
      // call keeps the audio device module recording). The platform mic
      // keeps buffering only while an automatic reconnect follows.
      await _releaseBackend(keepMic: _reconnecting && limit == null);
      _status = SessionStatus.error;
      statusDetail = limit?.message ?? '$e';
      debugPrint('voice session failed: $e');
    }
    _syncPhaseTicker();
    _changed();
    final hook = onUsageLimit;
    if (limit != null && allowFallback && hook != null && !_disposed) {
      if (await hook(limit)) await _connect(allowFallback: false);
    }
  }

  /// Closes the backend without touching the status (a failed or fatally
  /// broken session keeps showing its error).
  Future<void> _releaseBackend({bool keepMic = false}) async {
    if (!keepMic || _micManaged) await _closeMic();
    await _eventSub?.cancel();
    _eventSub = null;
    final b = _backend;
    _backend = null;
    if (b != null) {
      try {
        await b.close();
      } catch (_) {}
    }
  }

  Future<void> _disconnectBackend({bool keepMic = false}) async {
    _resetTurnState();
    await _releaseBackend(keepMic: keepMic);
    _status = SessionStatus.disconnected;
    _syncPhaseTicker();
  }

  /// Disconnects to save power (app in the background while muted or
  /// offline): no session, no mic, no timers. [resume] reconnects.
  Future<void> suspend() async {
    if (_disposed || _suspended) return;
    debugPrint('voice: suspending (status ${_status.name})');
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = false;
    _reconnectAttempt = 0;
    await _disconnectBackend();
    _suspended = true;
    _changed();
  }

  /// Reconnects after [suspend]. Does nothing unless suspended.
  Future<void> resume() async {
    if (_disposed || !_suspended) return;
    debugPrint('voice: resuming');
    await connect();
    _retryIfFailed();
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
    _qaHeldTimer?.cancel();
    _qaHeldTimer = null;
    _qaHeld.clear();
    _qaIgnoredItems.clear();
    _lastUtteranceId = null;
    _lastUtterancePcm = null;
    _finishAssistant(interrupted: _assistantMsg != null);
    _awaitingResponse = false;
    _discardUntilDone = false;
    _endHold();
    _held.clear();
    _dropUntil = null;
    _localVad.reset();
    _stopOut();
  }

  /// Stops playback now (and tells the echo guard nothing more is heard).
  void _stopOut() {
    if (_playing) _audibleUntil = DateTime.now().add(_echoTail + const Duration(milliseconds: 60));
    _out?.stop();
    _guard.stopPlayback();
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _paused = null;
    _stretch.clear();
    _stretchBytes = 0;
  }

  /// Hands Woi audio to the player (and the echo guard its reference).
  void _play(Uint8List pcm16) {
    final p = _paused;
    if (p != null) {
      p.add(pcm16);
      return;
    }
    if (_guard.queuedMs <= 0) {
      _stretch.clear();
      _stretchBytes = 0;
    }
    _stretch.add(pcm16);
    _stretchBytes += pcm16.length;
    while (_stretch.length > 1 && _stretchBytes - _stretch.first.length > kVoiceBytesPerSecond * 60) {
      _stretchBytes -= _stretch.removeAt(0).length;
    }
    _kwsReference(pcm16);
    _guard.onPlayback(pcm16);
    // Echo tail (the guard's window) plus the server VAD's reaction time.
    _echoWindowUntil = DateTime.now().add(Duration(milliseconds: _guard.queuedMs + 1300));
    _audibleUntil = DateTime.now().add(Duration(milliseconds: _guard.queuedMs) + _echoTail);
    _out?.write(pcm16);
  }

  // ---- offline stop-word spotting

  /// Woi is speaking or paused: the only time the spotter is fed.
  bool get _kwsActive => _playing || _paused != null || _assistantAudible;

  /// Starts the spotter (setting on) or stops it (off); re-arms on a new
  /// keyword list.
  bool _kwsEnsure() {
    final o = options();
    if (!o.stopWordDetection || stopWordSpotter == null || _micMode != MicMode.handsFree) {
      if (_kws != null) unawaited(_kwsStop());
      return false;
    }
    final words = o.stopWords.map((w) => w.trim()).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return false;
    final key = words.join('\n');
    if (_kws == null) {
      final k = stopWordSpotter!();
      _kws = k;
      _kwsSub = k.hits.listen(_onKwsHit);
    }
    if (key != _kwsWords) {
      _kwsWords = key;
      _kws!.start(words).catchError((Object e) => debugPrint('kws: unavailable: $e'));
    }
    return true;
  }

  Future<void> _kwsStop() async {
    final k = _kws;
    _kws = null;
    _kwsWords = null;
    await _kwsSub?.cancel();
    _kwsSub = null;
    await k?.dispose();
  }

  /// Woi's audio, stamped with when the speaker plays it.
  void _kwsReference(Uint8List pcm16) {
    if (!_kwsEnsure()) return;
    _kws!.addReference(pcm16, DateTime.now().add(Duration(milliseconds: max(0, _guard.queuedMs))));
  }

  /// QA only (`WOI_QA_DUMP_KWS_MIC=<path>`, read once at startup): every mic
  /// chunk the spotter path sees (the mic before the AEC when the platform
  /// has one, [RawMicCapable], else the normal mic; 24 kHz mono s16, raw) is
  /// appended to `<path>`, with `<path>.times` holding `<epoch ms> <bytes>`
  /// per chunk, for `tool/kws_proto.dart`. Unset (the default): no effect.
  static final String? qaDumpKwsMicEnv = Platform.environment['WOI_QA_DUMP_KWS_MIC'];
  IOSink? _qaDump;
  IOSink? _qaDumpTimes;

  void _qaDumpMic(Uint8List chunk) {
    final path = qaDumpKwsMicEnv;
    if (path == null || path.isEmpty || _disposed) return;
    _qaDump ??= File(path).openWrite(mode: FileMode.append);
    _qaDumpTimes ??= File('$path.times').openWrite(mode: FileMode.append);
    _qaDump!.add(chunk);
    _qaDumpTimes!.writeln('${DateTime.now().millisecondsSinceEpoch} ${chunk.length} ${_kwsActive ? 1 : 0}');
  }

  /// Mic audio (before the AEC if possible) while Woi is audible or paused.
  void _kwsMic(Uint8List chunk) {
    _qaDumpMic(chunk);
    if (!_kwsActive || _micMode != MicMode.handsFree) return;
    if (!_kwsEnsure()) return;
    _kws!.addMic(chunk, DateTime.now());
  }

  /// A stop word the user said over Woi: pause + local cut (stays stopped).
  void _onKwsHit(KwsHit h) {
    if (_disposed) return;
    final speaking = _playing || _paused != null;
    final lag = DateTime.now().difference(h.micTime).inMilliseconds;
    if (!speaking || !options().stopWordDetection) {
      kwsIgnored++;
      debugPrint('kws: "${h.keyword}" ignored (Woi not speaking), lag $lag ms');
      return;
    }
    kwsCuts++;
    final why = 'kws "${h.keyword}" threshold ${h.threshold.toStringAsFixed(2)}, lag $lag ms';
    debugPrint('barge-in: $why t=${DateTime.now().millisecondsSinceEpoch}');
    if (_userSpeaking) {
      // The server already has the turn: just make sure Woi is silent.
      _bargeIn();
      _changed();
      return;
    }
    if (_paused == null) _pause();
    _localCut(why);
  }

  /// Local onset: silence Woi now, keep the unheard rest for [_resume].
  void _pause() {
    final b = _unheard();
    _stopOut();
    _paused = b;
    _backend?.playbackPaused(true);
    _pausedAt = DateTime.now();
    _pauseVoicedMs = 0;
    _pauseMicPeak = 0;
    _pauseTimer = Timer(pauseEchoTail + pauseVoiceWindow, _pauseDecide);
  }

  /// Raw mic level while paused (after the echo tail) / the noise floor
  /// while nothing plays.
  void _trackMicLevel(Uint8List chunk) {
    final n = chunk.length ~/ 2;
    if (n == 0) return;
    final bd = ByteData.sublistView(chunk);
    var e = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      e += v * v;
    }
    final rms = sqrt(e / n);
    final at = _pausedAt;
    if (_paused != null && at != null) {
      final ms = DateTime.now().difference(at);
      if (ms < pauseEchoTail || ms > pauseEchoTail + pauseVoiceWindow) return;
      if (rms > _pauseMicPeak) _pauseMicPeak = rms;
      if (rms >= max(pauseVoiceMinRms, _micFloorRms * 3.16)) {
        _pauseVoicedMs += n * 1000 ~/ kVoiceSampleRate;
      }
      return;
    }
    if (_userSpeaking || _playing || _assistantAudible || _guard.echoExpected) return;
    _micFloorRms = rms < _micFloorRms || _micFloorRms == 0 ? _micFloorRms * 0.8 + rms * 0.2 : _micFloorRms * 0.995 + rms * 0.005;
  }

  /// [pauseEchoTail] + [pauseVoiceWindow] after the pause with no server
  /// speech start: the user keeps talking (voice in the quiet pause) or said
  /// a short word (strong onset, still voiced when it fired) -> [_localCut].
  /// Otherwise a strong onset is held for the server, a weak one resumes at
  /// the end of [_onsetConfirmWindow]. Peak alone never cuts.
  void _pauseDecide() {
    _pauseTimer = null;
    if (_paused == null) return;
    final peak = _guard.onsetPeakRms;
    final why =
        'peak ${peak.toStringAsFixed(3)}, at firing ${_onsetFireRms.toStringAsFixed(3)}, '
        'pause voiced $_pauseVoicedMs ms, pause mic peak ${_pauseMicPeak.toStringAsFixed(4)}, floor ${_micFloorRms.toStringAsFixed(4)}';
    if (_pauseVoicedMs >= pauseVoiceMinMs) return _localCut('voice in the pause, $why');
    if (peak >= onsetShortCutRmsValue && _onsetFireRms >= onsetShortCutFireRmsValue) {
      return _localCut('short word, $why');
    }
    if (_pauseVoicedMs == 0 && _onsetFireRms < onsetShortCutFireRmsValue) {
      // Nothing voiced after the tail and no near-end excess left when it
      // fired: echo (e29: false pauses at firing 0.000-0.013). Resume now
      // instead of holding ~2.4 s of silence for the server.
      onsetsQuietResumed++;
      debugPrint('barge-in: quiet pause, resuming now ($why)');
      return _resume();
    }
    debugPrint('barge-in: quiet pause ($why)');
    final rest = _onsetConfirmWindow - pauseEchoTail - pauseVoiceWindow;
    if (peak >= onsetHoldMinRms) {
      onsetsHeld++;
      debugPrint('barge-in: strong onset: holding ${onsetHoldExtra.inMilliseconds} ms more for the server');
      _pauseTimer = Timer(rest + onsetHoldExtra, _onsetUnconfirmed);
      return;
    }
    _pauseTimer = Timer(rest.isNegative ? Duration.zero : rest, _onsetUnconfirmed);
  }

  /// No server speech start in time: resume where it paused.
  void _onsetUnconfirmed() {
    _pauseTimer = null;
    if (_paused == null) return;
    debugPrint('barge-in: onset unconfirmed (peak excess rms ${_guard.onsetPeakRms.toStringAsFixed(3)})');
    _resume();
  }

  /// A strong onset the server never confirmed: the user interrupted
  /// (typically a short "stop"). Stop like a confirmed barge-in (playback
  /// off, reply cancelled and truncated at the heard position), create no
  /// response and wait for the user. A late transcript for the span is
  /// handled as usual (stop stays stopped, a request is answered, echo or
  /// filler does nothing: the cut reply is not resumed).
  void _localCut(String why) {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    if (_paused == null || _userSpeaking || _disposed) return;
    localCuts++;
    debugPrint(
      'barge-in: local cut ($why, no server speech start): '
      'stopped, waiting for the user t=${DateTime.now().millisecondsSinceEpoch}',
    );
    _bargeIn();
    _cutTail = null;
    _awaitingResponse = false;
    _qaReplayHeld('local cut');
    _changed();
  }

  /// The written audio the speaker has not played yet.
  BytesBuilder _unheard() {
    final paused = _paused;
    if (paused != null) return BytesBuilder(copy: false)..add(paused.toBytes());
    final unheard = min(_guard.queuedMs * kVoiceBytesPerSecond ~/ 1000, _stretchBytes) & ~1;
    final b = BytesBuilder(copy: false);
    var skip = _stretchBytes - unheard;
    for (final c in _stretch) {
      if (skip >= c.length) {
        skip -= c.length;
        continue;
      }
      b.add(skip > 0 ? Uint8List.sublistView(c, skip) : c);
      skip = 0;
    }
    return b;
  }

  /// The onset was not confirmed by the server: play on from where it paused.
  void _resume() {
    final p = _paused;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _paused = null;
    if (p == null || _userSpeaking || _disposed) return;
    _qaDropHeld();
    final pcm = p.takeBytes();
    _backend?.playbackPaused(false);
    onsetsResumed++;
    debugPrint(
      'barge-in: onset not confirmed, resuming (${pcm.length * 1000 ~/ kVoiceBytesPerSecond} ms left) '
      't=${DateTime.now().millisecondsSinceEpoch}',
    );
    if (pcm.isNotEmpty) _play(pcm);
    _changed();
  }

  /// Switches to another conversation; reconnects so the model gets its
  /// context (summary) fresh.
  Future<void> switchConversation(Conversation c) async {
    if (_conv.messages.isNotEmpty) await store.save(_conv);
    _pendingImages.clear();
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
    } else if (_status == SessionStatus.connected ||
        (_status == SessionStatus.connecting && _backend != null && _managed == null)) {
      await _openMic();
      _managed?.setInputEnabled(_forwarding);
    }
    if (_userSpeaking && !_forwarding) {
      // Switched to push-to-talk mid-utterance: no more audio reaches the
      // server, so close the turn like a talk-button release (otherwise
      // "Hearing you…" and the bubble's dots stay up forever).
      final b = _backend;
      if (b != null && _status == SessionStatus.connected) b.sendAudio(Uint8List(kVoiceBytesPerSecond * 8 ~/ 10));
      _onSpeechStopped();
    }
    _changed();
  }

  /// Closes and re-opens an open microphone so a capture setting (echo
  /// cancellation) takes effect.
  Future<void> reopenMic() async {
    if (_mic == null) return;
    final managedMic = _micManaged;
    await _closeMic();
    // A platform mic also reopens while (re)connecting: it keeps buffering.
    if (_micMode != MicMode.muted &&
        (_status == SessionStatus.connected || (!managedMic && _status == SessionStatus.connecting))) {
      await _openMic();
      _managed?.setInputEnabled(_forwarding);
    }
    _changed();
  }

  Future<void> _openMicWhileConnecting(VoiceBackend b) async {
    debugPrint('pre-connect: mic open start');
    try {
      await _openMic();
    } catch (e) {
      debugPrint('pre-connect: mic open failed: $e');
    }
    debugPrint('pre-connect: mic open end (open ${_mic != null}, ${_status.name})');
    if (identical(_backend, b)) _changed();
  }

  // An open in flight (shared by concurrent callers) and the close
  // generation: a mic that arrives after a close is closed again.
  Future<void>? _micOpening;
  int _micGen = 0;

  Future<void> _openMic() {
    if (_mic != null) return Future.value();
    final pending = _micOpening;
    if (pending != null) return pending;
    final f = _micOpening = _doOpenMic();
    unawaited(f.whenComplete(() {
      if (identical(_micOpening, f)) _micOpening = null;
    }));
    return f;
  }

  Future<void> _doOpenMic() async {
    final gen = _micGen;
    try {
      final managed = _managed;
      final mic = managed != null ? await managed.openManagedMic() : await audio.openMic();
      if (gen != _micGen || _disposed) {
        await mic.close();
        return;
      }
      _micManaged = managed != null;
      managed?.setInputEnabled(_forwarding);
      _mic = mic;
      _micSub = mic.chunks.listen(_onMicChunk);
      _levelsChanged.value++;
      if (managed != null && options().onsetMicWithManagedAudio) unawaited(_openOnsetMic());
      if (managed == null) unawaited(_openKwsRawMic());
    } catch (e) {
      _addSystem('Microphone unavailable: $e', meta: {'type': 'error'});
    }
  }

  Future<void> _openOnsetMic() async {
    if (_onsetMic != null || !options().localBargeIn) return;
    try {
      final m = await audio.openMic();
      if (_mic == null || !_micManaged || _onsetMic != null) {
        await m.close();
        return;
      }
      _onsetMic = m;
      _onsetSub = m.chunks.listen((c) {
        if (_status == SessionStatus.connected && _micMode == MicMode.handsFree) {
          _feedOnset(c);
          _kwsMic(c);
        }
      });
    } catch (e) {
      debugPrint('barge-in mic unavailable: $e');
    }
  }

  Future<void> _openKwsRawMic() async {
    final a = audio;
    if (_kwsRawMic != null || a is! RawMicCapable || !options().stopWordDetection || stopWordSpotter == null) return;
    try {
      final m = await (a as RawMicCapable).openRawMic();
      if (m == null) return;
      if (_mic == null || _micManaged || _kwsRawMic != null) {
        await m.close();
        return;
      }
      _kwsRawMic = m;
      _kwsRawSub = m.chunks.listen((c) {
        if (_status == SessionStatus.connected && _forwarding) _kwsMic(c);
      });
      debugPrint('kws: listening on the mic before the AEC');
    } catch (e) {
      debugPrint('kws: raw mic unavailable ($e), using the AEC mic');
    }
  }

  Future<void> _closeMic() async {
    _micGen++;
    _micOpening = null;
    _pending.clear();
    _preShot = null;
    await _micSub?.cancel();
    _micSub = null;
    final m = _mic;
    _mic = null;
    _micManaged = false;
    await m?.close();
    await _onsetSub?.cancel();
    _onsetSub = null;
    final o = _onsetMic;
    _onsetMic = null;
    await o?.close();
    await _kwsRawSub?.cancel();
    _kwsRawSub = null;
    final r = _kwsRawMic;
    _kwsRawMic = null;
    await r?.close();
    _levelsChanged.value++;
  }

  bool get _forwarding => _micMode == MicMode.handsFree || (_micMode == MicMode.pushToTalk && _pttHeld);

  // Half-duplex gate (media route): recent real chunks held back while
  // silence went to the server, and the end of the post-playback hangover.
  final List<Uint8List> _gated = [];
  DateTime _gateUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const _gateHangover = Duration(milliseconds: 300);
  static const _leadInBytes = kVoiceBytesPerSecond * 3 ~/ 10;
  int _gatedBytes = 0;

  /// Sends [chunk], or silence while the half-duplex gate is closed.
  /// Returns true when it already fed the onset detector.
  bool _sendGated(VoiceBackend b, Uint8List chunk) {
    final before = localOnsets;
    _feedOnset(chunk);
    final now = DateTime.now();
    if (localOnsets != before) {
      // The user talks over Woi: the lead-in goes out with this chunk.
      _gateUntil = now;
      for (final c in _gated) {
        b.sendAudio(c);
      }
      _gated.clear();
      _gatedBytes = 0;
      b.sendAudio(chunk);
      return true;
    }
    if (_playing && !_userSpeaking) _gateUntil = now.add(_gateHangover);
    if (now.isBefore(_gateUntil)) {
      gatedChunks++;
      _gated.add(chunk);
      _gatedBytes += chunk.length;
      // Keep ~300 ms of lead-in: the reference-aware onset needs ~100–200 ms
      // of speech before it fires, and that start must still reach the server.
      while (_gated.length > 1 && _gatedBytes - _gated.first.length >= _leadInBytes) {
        _gatedBytes -= _gated.removeAt(0).length;
      }
      b.sendAudio(Uint8List(chunk.length));
    } else {
      _gated.clear();
      _gatedBytes = 0;
      b.sendAudio(chunk);
    }
    return true;
  }

  /// Mic chunks replaced by silence by the half-duplex gate (tests/diagnostics).
  int gatedChunks = 0;

  bool _sawMicChunk = false;

  void _onMicChunk(Uint8List chunk) {
    if (!_sawMicChunk) {
      _sawMicChunk = true;
      debugPrint('pre-connect: first mic chunk (${_status.name})');
    }
    if (_status != SessionStatus.connected) {
      if (!_micManaged && _forwarding && !_suspended) _bufferPreConnect(chunk);
      return;
    }
    final b = _backend;
    if (b == null || !_forwarding) return;
    if (!_micManaged && _kwsRawMic == null) _kwsMic(chunk);
    // Android media route: half-duplex. While Woi plays (+300 ms) the server
    // gets silence; a local onset opens it with ~160 ms of lead-in.
    final halfDuplex = !_micManaged && options().halfDuplexWhileSpeaking && _micMode == MicMode.handsFree;
    if (!halfDuplex && !_micManaged && _micMode == MicMode.handsFree) _feedOnset(chunk);
    // Self-echo gate: while Woi's audio can be in the mic (playing, or its
    // echo still on the way) the server gets silence instead, so residual
    // echo can't become a user turn. The guard opens it when the user talks
    // over Woi; the held-back audio goes first as the turn's start.
    // Off by default: on real rooms it lost barge-ins (the local detector
    // misses short words in double talk, and then the server never heard
    // them). The server gets the canceller's output; echo turns are caught by
    // the transcript guard instead.
    final gate = echoGate && !_micManaged && _micMode == MicMode.handsFree && !_userSpeaking;
    final echo = gate && (_guard.echoExpected || _assistantAudible) && !_guard.gateOpen;
    final Uint8List out;
    if (echo) {
      _gatedPcm.add(chunk);
      out = Uint8List(chunk.length);
      _gating = true;
    } else {
      if (_gating) {
        _gating = false;
        final held = _gatedPcm.drain();
        if (_guard.gateOpen && held.isNotEmpty) {
          b.sendAudio(held);
          _preRoll.add(held);
        }
      }
      out = chunk;
    }
    if (halfDuplex) {
      _sendGated(b, out);
    } else if (!_micManaged) {
      b.sendAudio(out);
    }
    if (_userSpeaking) {
      _utterancePcm.add(out);
    } else {
      _preRoll.add(out);
    }
    if (!b.hasServerVad && _micMode == MicMode.handsFree) {
      _localVad.sensitivityScale = _assistantAudible ? 2.5 : 1.0;
      switch (_localVad.process(out)) {
        case VadEvent.speechStarted:
          _onSpeechStarted();
        case VadEvent.speechStopped:
          _onSpeechStopped();
        case null:
      }
    }
  }

  void _bufferPreConnect(Uint8List chunk) {
    final voiced = _pending.add(chunk);
    if (!voiced || _preShot != null) return;
    if (!options().autoScreenshot) return;
    // Speech in the pre-roll: grab the screen now, as a live turn would.
    _preShot = screen.capture(maxWidth: options().maxScreenshotWidth).then<Screenshot?>((s) => s).catchError((
      Object e,
    ) {
      debugPrint('pre-connect screenshot failed: $e');
      return null;
    });
  }

  /// Sends the audio captured while connecting (leading silence trimmed, in
  /// ~200 ms frames, oldest first), then live streaming takes over.
  void _flushPreConnect(VoiceBackend b) {
    if (_pending.isEmpty || _micManaged) {
      _pending.clear();
      return;
    }
    debugPrint('pre-connect: buffer ${_pending.describe()}');
    final frames = _pending.take();
    final clip = BytesBuilder(copy: false);
    for (final f in frames) {
      b.sendAudio(f);
      clip.add(f);
      if (!b.hasServerVad && _micMode == MicMode.handsFree) {
        switch (_localVad.process(f)) {
          case VadEvent.speechStarted:
            _onSpeechStarted();
          case VadEvent.speechStopped:
            _onSpeechStopped();
          case null:
        }
      }
    }
    preConnectFlushedBytes += clip.length;
    debugPrint('pre-connect: flushed ${clip.length * 1000 ~/ kVoiceBytesPerSecond} ms in ${frames.length} frames');
    if (_kDumpPreConnect && Platform.isAndroid) {
      // Diagnostics (--dart-define=WOI_DUMP_PRECONNECT=true): the exact PCM
      // flushed to the API, pulled with `run-as dev.woi.woi cat files/...`.
      final pcm = Uint8List.fromList(clip.toBytes());
      unawaited(
        writeWav('/data/user/0/dev.woi.woi/files/preconnect_flush.wav', pcm).catchError((Object e) {
          debugPrint('pre-connect dump failed: $e');
        }),
      );
    }
    if (_userSpeaking) {
      _utterancePcm.add(clip.takeBytes());
    } else {
      _flushedClip = clip.takeBytes();
      _flushedAt = DateTime.now();
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
    } else if (_mic != null && !_micManaged && !_pending.isEmpty) {
      // Released while still connecting: the trailing silence goes out with
      // the buffered press.
      _pending.add(Uint8List(kVoiceBytesPerSecond * 8 ~/ 10));
    }
    _changed();
  }

  // ------------------------------------------------------------ user turns

  /// Stops the assistant now; returns whether anything was interrupted.
  bool _bargeIn() {
    final speaking = _playing || _assistantMsg != null || _paused != null;
    if (!speaking) return false;
    bargeIns++;
    final tail = _unheard().takeBytes();
    _cutTail = tail.isEmpty ? null : tail;
    _cutMsg = _assistantMsg ?? _spoken.lastOrNull?.message;
    _cutAt = DateTime.now();
    // How much of the reply was heard (its text runs ahead of its audio):
    // where in the text an echo of the cut-off point would be.
    final heard = _stretchBytes <= 0 ? 1.0 : (1 - tail.length / _stretchBytes).clamp(0.0, 1.0);
    final last = _spoken.lastOrNull;
    if (_assistantMsg == null && last != null && identical(last.message, _cutMsg)) last.heard = heard;
    _cutHeard = heard;
    _stopOut();
    // Also when the response already finished but its audio is still
    // playing: the backend truncates / mutes what was not heard.
    _backend?.cancelResponse();
    if (_assistantMsg != null) _discardUntilDone = true;
    _finishAssistant(interrupted: true);
    return true;
  }

  void _feedOnset(Uint8List chunk) {
    // The floor is the old detector's mic RMS; the guard's is the excess over
    // the predicted echo.
    _guard.minRms = options().bargeInFloor / 3;
    if (_guard.process(chunk, audible: _assistantAudible && (!_userSpeaking || _deferPending)) &&
        options().localBargeIn) {
      _localOnset();
    } else {
      _trackMicLevel(chunk);
    }
  }

  /// The user started talking over the assistant (local detector): cut the
  /// audio right away; the server confirms the turn a few hundred ms later.
  void _localOnset() {
    if (_deferPending) return _confirmDeferred('local detector');
    if (_userSpeaking || !_playing) return;
    localOnsets++;
    _lastOnsetAt = DateTime.now();
    if (_guard.onsetPeakRms >= onsetCutRms) _strongOnsetAt = _lastOnsetAt;
    _onsetFireRms = _guard.lastExcessRms;
    _pause();
    debugPrint(
      'barge-in: local onset (lag ${_guard.lagMs} ms, excess rms ${_guard.lastExcessRms.toStringAsFixed(3)}, '
      'peak ${_guard.onsetPeakRms.toStringAsFixed(3)}) '
      't=${DateTime.now().millisecondsSinceEpoch}',
    );
    _changed();
  }

  // ---- reply hold / "stop"

  void _beginHold(Message? msg) {
    if (!_holding) {
      _holding = true;
      _backend?.setReplyHold(true);
    }
    if (msg != null) _holdMsg = msg;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(seconds: 6), _releaseHold);
  }

  void _endHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdMsg = null;
    if (_holding) {
      _holding = false;
      _backend?.setReplyHold(false);
    }
  }

  /// Not "stop" after all: play what was held back.
  void _releaseHold() {
    if (!_holding) return;
    _cutTail = null;
    _endHold();
    final events = List.of(_held);
    _held.clear();
    for (final e in events) {
      _onEvent(e);
    }
  }

  /// Decides a held reply from the transcript of the interrupting utterance.
  /// [done]: the transcript is final; [replyStarted]: the backend started a
  /// reply (on full-duplex backends the turn is then complete).
  void _checkHold({bool done = false, bool replyStarted = false}) {
    final m = _holdMsg;
    if (!_holding || m == null) return;
    final text = m.text.trim();
    if (text.isEmpty) {
      if (done) _releaseHold();
      return;
    }
    if (isStopPhrase(text)) {
      if (done || (replyStarted && _micManaged)) _onStopPhrase(m);
      return;
    }
    final suspect = _echoSuspects[m.id];
    if (suspect != null) {
      final said = suspect;
      if (done) {
        _echoSuspects.remove(m.id);
        if (isEchoOf(text, said) || _shortEcho(m, text, said)) {
          _turnDecision.putIfAbsent(m.id, () => 'dropped (echo match)');
          _onEchoTurn(m);
          return;
        }
      } else if (RegExp(r'\S+').allMatches(text).length < 4 || echoScore(text, said) >= echoThreshold - 0.3) {
        return; // could still be echo: wait for the final transcript
      }
    }
    if (done || !couldBecomeStopPhrase(text)) _releaseHold();
  }

  /// The "user" turn was Woi's own reply heard back (residual echo the
  /// server took for speech): no reply, no tool action, no bubble; what the
  /// echo cut off plays on. Repeated echo pauses hands-free listening.
  bool _shortEcho(Message m, String text, List<String> said) {
    // The detector heard the user; but while Woi is audible a lone filler or
    // foreign syllable is far likelier its echo burst that tripped it.
    if (_localOnsetTurns.contains(m.id) && !_audibleTurns.contains(m.id)) return false;
    final user = <String>[];
    for (final x in _conv.messages.reversed) {
      if (x.kind != MessageKind.user || identical(x, m) || x.text.trim().isEmpty) continue;
      user.add(x.text);
      if (user.length >= 5) break;
    }
    final why = shortEchoReason(text, said: said, userRecent: user);
    if (why == null) return false;
    shortEchoDrops++;
    _turnDecision[m.id] = 'dropped (short: $why)';
    debugPrint('echo turn: short transcript "$text" taken as echo ($why, no local onset)');
    return true;
  }

  /// Turns that began with (or right after) a local near-end onset: never
  /// dropped by the short-transcript rule ([shortEchoReason]).
  final Set<String> _localOnsetTurns = {};

  /// Turns that began while Woi was playing or paused by the onset
  /// (audible y/p): the short rule applies even with a local onset.
  final Set<String> _audibleTurns = {};

  /// Echo turns dropped by the short foreign/filler transcript rule.
  int shortEchoDrops = 0;

  /// Per user turn, for the one-line debug log at its final transcript:
  /// the state at speech start and the echo decision.
  final Map<String, String> _turnInfo = {};
  final Map<String, String> _turnDecision = {};

  void _logTurn(Message m, String text) {
    final info = _turnInfo.remove(m.id) ?? 'suspect=? deferred=? local=?';
    final kept = _conv.messages.contains(m);
    final why = _turnDecision.remove(m.id);
    final decision = kept
        ? (why != null && why.startsWith('kept') ? why : 'kept')
        : (why != null && why.startsWith('dropped') ? why : 'dropped (other)');
    var t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length > 40) t = '${t.substring(0, 40)}…';
    debugPrint('user turn: "$t" $info -> $decision');
  }

  void _onEchoTurn(Message m) {
    echoTurnsDropped++;
    final now = DateTime.now();
    final last = _lastEchoTurn;
    _echoStreak = last != null && now.difference(last) < _selfTalkSpan ? _echoStreak + 1 : 1;
    _lastEchoTurn = now;
    debugPrint('echo turn dropped ("${m.text.trim()}", $_echoStreak in a row)');
    final calls = [
      for (final e in _held)
        if (e is ToolCall) e.callId,
    ];
    // Its reply already ended (held): nothing more of it to drop.
    final replyDone = _held.any((e) => e is ResponseDone);
    _held.clear();
    String? itemId;
    _userByItem.forEach((k, v) {
      if (identical(v, m)) itemId = k;
    });
    _backend?.dropEchoTurn(itemId: itemId, callIds: calls);
    _endHold();
    _conv.messages.remove(m);
    _userByItem.removeWhere((_, v) => identical(v, m));
    _awaitingTranscript.remove(m);
    _echoSuspects.remove(m.id);
    _discardUntilDone = false;
    _dropUntil = replyDone ? null : now.add(const Duration(seconds: 4));
    _awaitingResponse = false;
    final tail = _cutTail, cut = _cutMsg, at = _cutAt;
    _cutTail = null;
    // The cut followed a strong local onset (peak >= [onsetCutRms]: the
    // user, not echo): an empty / filler / garbled transcript (a short
    // "stop" often comes back as "어") must not bring the reply back.
    final strong = _strongOnsetAt;
    if (tail != null && at != null && strong != null && at.difference(strong).abs() < const Duration(seconds: 3)) {
      debugPrint('echo turn after a strong local onset: the cut reply stays stopped');
    } else if (tail != null && at != null && now.difference(at) < const Duration(seconds: 10) && !_userSpeaking) {
      if (cut != null) cut.interrupted = false;
      debugPrint('echo turn: resuming the cut-off reply (${tail.length * 1000 ~/ kVoiceBytesPerSecond} ms)');
      _play(tail);
    }
    if (_echoStreak >= selfTalkLimit) _selfTalkBreak();
    context.onConversationChanged();
    _persistSoon();
    _changed();
  }

  void _selfTalkBreak() {
    selfTalkBreaks++;
    _echoStreak = 0;
    _lastEchoTurn = null;
    debugPrint('self-talk: pausing hands-free listening');
    _addSystem(
      'Woi kept hearing its own voice, so hands-free listening is paused. '
      'Turn the mic back on to continue (headphones or push-to-talk avoid this).',
      meta: {'type': 'self_talk'},
    );
    final cb = onSelfTalk;
    if (cb != null) {
      cb();
    } else {
      unawaited(setMicMode(MicMode.muted));
    }
  }

  /// The user said "stop" / "cancel" / "never mind": handled here, never sent
  /// on as a task. Playback stops, the running reply is cancelled and the
  /// model's answer to the stop request is dropped.
  void _onStopPhrase(Message m) {
    if (!_stopHandled.add(m.id)) return;
    stopsHandled++;
    _cutTail = null;
    debugPrint('stop phrase "${m.text.trim()}": stopping locally');
    _turnDecision[m.id] = 'kept (stop)';
    _held.clear();
    // Drop first: releasing the hold before it un-muted gpt-live for a moment.
    _backend?.stopAndDrop();
    _endHold();
    _stopOut();
    final a = _assistantMsg;
    if (a != null && _conv.messages.indexOf(a) > _conv.messages.indexOf(m)) {
      // Already the answer to "stop" itself: no bubble for it.
      _conv.messages.remove(a);
      _assistantMsg = null;
      _assistantPcm.takeBytes();
    }
    _finishAssistant(interrupted: true);
    _discardUntilDone = false;
    _dropUntil = DateTime.now().add(const Duration(seconds: 4));
    _awaitingResponse = false;
    _changed();
  }

  bool get _dropping {
    final u = _dropUntil;
    if (u == null) return false;
    if (DateTime.now().isAfter(u)) {
      _dropUntil = null;
      return false;
    }
    return true;
  }

  void _onSpeechStarted({String? itemId, bool deferred = false}) {
    if (_userSpeaking) return;
    if (_micMode == MicMode.muted) {
      // The mic is off, so this is not the user (gpt-live opens a server
      // "user turn" for typed context, noise or echo): no barge-in, no phase
      // change, no empty bubble.
      debugPrint('speech start ignored: mic muted');
      if (deferred) _backend?.dropEchoTurn(itemId: itemId);
      return;
    }
    _earconTimer?.cancel();
    _earconTimer = null;
    final now = DateTime.now();
    // A turn that may be Woi's echo: it starts while Woi is (about to be)
    // heard, or just after. With the mic gated ([echoGate]), the server only
    // got zeros while echo was expected, so just after a reply that ended
    // normally echo can only have leaked through an onset that opened the
    // gate.
    // Snapshot before [_bargeIn] stops the player (the log used to read it
    // after the cut, so it said "audible=n" on every interrupting turn).
    final audibleTag = _audibleTag;
    final onset = _lastOnsetAt;
    final leaked =
        !echoGate || _micManaged || (onset != null && now.difference(onset) < const Duration(seconds: 5));
    final echoLikely =
        _micMode == MicMode.handsFree &&
        (_paused != null ||
            _assistantAudible ||
            _guard.echoExpected ||
            (now.isBefore(_echoWindowUntil) && leaked));
    // Deferred (the server did not cut Woi off): interrupt now when the
    // local detector heard the user, else wait up to [deferWindow] for the
    // transcript to tell echo from the user; Woi talks on meanwhile.
    final local = _paused != null || (onset != null && now.difference(onset) < const Duration(milliseconds: 1500));
    final defer = deferred && echoLikely && !local;
    final interrupted = defer ? false : _bargeIn();
    if (deferred && !defer) _backend?.acceptTurn();
    _dropUntil = null;
    _userSpeaking = true;
    _deferPending = defer;
    _deferredAt = defer ? now : null;
    onTurnStart?.call();
    debugPrint('user speech start (interrupted=$interrupted) t=${DateTime.now().millisecondsSinceEpoch}');
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
    final flushedAt = _flushedAt;
    final freshFlush = flushedAt != null && now.difference(flushedAt) < const Duration(seconds: 10);
    final flushed = _flushedClip;
    _flushedClip = null;
    _flushedAt = null;
    if (freshFlush && flushed != null) _utterancePcm.add(flushed);
    final preShot = freshFlush ? _preShot : null;
    _preShot = null;
    _utterancePcm.add(_preRoll.drain());
    _currentUtterance = msg;
    if (local) _localOnsetTurns.add(msg.id);
    if (audibleTag == 'y' || audibleTag == 'p') _audibleTurns.add(msg.id);
    _turnInfo[msg.id] =
        'suspect=${echoLikely ? 'y' : 'n'} deferred=${defer ? 'y' : 'n'} local=${local ? 'y' : 'n'} '
        'audible=$audibleTag guard=${_guard.echoExpected ? 'y' : 'n'} '
        'window=${_echoWindowUntil.difference(now).inMilliseconds}ms';
    if (echoLikely) {
      _echoSuspects[msg.id] = [
        for (final r in _spoken)
          if (now.difference(r.at) < const Duration(seconds: 20)) r.window(),
      ];
      if (_echoSuspects[msg.id]!.isEmpty) _echoSuspects.remove(msg.id);
    }
    if (defer) {
      _deferMsg = msg;
      _deferTimer?.cancel();
      _deferTimer = Timer(deferWindow, _deferTimeout);
    } else if (interrupted || _echoSuspects.containsKey(msg.id) || (_holding && _holdMsg == null)) {
      _beginHold(msg);
    }
    final opts = options();
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    if (preShot != null && msg.image == null && !_screenshotStarted.contains(msg.id)) {
      // The speech was in the pre-connect audio: its screen was grabbed then.
      unawaited(_captureFor(msg, shot: preShot));
    } else if ((opts.autoScreenshot || cameraImage?.call() != null) &&
        msg.image == null &&
        !_screenshotStarted.contains(msg.id)) {
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
    debugPrint('user speech stop t=${DateTime.now().millisecondsSinceEpoch}');
    // The orb switches to "thinking" right here, before any server event
    // (not for a deferred turn: Woi is still talking).
    _awaitingResponse = !_deferPending;
    _touchTurn();
    if (!_deferPending) _scheduleThinkingEarcon();
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
      final ms = pcm.length * 1000 ~/ kVoiceBytesPerSecond;
      if (_holding && identical(_holdMsg, msg)) {
        // Long utterances are never just "stop".
        if (ms > 2500) {
          _releaseHold();
        } else {
          _holdTimer?.cancel();
          _holdTimer = Timer(const Duration(milliseconds: 2000), _releaseHold);
        }
      } else if (!_holding && !_micManaged && ms < 1300 && options().localBargeIn) {
        // A short utterance could be "stop" with nothing playing: hold the
        // reply (PCM backends buffer it) until the transcript says otherwise.
        _beginHold(msg);
        _holdTimer?.cancel();
        _holdTimer = Timer(const Duration(milliseconds: 1500), _releaseHold);
      }
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

  Future<void> _captureFor(Message msg, {Future<Screenshot?>? shot}) async {
    _screenshotStarted.add(msg.id);
    final opts = options();
    final cam = cameraImage?.call();
    final replace = cam != null && opts.cameraReplacesScreenshot;
    if (cam != null) attachContextImage(cam, to: replace ? msg : null);
    if (replace || !opts.autoScreenshot) return;
    try {
      final s = await shot ?? await screen.capture(maxWidth: options().maxScreenshotWidth);
      await attachScreenshot(s, note: 'Screen when the user spoke.', to: msg);
    } catch (e) {
      _addSystem('Screenshot failed: $e', meta: {'type': 'error'});
    }
  }

  /// Saves [shot], attaches it to [to] (or a new system message) and sends
  /// it to the model with [note]. The chat shows [label] when given (the
  /// note may carry long context such as the screen's visible text).
  Future<void> attachScreenshot(Screenshot shot, {required String note, String? label, Message? to}) async {
    onScreenshotCaptured?.call(shot);
    final target =
        to ?? _addMessage(Message(kind: MessageKind.system, text: label ?? note, meta: {'type': 'screenshot'}));
    final path = await store.saveImage(target.id, shot.png);
    target.image = ImageAttachment(
      path: path,
      width: shot.width,
      height: shot.height,
      originalWidth: shot.originalWidth,
      originalHeight: shot.originalHeight,
    );
    _sendWhenConnected(() {
      final itemId = _backend?.sendImage(
        shot.png,
        note:
            '$note Image is ${shot.width}x${shot.height} of a '
            '${shot.originalWidth}x${shot.originalHeight} screen; '
            'click_screen uses image pixel coordinates.',
      );
      if (itemId != null) target.meta[ImageMeta.serverItem] = itemId;
    });
    screenshotsSent++;
    context.onConversationChanged();
    _persistSoon();
    _changed();
    unawaited(compactImages());
  }

  // Images attached while no session is up (the assistant gesture resumes a
  // suspended Woi, a reconnect is in flight): sent once connected.
  final List<void Function()> _pendingImages = [];

  void _sendWhenConnected(void Function() send) {
    if (_status == SessionStatus.connected && _backend != null) {
      send();
      return;
    }
    _pendingImages.add(send);
    if (_pendingImages.length > 3) _pendingImages.removeAt(0);
  }

  void _flushPendingImages() {
    final pending = List.of(_pendingImages);
    _pendingImages.clear();
    for (final send in pending) {
      send();
    }
  }

  /// Number of camera/media images sent (diagnostics/tests).
  int contextImagesSent = 0;

  /// Sends a camera frame or media image to the model (at once, so a turn
  /// sent right after carries it) and attaches it to [to] or a new system
  /// message. gpt-live keeps it for delegations ([ContextImageSink]).
  /// Compaction tiers apply like for screenshots.
  Message attachContextImage(ContextImage img, {Message? to}) {
    final target =
        to ??
        _addMessage(
          Message(
            kind: MessageKind.system,
            text: img.kind == ContextImageKind.camera ? 'Camera frame' : 'Image from the viewer',
            meta: {'type': img.kind},
          ),
        );
    target.meta[ContextImageMeta.kind] = img.kind;
    _sendWhenConnected(() {
      final Object? b = _backend;
      if (b is ContextImageSink) {
        b.setContextImage(img.kind, DelegationImage(png: img.bytes, capturedAt: img.capturedAt, note: img.note));
      } else {
        final itemId = _backend?.sendImage(img.bytes, note: img.note);
        if (itemId != null) target.meta[ImageMeta.serverItem] = itemId;
      }
    });
    contextImagesSent++;
    final conv = _conv;
    store
        .saveImage(target.id, img.bytes, ext: img.isJpeg ? 'jpg' : 'png')
        .then((path) {
          target.image = ImageAttachment(
            path: path,
            width: img.width,
            height: img.height,
            originalWidth: img.width,
            originalHeight: img.height,
          );
          if (!identical(conv, _conv) || _disposed) return;
          context.onConversationChanged();
          _persistSoon();
          _changed();
          unawaited(compactImages());
        })
        .catchError((Object e) => debugPrint('saving ${img.kind} image failed: $e'));
    _changed();
    return target;
  }

  /// Forgets the camera frame kept for delegations (camera closed).
  void clearContextImage(String kind) {
    final Object? b = _backend;
    if (b is ContextImageSink) b.setContextImage(kind, null);
  }

  /// Lowers screenshot tiers (in the live context where the backend can
  /// swap items; locally always). Returns when done (tests).
  Future<void> compactImages() async {
    final ic = imageCompactor;
    if (ic == null) return;
    final conv = _conv;
    await ic.run(
      conv.messages,
      apply: _applyImageTier,
      onChanged: () {
        if (!identical(conv, _conv)) return;
        _pushScreenMemory();
        context.onConversationChanged();
        _persistSoon();
        _changed();
      },
    );
  }

  Future<bool> _applyImageTier(Message m, {Uint8List? png, String? text}) async {
    final b = _backend;
    final id = m.meta[ImageMeta.serverItem] as String?;
    if (b == null || id == null) return false;
    final next = await b.replaceImage(id, png: png, text: text);
    if (next == null) return false;
    m.meta[ImageMeta.serverItem] = next;
    return true;
  }

  /// Descriptions of screenshots that left the context, oldest first.
  String screenMemory({int maxChars = 2000}) {
    final lines = <String>[];
    for (final m in _conv.messages) {
      if (m.compacted || m.image == null) continue;
      final d = imageDescriptionOf(m);
      if (d != null) lines.add('- ${ContextManager.renderTime(m.createdAt)}: $d');
    }
    var out = lines.join('\n');
    if (out.length > maxChars) out = '…${out.substring(out.length - maxChars)}';
    return out;
  }

  void _pushScreenMemory() => _backend?.updateScreenMemory(screenMemory());

  /// Typed input (text fallback).
  void sendText(String text) {
    final t = text.trim();
    final b = _backend;
    if (t.isEmpty || b == null || _status != SessionStatus.connected) return;
    _bargeIn();
    _releaseHold();
    _dropUntil = null;
    onTurnStart?.call();
    final m = _addMessage(Message(kind: MessageKind.user, text: t));
    _conv.touch();
    if (localCommand?.call(t, typed: true) ?? false) {
      _stopHandled.add(m.id);
      _persistSoon();
      _changed();
      return;
    }
    if (isStopPhrase(t)) {
      // Typed "stop": handled locally, nothing is sent.
      _stopHandled.add(m.id);
      stopsHandled++;
      _stopOut();
      b.cancelResponse();
      _awaitingResponse = false;
      _persistSoon();
      _changed();
      return;
    }
    _awaitingResponse = true;
    _touchTurn();
    final cam = cameraImage?.call();
    if (cam != null) attachContextImage(cam);
    final pre = beforeTypedTurn?.call(t);
    if (pre == null) {
      b.sendText(t);
    } else {
      pre
          .then(
            (sent) => sent ?? t,
            onError: (Object e) {
              _addSystem('Media context failed: $e', meta: {'type': 'error'});
              return t;
            },
          )
          .then((sent) {
            if (!_disposed && identical(_backend, b)) b.sendText(sent);
          });
    }
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

  /// [qaIgnoreServerSpeech]: holds back / drops server user-turn events
  /// while Woi is speaking. Returns whether [e] was consumed.
  bool _qaFilter(BackendEvent e) {
    if (!qaIgnoreServerSpeech) return false;
    final String? id;
    switch (e) {
      case SpeechStarted(:final itemId) || SpeechStopped(:final itemId):
        id = itemId;
      case UserTranscriptDelta(:final itemId) || UserTranscriptDone(:final itemId):
        id = itemId;
      default:
        return false;
    }
    if (id != null && _qaIgnoredItems.contains(id)) {
      debugPrint('qa: ignoring ${e.runtimeType} of dropped turn $id');
      return true;
    }
    if (_qaHeld.isNotEmpty) {
      _qaHeld.add(e);
      return true;
    }
    if (e is SpeechStarted && e.deferred && !_userSpeaking && (_playing || _paused != null)) {
      qaServerStartsHeld++;
      _qaHeld.add(e);
      debugPrint(
        'qa: server speech start held for the local decision (paused=${_paused != null ? 'y' : 'n'}) '
        't=${DateTime.now().millisecondsSinceEpoch}',
      );
      _qaHeldTimer?.cancel();
      _qaHeldTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_paused == null && !_playing && !_assistantAudible) _qaReplayHeld('Woi finished');
      });
      return true;
    }
    return false;
  }

  void _qaReplayHeld(String why) {
    _qaHeldTimer?.cancel();
    _qaHeldTimer = null;
    if (_qaHeld.isEmpty) return;
    final events = List<BackendEvent>.of(_qaHeld);
    _qaHeld.clear();
    debugPrint('qa: replaying ${events.length} held server event(s) ($why)');
    for (final e in events) {
      _handle(e);
    }
  }

  void _qaDropHeld() {
    _qaHeldTimer?.cancel();
    _qaHeldTimer = null;
    if (_qaHeld.isEmpty) return;
    final start = _qaHeld.first;
    final id = start is SpeechStarted ? start.itemId : null;
    _qaHeld.clear();
    if (id != null) _qaIgnoredItems.add(id);
    debugPrint('qa: resumed: dropping the held server turn $id');
    _backend?.dropEchoTurn(itemId: id);
  }

  void _handle(BackendEvent e) {
    _touchTurn();
    if (_qaFilter(e)) return;
    final assistantSide =
        e is AssistantTranscriptDelta || e is AssistantTranscriptDone || e is AssistantAudioDelta || e is ResponseDone;
    if (assistantSide && !_discardUntilDone) {
      if (_dropping) {
        if (e is ResponseDone) _finishAssistant(interrupted: true);
        return;
      }
      if (_holding) {
        _held.add(e);
        if (e is! ResponseDone) _checkHold(replyStarted: true);
        return;
      }
    }
    switch (e) {
      case SpeechStarted(:final itemId, :final deferred):
        _onSpeechStarted(itemId: itemId, deferred: deferred);
      case SpeechStopped():
        _onSpeechStopped();
      case UserTranscriptDelta(:final text, :final itemId):
        final m = _userForTranscript(itemId);
        m.text += text;
        if (identical(m, _holdMsg)) _checkHold();
        _checkDeferred(m, done: false);
        _persistSoon();
        _changedSoon();
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
        if (_deferPending && identical(m, _deferMsg)) {
          _checkDeferred(m, done: true);
          if (!_conv.messages.contains(m)) {
            _logTurn(m, m.text);
            _changed();
            return;
          }
        }
        final local =
            !_stopHandled.contains(m.id) && _isLatestUser(m) && (localCommand?.call(m.text, typed: false) ?? false);
        if (local) {
          _onStopPhrase(m);
        } else if (identical(m, _holdMsg)) {
          _checkHold(done: true);
        } else if (isStopPhrase(m.text) && !_stopHandled.contains(m.id) && _isLatestUser(m)) {
          _onStopPhrase(m);
        }
        _echoSuspects.remove(m.id);
        _logTurn(m, m.text);
        if (_conv.messages.contains(m) && m.text.trim().isNotEmpty) _echoStreak = 0;
        _persistSoon();
        _changed();
      case AssistantTranscriptDelta(:final text):
        if (_discardUntilDone) return;
        _assistant().text += text;
        _awaitingResponse = false;
        _persistSoon();
        _changedSoon();
      case AssistantTranscriptDone(:final text):
        if (_discardUntilDone) return;
        if (text.isNotEmpty) _assistant().text = text;
        _changed();
      case AssistantAudioDelta(:final pcm16):
        if (_discardUntilDone || (_userSpeaking && !_deferPending)) return;
        _assistant();
        _awaitingResponse = false;
        _play(pcm16);
        _assistantPcm.add(pcm16);
      case ToolCall(:final callId, :final name, :final argsJson):
        if (_holding && _echoSuspects.containsKey(_holdMsg?.id)) {
          _held.add(e); // no action before we know the turn was not echo
          return;
        }
        _runTool(callId, name, argsJson);
      case Usage(:final totalContextTokens):
        context.onUsage(totalContextTokens);
      case BackendError(:final message, :final fatal, :final code):
        if (fatal && reconnectableCodes.contains(code) && maxAutoReconnects > 0) {
          _addSystem('$message; reconnecting…', meta: {'type': 'reconnect'});
          _scheduleReconnect(message);
          return;
        }
        final limit = UsageLimit.parse(message);
        _addSystem(limit?.message ?? message, meta: {'type': 'error'});
        if (fatal) {
          _status = SessionStatus.error;
          statusDetail = limit?.message ?? message;
          if (limit != null) usageLimit = limit;
          debugPrint('voice session failed: $message');
          // Nothing more comes from a fatally broken session: free its
          // mic / WebRTC call now instead of when the user presses Retry.
          unawaited(_releaseBackend().then((_) => _syncPhaseTicker()));
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

  /// Whether [m] is the newest user message (a late "stop" transcript for an
  /// old turn must not cancel the current reply).
  bool _isLatestUser(Message m) {
    for (final x in _conv.messages.reversed) {
      if (x.kind == MessageKind.user) return identical(x, m);
    }
    return false;
  }

  Message _assistant() => _assistantMsg ??= _addMessage(Message(kind: MessageKind.assistant, streaming: true));

  void _finishAssistant({bool interrupted = false}) {
    final m = _assistantMsg;
    _assistantMsg = null;
    final pcm = _assistantPcm.takeBytes();
    if (m == null) return;
    m.streaming = false;
    m.interrupted = interrupted;
    if (m.text.trim().isNotEmpty) {
      _spoken.add(_Spoken(m, DateTime.now(), interrupted && identical(m, _cutMsg) ? _cutHeard : 1));
      if (_spoken.length > 4) _spoken.removeAt(0);
    }
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
    _touchTurn();
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
  // ------------------------------------------------------------ reconnect

  /// The connection dropped: tear the dead session down now (whatever was in
  /// flight is gone) and connect again after a backoff, without the user
  /// pressing Retry.
  void _scheduleReconnect(String why, {bool keepStatus = false}) {
    if (_disposed) return;
    _reconnecting = true;
    _resetTurnState();
    // A failed connect keeps showing its error (and Retry) until the next
    // attempt starts.
    if (!keepStatus) {
      _status = SessionStatus.connecting;
      statusDetail = why;
    }
    final ms = reconnectBaseDelay.inMilliseconds * (1 << _reconnectAttempt.clamp(0, 10));
    final delay = Duration(milliseconds: ms.clamp(0, 30000));
    debugPrint('voice connection lost ($why); reconnect #${_reconnectAttempt + 1} in ${delay.inMilliseconds}ms');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_autoReconnect()));
    _changed();
  }

  Future<void> _autoReconnect() async {
    _reconnectTimer = null;
    if (_disposed || !_reconnecting) return;
    _reconnectAttempt++;
    final micMode = _micMode;
    await connect();
    if (_disposed) return;
    if (_status == SessionStatus.connected) {
      _reconnecting = false;
      _reconnectAttempt = 0;
      autoReconnects++;
      if (micMode != MicMode.muted && _mic == null) await setMicMode(micMode);
      debugPrint('voice reconnected (context restored)');
      _addSystem('Reconnected', meta: {'type': 'reconnect'});
      _changed();
    } else if (_suspended) {
      return;
    } else if (usageLimit != null) {
      // A usage limit (429) does not go away by retrying: one retry at reset.
      await _closeMic();
      _status = SessionStatus.error;
      _scheduleLimitRetry();
      _changed();
    } else if (_reconnectAttempt < maxAutoReconnects) {
      _scheduleReconnect(statusDetail ?? 'connect failed');
    } else {
      _reconnecting = false;
      _reconnectAttempt = 0;
      await _closeMic();
      _status = SessionStatus.error;
      _addSystem('Could not reconnect: ${statusDetail ?? 'unknown error'}', meta: {'type': 'error'});
      _changed();
    }
  }

  Future<void> shutdown() async {
    await _kwsStop();
    await _qaDump?.close();
    await _qaDumpTimes?.close();
    _qaDump = null;
    _qaDumpTimes = null;
    _reconnectTimer?.cancel();
    _reconnecting = false;
    _phaseTicker?.cancel();
    _phaseTicker = null;
    _screenshotTimer?.cancel();
    await _compactionSub?.cancel();
    await _closeMic();
    await _disconnectBackend();
    await _player?.close();
    await _earconPlayer?.close();
    await store.flush(_conv);
    await _compactionEvents.close();
    _levelsChanged.dispose();
    _deltaNotify?.cancel();
    _qaHeldTimer?.cancel();
    _disposed = true;
    dispose();
  }
}

/// A reply Woi spoke, and how much of it was heard before a barge-in.
class _Spoken {
  _Spoken(this.message, this.at, this.heard);
  final Message message;
  final DateTime at;
  double heard;

  /// The words an echo of it could be: the last ~15 heard (by text share)
  /// and a few beyond the estimate.
  String window() {
    final words = message.text.trim().split(RegExp(r'\s+'));
    final end = (words.length * heard).round();
    return words.sublist(max(0, end - 15), min(words.length, end + 4)).join(' ');
  }
}
