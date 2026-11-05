import 'dart:typed_data';

import '../../platform/audio_io.dart';
import '../auth/auth.dart';
import '../context/context_manager.dart';

/// Audio format used everywhere between the app and the voice backend:
/// signed 16-bit little-endian PCM, 24 kHz, mono.
const int kVoiceSampleRate = 24000;
const int kVoiceBytesPerSecond = kVoiceSampleRate * 2;

/// A function the model may call. [parameters] is a JSON-schema object.
class ToolSpec {
  const ToolSpec({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// OpenAI-realtime style `session.tools[]` entry.
  Map<String, Object?> toJson() => {
    'type': 'function',
    'name': name,
    'description': description,
    'parameters': parameters,
  };
}

/// Everything a backend needs to open a live session.
class SessionConfig {
  const SessionConfig({
    required this.model,
    required this.voice,
    required this.instructions,
    this.tools = const [],
    this.credentials,
    this.priorContext,
    this.recentContext,
    this.environment,
    this.pinnedNote,
    this.phone = false,
  });

  final String model;
  final String voice;
  final String instructions;
  final List<ToolSpec> tools;
  final Credentials? credentials;

  /// Summary of earlier (compacted) conversation, to be injected on
  /// (re)connect so the model keeps long-term context.
  final String? priorContext;

  /// Text of the turns after [priorContext] (still verbatim in the
  /// conversation). Backends that cannot replay items (gpt-live) put it in
  /// the startup instructions.
  final String? recentContext;

  /// Real user name, \$HOME and workspace dir, for prompts of models that
  /// run tools (so they never invent paths like /home/oai).
  final String? environment;

  /// The conversation note, pinned in the context every turn (never
  /// compacted). See [PinnedNoteSync] for how backends keep it current.
  final String? pinnedNote;

  /// Woi runs on a phone: a screenshot there steps Woi aside, so tools must
  /// not capture the screen speculatively.
  final bool phone;
}

/// Events emitted by a [VoiceBackend].
sealed class BackendEvent {
  const BackendEvent();
}

/// Partial user transcript. [itemId] names the user turn it belongs to (the
/// conversation item id in direct mode, a client turn key for gpt-live); the
/// pipeline uses it to keep words, screenshot and audio in one message even
/// when the transcription arrives after the assistant started replying.
class UserTranscriptDelta extends BackendEvent {
  const UserTranscriptDelta(this.text, {this.itemId});
  final String text;
  final String? itemId;
}

/// Final user transcript (replaces the partial text); see [UserTranscriptDelta].
class UserTranscriptDone extends BackendEvent {
  const UserTranscriptDone(this.text, {this.itemId, this.noSpeech = false});
  final String text;
  final String? itemId;

  /// The server saw no user turn for [itemId] (a local VAD false start); an
  /// empty message without a screenshot may be dropped.
  final bool noSpeech;
}

class AssistantTranscriptDelta extends BackendEvent {
  const AssistantTranscriptDelta(this.text);
  final String text;
}

class AssistantTranscriptDone extends BackendEvent {
  const AssistantTranscriptDone(this.text);
  final String text;
}

/// A chunk of assistant speech, PCM16 24 kHz mono.
class AssistantAudioDelta extends BackendEvent {
  const AssistantAudioDelta(this.pcm16);
  final Uint8List pcm16;
}

class ToolCall extends BackendEvent {
  const ToolCall(this.callId, this.name, this.argsJson);
  final String callId;
  final String name;
  final String argsJson;
}

class Usage extends BackendEvent {
  const Usage(this.inputTokens, this.outputTokens, this.totalContextTokens);
  final int inputTokens;
  final int outputTokens;
  final int totalContextTokens;
}

/// The user started talking. A repeated [itemId] continues that turn (e.g.
/// a short pause the server treats as one turn) instead of opening a new one.
class SpeechStarted extends BackendEvent {
  const SpeechStarted({this.itemId, this.deferred = false});
  final String? itemId;

  /// The server started a turn while Woi was speaking but neither cut Woi
  /// off nor will answer it by itself: the pipeline decides
  /// ([VoiceBackend.acceptTurn] to interrupt, [VoiceBackend.dropEchoTurn]
  /// for echo).
  final bool deferred;
}

class SpeechStopped extends BackendEvent {
  const SpeechStopped({this.itemId});
  final String? itemId;
}

/// Transcript of a [VoiceBackend.probeSpan] clip (empty: nothing heard or
/// transcription failed). Not a user turn: the clip is never answered.
class ProbeTranscript extends BackendEvent {
  const ProbeTranscript(this.text);
  final String text;
}

class BackendError extends BackendEvent {
  const BackendError(this.message, {this.code, this.fatal = false});
  final String message;
  final String? code;
  final bool fatal;
}

class ResponseDone extends BackendEvent {
  const ResponseDone({this.cancelled = false});
  final bool cancelled;
}

/// A realtime speech-to-speech session (OpenAI-realtime style).
///
/// Implementations: [MockVoiceBackend] today; a WebSocket backend later.
/// After [sendToolResult] the backend is expected to continue the response
/// (i.e. issue `response.create` itself).
abstract class VoiceBackend {
  Stream<BackendEvent> get events;

  /// Whether the backend detects speech itself and emits [SpeechStarted] /
  /// [SpeechStopped]. When false the turn pipeline runs a local energy VAD.
  bool get hasServerVad => true;

  /// How [ContextManager] measures this backend's context.
  ContextAccounting get contextAccounting => ContextAccounting.usage;

  /// Work in flight that will still produce events (a response being
  /// generated, a delegation or tool running). While true the pipeline keeps
  /// showing "Thinking…" however long it takes.
  bool get busy => false;

  Future<void> connect(SessionConfig config);

  /// Continuous microphone audio, PCM16 24 kHz mono.
  void sendAudio(Uint8List pcm16);

  void sendText(String text);

  /// Adds a screenshot to the model context. Returns the id of the context
  /// item that holds it when the backend can later [replaceImage] it.
  String? sendImage(Uint8List png, {String? note});

  /// Replaces the screenshot item [itemId] with a smaller copy ([png]) or a
  /// text description ([text]), between responses. Returns the new item id,
  /// or null if not supported / the item is gone.
  Future<String?> replaceImage(String itemId, {Uint8List? png, String? text}) async => null;

  /// Descriptions of earlier screenshots that left the context (for
  /// backends whose model context is text only and that delegate actions).
  void updateScreenMemory(String text) {}

  void sendToolResult(String callId, String jsonOutput);

  void cancelResponse();

  /// The user asked to stop ("stop", "cancel", "never mind"): cancel what is
  /// playing and drop the reply the model makes to that request (no spoken
  /// acknowledgement, no delegated action).
  void stopAndDrop() => cancelResponse();

  /// A user turn was Woi's own voice heard back (echo): drop the reply to it
  /// like [stopAndDrop], forget the turn ([itemId], the server's user item)
  /// and close the tool calls its reply made ([callIds]) without running
  /// them or asking for another reply.
  void dropEchoTurn({String? itemId, List<String> callIds = const []}) => stopAndDrop();

  /// A local onset the server VAD did not confirm (a short "stop" under
  /// Woi's echo): transcribe [pcm] (the mic around the onset) on its own and
  /// report it as a [ProbeTranscript]. Returns false if not supported.
  bool probeSpan(Uint8List pcm) => false;

  /// A [SpeechStarted.deferred] turn is the user after all: it gets a reply
  /// once it ends (the caller interrupts Woi with [cancelResponse]).
  void acceptTurn() {}

  /// While held, the next reply must not become audible (the pipeline is
  /// still deciding whether the user's interruption was just "stop").
  /// Backends that play audio themselves implement this; for PCM backends the
  /// pipeline buffers instead.
  void setReplyHold(bool hold) {}

  Future<void> close();
}

/// Optional capability of a [VoiceBackend] that owns the audio devices itself
/// (e.g. WebRTC capturing the mic and playing the reply with built-in echo
/// cancellation). The pipeline must then not open its own mic or play
/// [AssistantAudioDelta] on a platform player: it uses [openManagedMic] (for
/// levels and utterance clips) and [managedPlayer] (whose `write` only feeds
/// levels / `isPlaying`; the audio is already audible). [VoiceBackend.sendAudio]
/// is ignored by such backends.
abstract interface class ManagedAudioBackend {
  /// What the backend actually captures (PCM16 24 kHz mono) plus its level.
  Future<MicStream> openManagedMic();

  PcmPlayer get managedPlayer;

  /// Gates the outgoing mic (push-to-talk / mute).
  void setInputEnabled(bool enabled);
}
