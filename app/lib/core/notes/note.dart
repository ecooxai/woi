/// The Markdown note that belongs to one conversation.
class Note {
  Note({required this.conversationId, this.markdown = '', DateTime? updatedAt})
    : updatedAt = updatedAt ?? DateTime.now();

  final String conversationId;
  String markdown;
  DateTime updatedAt;

  bool get isEmpty => markdown.trim().isEmpty;

  Map<String, Object?> toJson() => {
    'version': 1,
    'conversationId': conversationId,
    'markdown': markdown,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Note.fromJson(Map<String, Object?> j) => Note(
    conversationId: j['conversationId'] as String? ?? '',
    markdown: j['markdown'] as String? ?? '',
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );
}

/// Words in [markdown], ignoring Markdown punctuation (#, -, [ ], `, *).
int noteWordCount(String markdown) {
  final stripped = markdown
      .replaceAll(RegExp(r'^\s*([-*+]|\d+[.)])\s+\[[ xX]\]\s*', multiLine: true), ' ')
      .replaceAll(RegExp(r'[#>*_`~\[\]()|]'), ' ');
  return RegExp(r"[\p{L}\p{N}][\p{L}\p{N}'’.\-/:]*", unicode: true).allMatches(stripped).length;
}

/// A title for a conversation that only has a note: its first heading or
/// first non-empty line.
String noteTitle(String markdown, {int max = 60}) {
  for (final raw in markdown.split('\n')) {
    final l = raw
        .replaceFirst(RegExp(r'^\s*#{1,6}\s*'), '')
        .replaceFirst(RegExp(r'^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s*)?'), '')
        .replaceAll(RegExp(r'[*_`]'), '')
        .trim();
    if (l.isEmpty) continue;
    return l.length <= max ? l : '${l.substring(0, max - 1)}…';
  }
  return '';
}
