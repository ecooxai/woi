/// Optional capability of a [VoiceBackend] that keeps the conversation note
/// pinned in the model context.
///
/// * Direct realtime: the note is part of the session instructions; a change
///   is pushed with `session.update` before the next response.
/// * gpt-live: instructions are immutable, so the note goes into the startup
///   (and reconnect/swap) instructions and into every delegation's input.
abstract interface class PinnedNoteSync {
  /// The current note Markdown (null or empty: no note yet).
  void setPinnedNote(String? markdown);
}
