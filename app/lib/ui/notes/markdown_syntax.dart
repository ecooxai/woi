import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/code_highlight.dart';

/// Editor text styles (the source view of the note).
abstract final class MdEditorStyle {
  static TextStyle base() => body(15.5, height: 1.62, color: WoiColors.text);
  static TextStyle heading(int level) => display(switch (level) {
    1 => 23.0,
    2 => 19.5,
    3 => 17.0,
    _ => 15.5,
  }, weight: FontWeight.w700).copyWith(height: 1.5, color: WoiColors.text);
  static TextStyle marker() => mono(14, color: WoiColors.violet.withValues(alpha: 0.85), height: 1.62);
  static TextStyle code() => mono(14, color: WoiColors.amber, height: 1.62);
}

/// A styled run of the source text.
class MdRun {
  const MdRun(this.start, this.end, this.style);
  final int start;
  final int end;
  final TextStyle style;
}

final _headingRe = RegExp(r'^(#{1,6})(\s+)(.*)$');
final _fenceRe = RegExp(r'^\s*(```|~~~)');
final _listRe = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\])?');
final _quoteRe = RegExp(r'^\s{0,3}>');
final _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _inlineRe = RegExp(
  r'(?<code>`[^`\n]+`)'
  r'|(?<link>\[[^\]\n]+\]\([^)\s]+\))'
  r'|(?<bold>\*\*[^*\n]+?\*\*|__[^_\n]+?__)'
  r'|(?<strike>~~[^~\n]+?~~)'
  r'|(?<ital>(?<![\w*])\*[^*\s][^*\n]*?\*(?![\w*])|(?<![\w_])_[^_\s][^_\n]*?_(?![\w_]))'
  r'|(?<url>https?://[^\s<>()]+)',
);

/// Styled runs covering [text] (every character exactly once, in order).
/// Markdown markers stay visible (it is a source editor) but are dimmed;
/// content gets its rendered emphasis.
///
/// The whole note is laid out again on every keystroke, and each style run
/// (above all a font switch) adds shaping work: adjacent runs with the same
/// style are merged (a line and its newline are one run), and list / quote
/// markers keep the body font, only coloured (checkboxes, fences and code
/// stay monospaced). That made a 4,400-character note ~25 % cheaper to lay
/// out.
List<MdRun> highlightMarkdown(String text) {
  final runs = <MdRun>[];
  final base = MdEditorStyle.base();
  var inFence = false;
  var lineStart = 0;
  final lines = text.split('\n');
  void push(int a, int b, TextStyle st) => _pushMerged(runs, a, b, st);

  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final s = lineStart;
    final e = s + line.length;
    final hl = _highlightLine(line, inFence);
    for (final r in hl.runs) {
      push(s + r.start, s + r.end, r.style);
    }
    inFence = hl.fenceOut;
    lineStart = e + 1;
    if (li < lines.length - 1) push(e, e + 1, base);
  }
  return runs;
}

/// Appends a run, merged into the previous one when it continues it with the
/// same style.
void _pushMerged(List<MdRun> runs, int a, int b, TextStyle st) {
  if (b <= a) return;
  if (runs.isNotEmpty) {
    final last = runs.last;
    if (last.end == a && (identical(last.style, st) || last.style == st)) {
      runs[runs.length - 1] = MdRun(last.start, b, st);
      return;
    }
  }
  runs.add(MdRun(a, b, st));
}

/// Highlight of one line: runs relative to the line start (without the
/// newline) and the fenced-code state after the line. A line's result depends
/// only on its text and the incoming fence state, which is what makes the
/// editor's per-line cache exact.
final class _LineHl {
  const _LineHl(this.runs, this.fenceOut);
  final List<MdRun> runs;
  final bool fenceOut;
}

_LineHl _highlightLine(String line, bool inFence) {
  final runs = <MdRun>[];
  final base = MdEditorStyle.base();
  void add(int a, int b, TextStyle st) => _pushMerged(runs, a, b, st);

  if (_fenceRe.hasMatch(line)) {
    add(0, line.length, MdEditorStyle.code().copyWith(color: WoiColors.textFaint));
    return _LineHl(runs, !inFence);
  } else if (inFence) {
    add(0, line.length, MdEditorStyle.code().copyWith(color: CodeColors.plain));
  } else if (_headingRe.firstMatch(line) case final h?) {
    final level = h.group(1)!.length;
    final hs = MdEditorStyle.heading(level);
    final markLen = h.group(1)!.length + h.group(2)!.length;
    add(0, markLen, hs.copyWith(color: WoiColors.cyan.withValues(alpha: 0.55)));
    _inline(line, markLen, line.length, hs, add);
  } else if (_ruleRe.hasMatch(line)) {
    add(0, line.length, MdEditorStyle.marker().copyWith(color: WoiColors.textFaint));
  } else if (_listRe.firstMatch(line) case final m?) {
    final box = m.group(4);
    final checked = box != null && box != '[ ]';
    final markEnd = m.end;
    add(0, m.group(1)!.length, base);
    final bulletEnd = m.group(1)!.length + m.group(2)!.length + m.group(3)!.length;
    add(m.group(1)!.length, bulletEnd, base.copyWith(color: WoiColors.cyan));
    if (box != null) {
      add(
        bulletEnd,
        markEnd,
        MdEditorStyle.marker().copyWith(
          color: checked ? WoiColors.mint : WoiColors.violet,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    final content = checked
        ? base.copyWith(
            color: WoiColors.textFaint,
            decoration: TextDecoration.lineThrough,
            decorationColor: WoiColors.textFaint,
          )
        : base;
    _inline(line, markEnd, line.length, content, add);
  } else if (_quoteRe.hasMatch(line)) {
    final gt = line.indexOf('>') + 1;
    add(0, gt, base.copyWith(color: WoiColors.violet));
    _inline(line, gt, line.length, base.copyWith(color: WoiColors.textDim, fontStyle: FontStyle.italic), add);
  } else {
    _inline(line, 0, line.length, base, add);
  }
  return _LineHl(runs, inFence);
}

/// One highlighted source line as the editor shows it: runs relative to the
/// line start (including its trailing newline, if any) and the TextSpan built
/// from them, reused as the identical instance while the line is unchanged.
final class _LineEntry {
  _LineEntry(this.runs, this.fenceOut, this.span);
  final List<MdRun> runs;
  final bool fenceOut;
  final InlineSpan span;
}

_LineEntry _buildLineEntry(String line, bool inFence, bool newline) {
  final hl = _highlightLine(line, inFence);
  final runs = [...hl.runs];
  if (newline) _pushMerged(runs, line.length, line.length + 1, MdEditorStyle.base());
  final full = newline ? '$line\n' : line;
  final spans = [for (final r in runs) TextSpan(text: full.substring(r.start, r.end), style: r.style)];
  final InlineSpan span = spans.length == 1 ? spans.first : TextSpan(children: spans);
  return _LineEntry(runs, hl.fenceOut, span);
}

void _inline(String line, int from, int to, TextStyle st, void Function(int, int, TextStyle) add) {
  var pos = from;
  final dim = st.copyWith(color: WoiColors.textFaint);
  for (final m in _inlineRe.allMatches(line.substring(from, to))) {
    final a = from + m.start, b = from + m.end;
    if (a > pos) add(pos, a, st);
    if (m.namedGroup('code') != null) {
      add(a, a + 1, dim);
      add(a + 1, b - 1, MdEditorStyle.code().copyWith(backgroundColor: WoiColors.amber.withValues(alpha: 0.08)));
      add(b - 1, b, dim);
    } else if (m.namedGroup('link') != null) {
      final close = line.indexOf('](', a);
      add(a, a + 1, dim);
      add(a + 1, close, st.copyWith(color: WoiColors.cyan));
      add(close, b, mono(13, color: WoiColors.textFaint, height: st.height));
    } else if (m.namedGroup('bold') != null) {
      add(a, a + 2, dim);
      add(a + 2, b - 2, weighted(st, FontWeight.w700));
      add(b - 2, b, dim);
    } else if (m.namedGroup('strike') != null) {
      add(a, a + 2, dim);
      add(a + 2, b - 2, st.copyWith(decoration: TextDecoration.lineThrough, color: WoiColors.textDim));
      add(b - 2, b, dim);
    } else if (m.namedGroup('ital') != null) {
      add(a, a + 1, dim);
      add(a + 1, b - 1, st.copyWith(fontStyle: FontStyle.italic));
      add(b - 1, b, dim);
    } else {
      add(
        a,
        b,
        st.copyWith(
          color: WoiColors.cyan,
          decoration: TextDecoration.underline,
          decorationColor: WoiColors.cyan.withValues(alpha: 0.4),
        ),
      );
    }
    pos = b;
  }
  if (to > pos) add(pos, to, st);
}

/// Text controller of the note editor: live Markdown highlighting plus a
/// tint over the latest AI edit.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  TextRange? _ai;

  /// Character range of the latest AI edit (null: none).
  TextRange? get aiRange => _ai;
  set aiRange(TextRange? r) {
    if (r == _ai) return;
    _ai = r;
    notifyListeners();
  }

  /// Glow strength of the AI tint (animated by the editor).
  double aiGlow = 1;

  void setGlow(double g) {
    if (g == aiGlow) return;
    aiGlow = g;
    notifyListeners();
  }

  /// Per-line highlight cache, keyed by (line text, fence state before the
  /// line, has trailing newline). A keystroke re-highlights only the lines
  /// whose text or incoming fence state changed (the edited line, plus the
  /// following lines up to where the fence state matches again when an edit
  /// opens / closes a code fence); every other line reuses its TextSpan
  /// instance. Entries not used by the current text are dropped.
  Map<(String, bool, bool), _LineEntry> _lines = {};

  /// Lines re-highlighted by the last [buildTextSpan] that changed the text
  /// (tests / perf logging).
  @visibleForTesting
  int lastHighlightedLines = 0;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    final ai = _ai;
    final aiOn = ai != null && ai.isValid && !ai.isCollapsed && ai.end <= t.length;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : null;
    // Same inputs: the same span object, so RenderEditable skips relayout
    // (EditableText rebuilds on focus / selection / caret changes too).
    final key = (t, aiOn ? ai : null, aiOn ? aiGlow : null, composing, style);
    final cached = _spanCache;
    if (cached != null && _spanKey == key) return cached;
    final children = <InlineSpan>[];
    final lines = t.split('\n');
    final old = _lines;
    final next = <(String, bool, bool), _LineEntry>{};
    var fresh = 0;
    var inFence = false;
    var offset = 0;
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final nl = li < lines.length - 1;
      final k = (line, inFence, nl);
      var entry = next[k] ?? old[k];
      if (entry == null) {
        entry = _buildLineEntry(line, inFence, nl);
        fresh++;
      }
      next[k] = entry;
      final end = offset + line.length + (nl ? 1 : 0);
      final hitsAi = aiOn && ai.start < end && ai.end > offset;
      final hitsComposing = composing != null && composing.start < end && composing.end > offset;
      if (hitsAi || hitsComposing) {
        for (final r in entry.runs) {
          _addSplit(children, t, offset + r.start, offset + r.end, r.style, aiOn ? ai : null, composing);
        }
      } else {
        children.add(entry.span);
      }
      inFence = entry.fenceOut;
      offset = end;
    }
    _lines = next;
    lastHighlightedLines = fresh;
    _spanKey = key;
    return _spanCache = TextSpan(style: style ?? MdEditorStyle.base(), children: children);
  }

  /// Adds the run [start, end) split at the AI range and composing range
  /// boundaries, with the AI tint / composing underline applied.
  void _addSplit(
    List<InlineSpan> children,
    String t,
    int start,
    int end,
    TextStyle style,
    TextRange? ai,
    TextRange? composing,
  ) {
    final cuts = <int>{start, end};
    if (ai != null) {
      if (ai.start > start && ai.start < end) cuts.add(ai.start);
      if (ai.end > start && ai.end < end) cuts.add(ai.end);
    }
    if (composing != null) {
      if (composing.start > start && composing.start < end) cuts.add(composing.start);
      if (composing.end > start && composing.end < end) cuts.add(composing.end);
    }
    final sorted = cuts.toList()..sort();
    for (var k = 0; k < sorted.length - 1; k++) {
      final a = sorted[k], b = sorted[k + 1];
      var st = style;
      if (ai != null && a >= ai.start && b <= ai.end) {
        st = st.copyWith(backgroundColor: WoiColors.violet.withValues(alpha: 0.20 * aiGlow.clamp(0.0, 1.0)));
      }
      if (composing != null && a >= composing.start && b <= composing.end) {
        st = st.copyWith(decoration: TextDecoration.underline);
      }
      children.add(TextSpan(text: t.substring(a, b), style: st));
    }
  }

  Object? _spanKey;
  TextSpan? _spanCache;
}

/// If [offset] is on the `[ ]` / `[x]` box of a checklist line, the 0-based
/// line index; otherwise null.
int? checkboxLineAt(String text, int offset) {
  if (offset < 0 || offset > text.length) return null;
  final lineStart = text.lastIndexOf('\n', offset == 0 ? 0 : offset - 1) + 1;
  final lineEndRaw = text.indexOf('\n', lineStart);
  final lineEnd = lineEndRaw < 0 ? text.length : lineEndRaw;
  final line = text.substring(lineStart, lineEnd);
  final m = _listRe.firstMatch(line);
  if (m == null || m.group(4) == null) return null;
  final boxStart = lineStart + m.start + m.group(1)!.length + m.group(2)!.length + m.group(3)!.length;
  final boxEnd = boxStart + 3;
  if (offset < boxStart || offset > boxEnd) return null;
  return '\n'.allMatches(text.substring(0, lineStart)).length;
}
