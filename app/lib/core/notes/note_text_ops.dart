import 'note_ops.dart';

/// Plain text edits of a note for voice control ("insert X after Y",
/// "replace X with Y", "delete the milk line"). Matching is
/// case-insensitive. Each throws [NoteEditException] when nothing matches.

int _find(String text, String needle) => text.toLowerCase().indexOf(needle.toLowerCase());

(int, int) _lineAt(String text, int i) {
  final s = text.lastIndexOf('\n', i == 0 ? 0 : i - 1) + 1;
  final e = text.indexOf('\n', i);
  return (s, e < 0 ? text.length : e);
}

/// Inserts [text] as new line(s) after the line containing [after], before
/// the line containing [before], or at the top of the note.
NoteEditResult insertNoteText(String current, String text, {String? after, String? before}) {
  final add = text.trim();
  if (add.isEmpty) throw NoteEditException('insert needs non-empty "text"');
  int at;
  if (after != null && after.trim().isNotEmpty) {
    final i = _find(current, after.trim());
    if (i < 0) throw NoteEditException('"$after" is not in the note');
    final (_, e) = _lineAt(current, i);
    at = e;
    final out = '${current.substring(0, at)}\n$add${current.substring(at)}';
    final res = at == current.length && !out.endsWith('\n') ? '$out\n' : out;
    return NoteEditResult(text: res, start: at + 1, end: at + 1 + add.length, summary: 'Inserted after "${after.trim()}"');
  }
  if (before != null && before.trim().isNotEmpty) {
    final i = _find(current, before.trim());
    if (i < 0) throw NoteEditException('"$before" is not in the note');
    final (s, _) = _lineAt(current, i);
    at = s;
  } else {
    at = 0;
  }
  final out = '${current.substring(0, at)}$add\n${current.substring(at)}';
  return NoteEditResult(
    text: out,
    start: at,
    end: at + add.length,
    summary: before == null ? 'Inserted at the top' : 'Inserted before "${before.trim()}"',
  );
}

/// Replaces the first (or every) occurrence of [find] with [text].
NoteEditResult replaceNoteText(String current, String find, String text, {bool all = false}) {
  final f = find.trim();
  if (f.isEmpty) throw NoteEditException('replace needs "find"');
  var i = _find(current, f);
  if (i < 0) throw NoteEditException('"$f" is not in the note');
  final first = i;
  var out = current;
  var n = 0;
  while (i >= 0) {
    out = out.replaceRange(i, i + f.length, text);
    n++;
    if (!all) break;
    final next = out.toLowerCase().indexOf(f.toLowerCase(), i + text.length);
    i = next;
  }
  return NoteEditResult(
    text: out,
    start: first,
    end: first + text.length,
    summary: n > 1 ? 'Replaced "$f" $n times' : 'Replaced "$f"',
  );
}

final _bullet = RegExp(r'^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+|#{1,6}\s+)?');

/// Deletes [find]: the whole line when [find] is (nearly) all of the line's
/// text (a list item, a heading), otherwise just the matched text.
NoteEditResult deleteNoteText(String current, String find) {
  final f = find.trim();
  if (f.isEmpty) throw NoteEditException('delete_text needs "find"');
  final i = _find(current, f);
  if (i < 0) throw NoteEditException('"$f" is not in the note');
  final (s, e) = _lineAt(current, i);
  final line = current.substring(s, e);
  final content = line.replaceFirst(_bullet, '').trim();
  final wholeLine = content.length <= f.length + 3;
  String out;
  if (wholeLine) {
    final end = e < current.length ? e + 1 : e;
    final start = end == e && s > 0 ? s - 1 : s; // last line: drop the newline before it
    out = current.replaceRange(start, end, '');
    return NoteEditResult(text: out, start: start, end: start, summary: 'Deleted the line "$content"');
  }
  out = current.replaceRange(i, i + f.length, '');
  // Collapse the gap left behind ("a  b" -> "a b", "milk \n" -> "milk\n").
  var at = i;
  if (at > 0 && out[at - 1] == ' ' && (at == out.length || out[at] == ' ' || out[at] == '\n')) {
    out = out.replaceRange(at - 1, at, '');
    at--;
  }
  return NoteEditResult(text: out, start: at, end: at, summary: 'Deleted "$f"');
}
