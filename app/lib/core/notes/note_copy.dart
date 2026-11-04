/// What "Copy" copies from a note: the whole note, or the line, paragraph
/// or H1 section around the cursor.
enum NoteCopyScope {
  note('note'),
  line('line'),
  paragraph('paragraph'),
  section('section');

  const NoteCopyScope(this.label);
  final String label;

  /// "this paragraph", "the line", "heading section", "everything"...
  static NoteCopyScope? parse(String? s) {
    final n = (s ?? '').trim().toLowerCase();
    if (n.isEmpty || RegExp(r'note|all|whole|every|document|file').hasMatch(n)) return NoteCopyScope.note;
    if (n.contains('para') || n.contains('block')) return NoteCopyScope.paragraph;
    if (RegExp(r'section|head|h1|chapter|title').hasMatch(n)) return NoteCopyScope.section;
    if (n.contains('line') || n.contains('row')) return NoteCopyScope.line;
    return null;
  }
}

(int, int) _lineAt(String t, int at) {
  final s = at <= 0 ? 0 : t.lastIndexOf('\n', at - 1) + 1;
  var e = t.indexOf('\n', at);
  if (e < 0) e = t.length;
  return (s, e);
}

/// Start offset of every line.
List<int> _lineStarts(String t) {
  final out = <int>[0];
  for (var i = t.indexOf('\n'); i >= 0; i = t.indexOf('\n', i + 1)) {
    out.add(i + 1);
  }
  return out;
}

String _line(String t, List<int> starts, int i) {
  final e = i + 1 < starts.length ? starts[i + 1] - 1 : t.length;
  return t.substring(starts[i], e);
}

int _lineIndex(List<int> starts, int at) {
  var lo = 0, hi = starts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (starts[mid] <= at) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

final _fence = RegExp(r'^\s{0,3}(```|~~~)');
final _h1 = RegExp(r'^\s{0,3}#(\s|$)');

/// The text [scope] covers at [cursor] (a text offset; clamped). Lines are
/// returned without their trailing newline; paragraphs and sections are
/// trimmed of surrounding blank lines. Empty when there is nothing there.
///
/// - line: the line holding the cursor.
/// - paragraph: the lines between the blank lines around the cursor. On a
///   blank line, the paragraph just above (else the one below).
/// - section: from the H1 (`# Title`) at or above the cursor to the line
///   before the next H1; before the first H1, from the top. `#` lines inside
///   fenced code blocks are not headings.
String noteCopyText(String text, int cursor, NoteCopyScope scope) {
  final at = cursor.clamp(0, text.length);
  switch (scope) {
    case NoteCopyScope.note:
      return text;
    case NoteCopyScope.line:
      final (s, e) = _lineAt(text, at);
      return text.substring(s, e);
    case NoteCopyScope.paragraph:
      final starts = _lineStarts(text);
      bool blank(int i) => _line(text, starts, i).trim().isEmpty;
      var i = _lineIndex(starts, at);
      if (blank(i)) {
        var up = i;
        while (up >= 0 && blank(up)) {
          up--;
        }
        if (up >= 0) {
          i = up;
        } else {
          var down = i;
          while (down < starts.length && blank(down)) {
            down++;
          }
          if (down >= starts.length) return '';
          i = down;
        }
      }
      var a = i, b = i;
      while (a > 0 && !blank(a - 1)) {
        a--;
      }
      while (b + 1 < starts.length && !blank(b + 1)) {
        b++;
      }
      final end = b + 1 < starts.length ? starts[b + 1] - 1 : text.length;
      return text.substring(starts[a], end);
    case NoteCopyScope.section:
      final starts = _lineStarts(text);
      final cur = _lineIndex(starts, at);
      // H1 lines outside code fences.
      final heads = <int>[];
      var inFence = false;
      for (var i = 0; i < starts.length; i++) {
        final l = _line(text, starts, i);
        if (_fence.hasMatch(l)) {
          inFence = !inFence;
        } else if (!inFence && _h1.hasMatch(l)) {
          heads.add(i);
        }
      }
      var a = 0;
      for (final h in heads) {
        if (h <= cur) a = h;
      }
      final next = heads.where((h) => h > cur).firstOrNull;
      final end = next == null ? text.length : starts[next] - 1;
      return text.substring(starts[a], end.clamp(starts[a], text.length)).replaceFirst(RegExp(r'\s+$'), '');
  }
}

/// Short description of what was copied, for the "Copied" confirmation.
String noteCopyLabel(NoteCopyScope scope, String copied) {
  final lines = copied.isEmpty ? 0 : '\n'.allMatches(copied).length + 1;
  final what = switch (scope) {
    NoteCopyScope.note => 'note',
    NoteCopyScope.line => 'line',
    NoteCopyScope.paragraph => 'paragraph',
    NoteCopyScope.section => 'section',
  };
  return scope == NoteCopyScope.line ? 'Copied $what' : 'Copied $what ($lines ${lines == 1 ? 'line' : 'lines'})';
}
