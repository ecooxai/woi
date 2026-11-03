/// Pure edit operations behind the `update_note` tool. Each returns the new
/// text plus the range that changed (for the "AI edited" highlight).
library;

enum NoteEditMode {
  append('append'),
  replaceSection('replace_section'),
  replaceAll('replace_all'),
  checkItem('check_item');

  const NoteEditMode(this.wire);

  /// Name used in the tool schema.
  final String wire;

  static NoteEditMode? parse(String? s) {
    for (final m in values) {
      if (m.wire == s || m.name == s) return m;
    }
    return null;
  }
}

class NoteEditException implements Exception {
  NoteEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NoteEditResult {
  const NoteEditResult({required this.text, required this.start, required this.end, required this.summary});

  final String text;

  /// Changed range in [text] (UTF-16 offsets, end exclusive).
  final int start;
  final int end;

  /// Short description for the tool result and the undo chip.
  final String summary;
}

final _heading = RegExp(r'^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$');
final _checkLine = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\]\s*)(.*)$');

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[*_`#:\[\]().,!?]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Line start offsets of [text] (always includes 0).
List<int> _lineStarts(String text) {
  final out = [0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 10) out.add(i + 1);
  }
  return out;
}

bool _isListLine(String l) => RegExp(r'^\s*([-*+]|\d+[.)])\s+').hasMatch(l);

NoteEditResult applyNoteEdit(
  String current,
  NoteEditMode mode, {
  String text = '',
  String? heading,
  String? item,
  bool checked = true,
}) {
  switch (mode) {
    case NoteEditMode.append:
      return _append(current, text);
    case NoteEditMode.replaceAll:
      final t = text.endsWith('\n') || text.isEmpty ? text : '$text\n';
      return NoteEditResult(text: t, start: 0, end: t.length, summary: 'Rewrote the note');
    case NoteEditMode.replaceSection:
      final h = heading?.trim() ?? '';
      if (h.isEmpty) throw NoteEditException('replace_section needs "heading"');
      return _replaceSection(current, h, text);
    case NoteEditMode.checkItem:
      final it = item?.trim().isNotEmpty == true ? item!.trim() : text.trim();
      if (it.isEmpty) throw NoteEditException('check_item needs "item" (the checklist item text)');
      return _checkItem(current, it, checked);
  }
}

NoteEditResult _append(String current, String text) {
  final add = text.trimRight();
  if (add.trim().isEmpty) throw NoteEditException('append needs non-empty "text"');
  var base = current.trimRight();
  String sep;
  if (base.isEmpty) {
    sep = '';
  } else {
    final lastLine = base.substring(base.lastIndexOf('\n') + 1);
    final firstAdded = add.trimLeft().split('\n').first;
    // Keep list items together; separate other blocks with a blank line.
    sep = _isListLine(lastLine) && _isListLine(firstAdded) ? '\n' : '\n\n';
  }
  final body = add.replaceFirst(RegExp(r'^\n+'), '');
  final start = base.length + sep.length;
  final out = '$base$sep$body\n';
  return NoteEditResult(text: out, start: start, end: start + body.length, summary: 'Added to the note');
}

/// Section = heading line up to the next heading of the same or a higher
/// level. Missing headings are created at the end.
NoteEditResult _replaceSection(String current, String heading, String text) {
  final want = _norm(heading.replaceFirst(RegExp(r'^#+\s*'), ''));
  final lines = current.split('\n');
  final starts = _lineStarts(current);
  int? hLine;
  var level = 2;
  // Exact match first, then a heading that contains the wanted words.
  for (final exact in [true, false]) {
    for (var i = 0; i < lines.length && hLine == null; i++) {
      final m = _heading.firstMatch(lines[i]);
      if (m == null) continue;
      final got = _norm(m.group(2)!);
      if (exact ? got == want : (got.contains(want) || (got.isNotEmpty && want.contains(got)))) {
        hLine = i;
        level = m.group(1)!.length;
      }
    }
    if (hLine != null) break;
  }
  var body = text.trimRight();
  if (hLine == null) {
    final title = heading.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    final block = body.isEmpty ? '## $title' : '## $title\n\n${_stripLeadingHeading(body, title)}';
    final r = _append(current, block);
    return NoteEditResult(text: r.text, start: r.start, end: r.end, summary: 'Added section "$title"');
  }
  var end = lines.length;
  for (var i = hLine + 1; i < lines.length; i++) {
    final m = _heading.firstMatch(lines[i]);
    if (m != null && m.group(1)!.length <= level) {
      end = i;
      break;
    }
  }
  final title = _heading.firstMatch(lines[hLine])!.group(2)!;
  body = _stripLeadingHeading(body, title);
  final bodyStart = hLine + 1 < starts.length ? starts[hLine + 1] : current.length;
  final bodyEnd = end < starts.length ? starts[end] : current.length;
  final before = hLine + 1 < starts.length ? current.substring(0, bodyStart) : '$current\n';
  final after = current.substring(bodyEnd);
  final insert = body.isEmpty ? '\n' : '\n$body\n${after.isEmpty ? '' : '\n'}';
  final out = '$before$insert$after';
  final s = before.length + (body.isEmpty ? 0 : 1);
  return NoteEditResult(
    text: out.endsWith('\n') ? out : '$out\n',
    start: s,
    end: s + body.length,
    summary: 'Updated section "$title"',
  );
}

/// The model sometimes repeats the heading in the new body; drop it.
String _stripLeadingHeading(String body, String title) {
  final lines = body.split('\n');
  final m = lines.isEmpty ? null : _heading.firstMatch(lines.first);
  if (m != null && _norm(m.group(2)!) == _norm(title)) {
    return lines.skip(1).join('\n').replaceFirst(RegExp(r'^\n+'), '').trimRight();
  }
  return body;
}

NoteEditResult _checkItem(String current, String item, bool checked) {
  final want = _norm(item);
  final lines = current.split('\n');
  final starts = _lineStarts(current);
  int? hit;
  for (final pass in [0, 1, 2]) {
    for (var i = 0; i < lines.length && hit == null; i++) {
      final m = _checkLine.firstMatch(lines[i]);
      if (m == null) continue;
      final got = _norm(m.group(4)!);
      final ok = switch (pass) {
        0 => got == want,
        1 => got.contains(want) || want.contains(got),
        _ => _wordsOverlap(got, want),
      };
      if (ok) hit = i;
    }
    if (hit != null) break;
  }
  if (hit == null) throw NoteEditException('no checklist item matching "$item"');
  final m = _checkLine.firstMatch(lines[hit])!;
  lines[hit] = '${m.group(1)}${checked ? 'x' : ' '}${m.group(3)}${m.group(4)}';
  final out = lines.join('\n');
  final s = starts[hit];
  return NoteEditResult(
    text: out,
    start: s,
    end: s + lines[hit].length,
    summary: '${checked ? 'Checked off' : 'Unchecked'} "${m.group(4)!.trim()}"',
  );
}

bool _wordsOverlap(String a, String b) {
  final wa = a.split(' ').where((w) => w.length > 2).toSet();
  final wb = b.split(' ').where((w) => w.length > 2).toSet();
  if (wa.isEmpty || wb.isEmpty) return false;
  final common = wa.intersection(wb).length;
  return common / wb.length >= 0.6;
}

/// Toggles the checklist box on [line] (0-based) of [text]; null if that
/// line is not a checklist item. Used by clickable checkboxes.
String? toggleChecklistLine(String text, int line) {
  final lines = text.split('\n');
  if (line < 0 || line >= lines.length) return null;
  final m = _checkLine.firstMatch(lines[line]);
  if (m == null) return null;
  final on = m.group(2) != ' ';
  lines[line] = '${m.group(1)}${on ? ' ' : 'x'}${m.group(3)}${m.group(4)}';
  return lines.join('\n');
}
