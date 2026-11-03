import '../context/context_manager.dart';

/// Longest note text pinned into the model context; longer notes are cut
/// (the model can still read everything with `read_note`).
const kMaxPinnedNoteChars = 24000;

/// The block appended to the voice instructions / delegation input so the
/// model always sees the current note. Never compacted or summarised.
String pinnedNoteBlock(String? markdown) {
  final raw = (markdown ?? '').trimRight();
  final body = raw.isEmpty
      ? '(empty: nothing recorded yet)'
      : raw.length <= kMaxPinnedNoteChars
      ? raw
      : '${raw.substring(0, kMaxPinnedNoteChars)}\n… (note truncated here; call read_note for the rest)';
  return '# Conversation note (pinned, always current)\n'
      'The user and you share this Markdown note; it is shown in the app. It is the source of truth for '
      'facts, decisions, todos and paths recorded in this conversation. Answer from it when relevant.\n'
      '<note>\n$body\n</note>';
}

/// Instructions plus the pinned note.
String withPinnedNote(String instructions, String? note) => '$instructions\n\n${pinnedNoteBlock(note)}';

/// Context tokens taken by the pinned note (its own context-meter segment).
int pinnedNoteTokens(String? markdown) => ContextManager.textTokens(pinnedNoteBlock(markdown));
