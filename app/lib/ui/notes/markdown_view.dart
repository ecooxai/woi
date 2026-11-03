import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/code_highlight.dart';

// ------------------------------------------------------------------ parser

enum MdBlockKind { heading, paragraph, listItem, code, quote, rule, table, blank }

/// One rendered block of Markdown. [line] is the 0-based source line where
/// it starts (used to toggle checklist items in the source).
class MdBlock {
  MdBlock(this.kind, this.line, {this.text = '', this.level = 0, this.ordered, this.checked, this.lang, this.rows});
  final MdBlockKind kind;
  final int line;
  final String text;

  /// Heading level (1-6) or list indent depth (0-based).
  final int level;

  /// List marker ("1." / null for bullets).
  final String? ordered;

  /// Checklist state (null: not a checklist item).
  final bool? checked;
  final String? lang;
  final List<List<String>>? rows;
}

final _heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
final _fence = RegExp(r'^\s*(```|~~~)\s*([\w+#.-]*)\s*$');
final _list = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(?:\[([ xX])\]\s+)?(.*)$');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _quote = RegExp(r'^\s{0,3}>\s?(.*)$');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

List<String> _cells(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return [for (final c in t.split('|')) c.trim()];
}

/// Splits Markdown into blocks (a pragmatic CommonMark subset: headings,
/// paragraphs, nested bullet/ordered/check lists, fenced code, quotes,
/// rules and pipe tables).
List<MdBlock> parseMarkdown(String src) {
  final lines = src.split('\n');
  final out = <MdBlock>[];
  var i = 0;
  while (i < lines.length) {
    final l = lines[i];
    if (l.trim().isEmpty) {
      if (out.isNotEmpty && out.last.kind != MdBlockKind.blank) out.add(MdBlock(MdBlockKind.blank, i));
      i++;
      continue;
    }
    final fence = _fence.firstMatch(l);
    if (fence != null) {
      final start = i;
      final buf = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(fence.group(1)!)) {
        buf.add(lines[i]);
        i++;
      }
      i++; // closing fence
      out.add(MdBlock(MdBlockKind.code, start, text: buf.join('\n'), lang: fence.group(2)));
      continue;
    }
    final h = _heading.firstMatch(l);
    if (h != null) {
      out.add(MdBlock(MdBlockKind.heading, i, text: h.group(2)!, level: h.group(1)!.length));
      i++;
      continue;
    }
    if (_rule.hasMatch(l)) {
      out.add(MdBlock(MdBlockKind.rule, i));
      i++;
      continue;
    }
    final li = _list.firstMatch(l);
    if (li != null) {
      final indent = li.group(1)!.replaceAll('\t', '    ').length;
      final marker = li.group(2)!;
      final box = li.group(3);
      out.add(
        MdBlock(
          MdBlockKind.listItem,
          i,
          text: li.group(4)!,
          level: indent ~/ 2,
          ordered: RegExp(r'^\d').hasMatch(marker) ? marker : null,
          checked: box == null ? null : box != ' ',
        ),
      );
      i++;
      continue;
    }
    final q = _quote.firstMatch(l);
    if (q != null) {
      final start = i;
      final buf = <String>[];
      while (i < lines.length) {
        final m = _quote.firstMatch(lines[i]);
        if (m == null) break;
        buf.add(m.group(1)!);
        i++;
      }
      out.add(MdBlock(MdBlockKind.quote, start, text: buf.join('\n')));
      continue;
    }
    if (l.contains('|') && i + 1 < lines.length && _tableSep.hasMatch(lines[i + 1])) {
      final start = i;
      final rows = <List<String>>[_cells(l)];
      i += 2;
      while (i < lines.length && lines[i].contains('|') && lines[i].trim().isNotEmpty) {
        rows.add(_cells(lines[i]));
        i++;
      }
      out.add(MdBlock(MdBlockKind.table, start, rows: rows));
      continue;
    }
    // Paragraph: until a blank line or another block starts.
    final start = i;
    final buf = <String>[l.trim()];
    i++;
    while (i < lines.length) {
      final n = lines[i];
      if (n.trim().isEmpty ||
          _heading.hasMatch(n) ||
          _fence.hasMatch(n) ||
          _list.hasMatch(n) ||
          _quote.hasMatch(n) ||
          _rule.hasMatch(n)) {
        break;
      }
      buf.add(n.trim());
      i++;
    }
    out.add(MdBlock(MdBlockKind.paragraph, start, text: buf.join(' ')));
  }
  while (out.isNotEmpty && out.last.kind == MdBlockKind.blank) {
    out.removeLast();
  }
  return out;
}

// ------------------------------------------------------------------ inline

final _inline = RegExp(
  r'(?<code>`[^`\n]+`)'
  r'|(?<link>\[(?<lt>[^\]\n]+)\]\((?<lu>[^)\s]+)\))'
  r'|(?<bold>\*\*(?<bt>[^*\n]+?)\*\*|__(?<bt2>[^_\n]+?)__)'
  r'|(?<strike>~~(?<st>[^~\n]+?)~~)'
  r'|(?<ital>(?<![\w*])\*(?<it>[^*\s][^*\n]*?)\*(?![\w*])|(?<![\w_])_(?<it2>[^_\s][^_\n]*?)_(?![\w_]))'
  r'|(?<url>https?://[^\s<>()]+[^\s<>().,;:!?"])'
  r'|(?<path>(?<![\w/~.])(?:~|/)(?:[\w.@+-]+/)*[\w@+-]+\.[A-Za-z0-9]{1,6}\b)',
);

/// Inline spans for one block of text: `code`, **bold**, *italic*,
/// ~~strike~~, [links](url), bare URLs and absolute file paths (clickable).
List<InlineSpan> parseInline(
  String text,
  TextStyle base, {
  void Function(String target)? onLink,
  List<GestureRecognizer>? recognizers,
}) {
  final spans = <InlineSpan>[];
  var pos = 0;
  TapGestureRecognizer? tap(String target) {
    if (onLink == null) return null;
    final r = TapGestureRecognizer()..onTap = () => onLink(target);
    recognizers?.add(r);
    return r;
  }

  final linkStyle = base.copyWith(
    color: WoiColors.cyan,
    decoration: TextDecoration.underline,
    decorationColor: WoiColors.cyan.withValues(alpha: 0.5),
  );
  for (final m in _inline.allMatches(text)) {
    if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start), style: base));
    if (m.namedGroup('code') != null) {
      final c = m.namedGroup('code')!;
      spans.add(
        TextSpan(
          text: ' ${c.substring(1, c.length - 1)} ',
          style: mono(
            (base.fontSize ?? 14) * 0.9,
            color: WoiColors.amber,
          ).copyWith(backgroundColor: WoiColors.amber.withValues(alpha: 0.10)),
        ),
      );
    } else if (m.namedGroup('link') != null) {
      final url = m.namedGroup('lu')!;
      spans.add(
        TextSpan(
          text: m.namedGroup('lt'),
          style: linkStyle,
          recognizer: tap(url),
          mouseCursor: SystemMouseCursors.click,
        ),
      );
    } else if (m.namedGroup('bold') != null) {
      final t = m.namedGroup('bt') ?? m.namedGroup('bt2')!;
      spans.addAll(parseInline(t, weighted(base, FontWeight.w700), onLink: onLink, recognizers: recognizers));
    } else if (m.namedGroup('strike') != null) {
      spans.add(
        TextSpan(
          text: m.namedGroup('st'),
          style: base.copyWith(decoration: TextDecoration.lineThrough, color: WoiColors.textFaint),
        ),
      );
    } else if (m.namedGroup('ital') != null) {
      final t = m.namedGroup('it') ?? m.namedGroup('it2')!;
      spans.addAll(
        parseInline(
          t,
          base.copyWith(fontStyle: FontStyle.italic),
          onLink: onLink,
          recognizers: recognizers,
        ),
      );
    } else {
      final target = m.group(0)!;
      final isPath = m.namedGroup('path') != null;
      spans.add(
        TextSpan(
          text: target,
          style: isPath
              ? mono(
                  (base.fontSize ?? 14) * 0.92,
                  color: WoiColors.cyan,
                ).copyWith(decoration: TextDecoration.underline, decorationColor: WoiColors.cyan.withValues(alpha: 0.4))
              : linkStyle,
          recognizer: tap(target),
          mouseCursor: SystemMouseCursors.click,
        ),
      );
    }
    pos = m.end;
  }
  if (pos < text.length) spans.add(TextSpan(text: text.substring(pos), style: base));
  return spans;
}

// -------------------------------------------------------------------- view

/// Rendered Markdown (preview pane of the note editor and `.md` files in
/// the media viewer). Checklist boxes are clickable when [onToggleLine] is
/// set; links/paths call [onLink].
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.markdown,
    this.onToggleLine,
    this.onLink,
    this.padding = const EdgeInsets.fromLTRB(28, 22, 28, 40),
    this.highlightLines,
    this.scrollController,
    this.emptyHint,
  });

  final String markdown;
  final void Function(int line)? onToggleLine;
  final void Function(String target)? onLink;
  final EdgeInsets padding;

  /// Source lines to tint (the latest AI edit).
  final (int, int)? highlightLines;
  final ScrollController? scrollController;
  final Widget? emptyHint;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final List<GestureRecognizer> _recognizers = [];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  List<InlineSpan> _spans(String t, TextStyle s) => parseInline(t, s, onLink: widget.onLink, recognizers: _recognizers);

  @override
  Widget build(BuildContext context) {
    _clear();
    final blocks = parseMarkdown(widget.markdown);
    if (blocks.isEmpty && widget.emptyHint != null) return widget.emptyHint!;
    final hl = widget.highlightLines;
    return SelectionArea(
      child: ListView.builder(
        controller: widget.scrollController,
        padding: widget.padding,
        itemCount: blocks.length,
        itemBuilder: (context, i) {
          final b = blocks[i];
          final w = _block(b, i == 0);
          final lit = hl != null && b.kind != MdBlockKind.blank && b.line >= hl.$1 && b.line <= hl.$2;
          if (!lit) return w;
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: WoiColors.violet.withValues(alpha: 0.10),
              border: const Border(left: BorderSide(color: WoiColors.violet, width: 2)),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.only(left: 8),
            child: w,
          );
        },
      ),
    );
  }

  Widget _block(MdBlock b, bool first) {
    switch (b.kind) {
      case MdBlockKind.blank:
        return const SizedBox(height: 10);
      case MdBlockKind.heading:
        final size = switch (b.level) {
          1 => 28.0,
          2 => 21.0,
          3 => 17.5,
          _ => 15.5,
        };
        final style = display(size, weight: b.level <= 2 ? FontWeight.w700 : FontWeight.w600);
        return Padding(
          padding: EdgeInsets.only(top: first ? 0 : (b.level <= 2 ? 18 : 12), bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (b.level == 1)
                ShaderMask(
                  shaderCallback: (r) =>
                      const LinearGradient(colors: [WoiColors.text, WoiColors.cyan, WoiColors.violet]).createShader(r),
                  child: Text.rich(TextSpan(children: _spans(b.text, style.copyWith(color: Colors.white)))),
                )
              else
                Text.rich(TextSpan(children: _spans(b.text, style))),
              if (b.level <= 2)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        (b.level == 1 ? WoiColors.cyan : WoiColors.violet).withValues(alpha: 0.45),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      case MdBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text.rich(TextSpan(children: _spans(b.text, body(15, height: 1.6)))),
        );
      case MdBlockKind.listItem:
        return _listItem(b);
      case MdBlockKind.quote:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          decoration: BoxDecoration(
            color: WoiColors.violet.withValues(alpha: 0.06),
            border: Border(left: BorderSide(color: WoiColors.violet.withValues(alpha: 0.7), width: 3)),
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
          ),
          child: Text.rich(
            TextSpan(
              children: _spans(
                b.text,
                body(14.5, color: WoiColors.textDim, height: 1.55).copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ),
        );
      case MdBlockKind.rule:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          height: 1,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.transparent, WoiColors.strokeStrong, Colors.transparent]),
          ),
        );
      case MdBlockKind.code:
        return _code(b);
      case MdBlockKind.table:
        return _table(b);
    }
  }

  Widget _listItem(MdBlock b) {
    final checked = b.checked;
    final textStyle = body(
      15,
      height: 1.55,
      color: checked == true ? WoiColors.textFaint : WoiColors.text,
    ).copyWith(decoration: checked == true ? TextDecoration.lineThrough : null, decorationColor: WoiColors.textFaint);
    Widget marker;
    if (checked != null) {
      final canToggle = widget.onToggleLine != null;
      marker = MouseRegion(
        cursor: canToggle ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          key: ValueKey('md-check-${b.line}'),
          behavior: HitTestBehavior.opaque,
          onTap: canToggle ? () => widget.onToggleLine!(b.line) : null,
          child: Padding(
            padding: const EdgeInsets.only(top: 3, right: 10, left: 2),
            child: AnimatedContainer(
              duration: WoiMotion.fast,
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                gradient: checked ? const LinearGradient(colors: [WoiColors.mint, WoiColors.cyan]) : null,
                border: Border.all(color: checked ? Colors.transparent : WoiColors.strokeStrong, width: 1.5),
                boxShadow: checked ? [BoxShadow(color: WoiColors.mint.withValues(alpha: 0.35), blurRadius: 10)] : null,
              ),
              child: checked ? const Icon(Icons.check_rounded, size: 14, color: WoiColors.bg0) : null,
            ),
          ),
        ),
      );
    } else if (b.ordered != null) {
      marker = SizedBox(
        width: 26,
        child: Text(
          b.ordered!,
          style: display(14, color: WoiColors.cyan).copyWith(fontFeatures: kTabular),
        ),
      );
    } else {
      final colors = [WoiColors.cyan, WoiColors.violet, WoiColors.magenta];
      marker = Padding(
        padding: const EdgeInsets.only(top: 9, right: 12, left: 6),
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: b.level == 0 ? BoxShape.circle : BoxShape.rectangle,
            color: colors[b.level % 3],
            boxShadow: [BoxShadow(color: colors[b.level % 3].withValues(alpha: 0.6), blurRadius: 6)],
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: 22.0 * b.level, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          marker,
          Expanded(child: Text.rich(TextSpan(children: _spans(b.text, textStyle)))),
        ],
      ),
    );
  }

  Widget _code(MdBlock b) {
    final lang = langForPath('x.${(b.lang ?? '').isEmpty ? 'txt' : b.lang}');
    final lines = b.text.split('\n');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: WoiColors.bg0.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if ((b.lang ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(b.lang!.toUpperCase(), style: eyebrow(size: 10, color: WoiColors.textFaint)),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < lines.length; i++) ...[
                    ...highlightLine(lines[i], lang, size: 13),
                    if (i < lines.length - 1) const TextSpan(text: '\n'),
                  ],
                ],
                style: mono(13, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(MdBlock b) {
    final rows = b.rows!;
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WoiRadii.sm),
        border: Border.all(color: WoiColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: const TableBorder(
            horizontalInside: BorderSide(color: WoiColors.stroke),
            verticalInside: BorderSide(color: WoiColors.stroke),
          ),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: BoxDecoration(color: r == 0 ? WoiColors.glassStrong : null),
                children: [
                  for (var c = 0; c < cols; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      child: Text.rich(
                        TextSpan(
                          children: _spans(
                            c < rows[r].length ? rows[r][c] : '',
                            r == 0 ? body(13.5, weight: FontWeight.w700) : body(13.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
