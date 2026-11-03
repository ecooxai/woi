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
List<MdRun> highlightMarkdown(String text) {
  final runs = <MdRun>[];
  final base = MdEditorStyle.base();
  var inFence = false;
  var lineStart = 0;
  final lines = text.split('\n');
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final s = lineStart;
    final e = s + line.length;
    void add(int a, int b, TextStyle st) {
      if (b > a) runs.add(MdRun(s + a, s + b, st));
    }

    if (_fenceRe.hasMatch(line)) {
      add(0, line.length, MdEditorStyle.code().copyWith(color: WoiColors.textFaint));
      inFence = !inFence;
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
      add(m.group(1)!.length, bulletEnd, MdEditorStyle.marker().copyWith(color: WoiColors.cyan));
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
      add(0, gt, MdEditorStyle.marker().copyWith(color: WoiColors.violet));
      _inline(line, gt, line.length, base.copyWith(color: WoiColors.textDim, fontStyle: FontStyle.italic), add);
    } else {
      _inline(line, 0, line.length, base, add);
    }
    lineStart = e + 1;
    if (li < lines.length - 1) runs.add(MdRun(e, e + 1, base));
  }
  return runs;
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

  String? _cacheText;
  List<MdRun> _cacheRuns = const [];

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    if (t != _cacheText) {
      _cacheText = t;
      _cacheRuns = highlightMarkdown(t);
    }
    final ai = _ai;
    final aiOn = ai != null && ai.isValid && !ai.isCollapsed && ai.end <= t.length;
    final composing = withComposing && value.isComposingRangeValid ? value.composing : null;
    final children = <InlineSpan>[];
    for (final r in _cacheRuns) {
      // Split each run at the AI range and composing range boundaries.
      final cuts = <int>{r.start, r.end};
      if (aiOn) {
        if (ai.start > r.start && ai.start < r.end) cuts.add(ai.start);
        if (ai.end > r.start && ai.end < r.end) cuts.add(ai.end);
      }
      if (composing != null) {
        if (composing.start > r.start && composing.start < r.end) cuts.add(composing.start);
        if (composing.end > r.start && composing.end < r.end) cuts.add(composing.end);
      }
      final sorted = cuts.toList()..sort();
      for (var k = 0; k < sorted.length - 1; k++) {
        final a = sorted[k], b = sorted[k + 1];
        var st = r.style;
        if (aiOn && a >= ai.start && b <= ai.end) {
          st = st.copyWith(backgroundColor: WoiColors.violet.withValues(alpha: 0.20 * aiGlow.clamp(0.0, 1.0)));
        }
        if (composing != null && a >= composing.start && b <= composing.end) {
          st = st.copyWith(decoration: TextDecoration.underline);
        }
        children.add(TextSpan(text: t.substring(a, b), style: st));
      }
    }
    return TextSpan(style: style ?? MdEditorStyle.base(), children: children);
  }
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
