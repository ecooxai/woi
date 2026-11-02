import 'dart:typed_data';

import '../auth/auth.dart';

/// Audio format used everywhere between the app and the voice backend:
/// signed 16-bit little-endian PCM, 24 kHz, mono.
const int kVoiceSampleRate = 24000;
const int kVoiceBytesPerSecond = kVoiceSampleRate * 2;

/// A function the model may call. [parameters] is a JSON-schema object.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

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
  });

  final String model;
  final String voice;
  final String instructions;
  final List<ToolSpec> tools;
  final Credentials? credentials;

  /// Summary of earlier (compacted) conversation, to be injected on
  /// (re)connect so the model keeps long-term context.
  final String? priorContext;
}

/// Events emitted by a [VoiceBackend].
sealed class BackendEvent {
  const BackendEvent();
}

class UserTranscriptDelta extends BackendEvent {
  const UserTranscriptDelta(this.text);
  final String text;
}

class UserTranscriptDone extends BackendEvent {
  const UserTranscriptDone(this.text);
  final String text;
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

class SpeechStarted extends BackendEvent {
  const SpeechStarted();
}

class SpeechStopped extends BackendEvent {
  const SpeechStopped();
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

  Future<void> connect(SessionConfig config);

  /// Continuous microphone audio, PCM16 24 kHz mono.
  void sendAudio(Uint8List pcm16);

  void sendText(String text);

  void sendImage(Uint8List png, {String? note});

  void sendToolResult(String callId, String jsonOutput);

  void cancelResponse();

  Future<void> close();
}
