import '../models/message.dart';

/// User recordings have their own retention window, independent of typed
/// turns, assistant speech, screenshots and tool output.
const kRetainedUserAudioMessages = 5;

/// Active recordings in conversation order. Already archived messages stay
/// archived; compaction never removes their audio files from chat history.
List<Message> retainedUserAudioMessages(List<Message> messages) {
  final kept = <Message>[];
  for (final message in messages.reversed) {
    if (message.compacted || message.kind != MessageKind.user || message.audio == null) continue;
    kept.add(message);
    if (kept.length == kRetainedUserAudioMessages) break;
  }
  return kept.reversed.toList(growable: false);
}

/// A small immutable reference for replaying a retained recording. Audio is
/// read lazily from the original archive, one clip at a time on reconnect.
class RetainedUserAudio {
  const RetainedUserAudio({required this.messageId, required this.path, required this.transcript});

  final String messageId;
  final String path;
  final String transcript;

  factory RetainedUserAudio.fromMessage(Message message) =>
      RetainedUserAudio(messageId: message.id, path: message.audio!.path, transcript: message.text);
}

List<RetainedUserAudio> retainedUserAudioSnapshot(Conversation conversation) => [
  for (final message in retainedUserAudioMessages(conversation.messages)) RetainedUserAudio.fromMessage(message),
];
