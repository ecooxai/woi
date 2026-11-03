/// How a compaction summary was applied to a live voice session.
enum ContextApplyMethod {
  /// Summary inserted as a system item and old items removed with
  /// `conversation.item.delete`.
  deletedItems,

  /// Session re-opened with the summary (plus recent turns) as initial context.
  reconnected,

  /// Nothing to do (e.g. not connected, or a newer summary replaced this one).
  skipped,
}

class ContextApplyResult {
  const ContextApplyResult(this.method, {this.removedItems = 0, this.detail});
  final ContextApplyMethod method;
  final int removedItems;
  final String? detail;

  @override
  String toString() => 'ContextApplyResult(${method.name}, removed: $removedItems${detail == null ? '' : ', $detail'})';
}

/// Optional [VoiceBackend] capability: replace old server-side conversation
/// items with a summary. Implementations must wait until no response is
/// active (between responses) and must not interrupt playback.
///
/// [recentTurns] is a text rendering of the turns the compaction kept, for
/// backends that rebuild the context from text (gpt-live reconnect); the
/// Realtime backend keeps those items on the server and ignores it.
abstract interface class LiveContextSync {
  Future<ContextApplyResult> applySummary(String summary, {String? recentTurns});
}
