import 'package:flutter/material.dart';

import '../../core/util/diff.dart';
import '../theme.dart';
import 'code_highlight.dart';

enum DiffLayout { unified, split }

/// One row of a side-by-side diff; null sides are blank. A row with both
/// sides null is a collapsed region.
class SplitRow {
  const SplitRow(this.left, this.right);
  final DiffLine? left;
  final DiffLine? right;
  bool get isGap => left == null && right == null;
}

/// Pairs the deletions and insertions of each change block side by side.
List<SplitRow> splitRows(List<DiffLine?> rows) {
  final out = <SplitRow>[];
  var i = 0;
  while (i < rows.length) {
    final l = rows[i];
    if (l == null) {
      out.add(const SplitRow(null, null));
      i++;
      continue;
    }
    if (l.op == DiffOp.equal) {
      out.add(SplitRow(l, l));
      i++;
      continue;
    }
    // A change block is any run of inserts/deletes, in either order.
    final dels = <DiffLine>[];
    final ins = <DiffLine>[];
    while (i < rows.length && rows[i] != null && rows[i]!.op != DiffOp.equal) {
      final r = rows[i++]!;
      (r.op == DiffOp.delete ? dels : ins).add(r);
    }
    final n = dels.length > ins.length ? dels.length : ins.length;
    for (var k = 0; k < n; k++) {
      out.add(SplitRow(k < dels.length ? dels[k] : null, k < ins.length ? ins[k] : null));
    }
  }
  return out;
}

/// Coloured, syntax-highlighted line diff; unchanged regions collapse.
class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.diff,
    this.path,
    this.layout = DiffLayout.unified,
    this.contextLines = 3,
  });

  final LineDiff diff;
  final String? path;
  final DiffLayout layout;
  final int contextLines;

  static const _rowH = 21.0;

  @override
  Widget build(BuildContext context) {
    if (diff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No changes', style: body(13, color: WoiColors.textDim)),
      );
    }
    final lang = langForPath(path);
    final rows = diff.withContext(contextLines);
    if (layout == DiffLayout.split) {
      final split = splitRows(rows);
      return Scrollbar(
        child: ListView.builder(
          itemCount: split.length,
          itemExtent: _rowH,
          itemBuilder: (context, i) {
            final r = split[i];
            if (r.isGap) return const _Gap();
            return Row(
              children: [
                Expanded(child: _side(r.left, lang, left: true)),
                Container(width: 1, color: WoiColors.stroke),
                Expanded(child: _side(r.right, lang, left: false)),
              ],
            );
          },
        ),
      );
    }
    return Scrollbar(
      child: ListView.builder(
        itemCount: rows.length,
        itemExtent: _rowH,
        itemBuilder: (context, i) {
          final l = rows[i];
          if (l == null) return const _Gap();
          final (bg, fg, sign) = _look(l.op);
          return Container(
            color: bg,
            child: Row(
              children: [
                _gutter(l.oldNo, fg, l.op),
                _gutter(l.newNo, fg, l.op),
                _sign(sign, fg),
                Expanded(child: _code(l, lang)),
              ],
            ),
          );
        },
      ),
    );
  }

  (Color, Color, String) _look(DiffOp op) => switch (op) {
    DiffOp.insert => (WoiColors.mint.withValues(alpha: 0.10), WoiColors.mint, '+'),
    DiffOp.delete => (WoiColors.red.withValues(alpha: 0.11), WoiColors.red, '−'),
    DiffOp.equal => (Colors.transparent, WoiColors.textFaint, ' '),
  };

  Widget _side(DiffLine? l, CodeLang lang, {required bool left}) {
    if (l == null) {
      return Container(color: Colors.black.withValues(alpha: 0.18));
    }
    final (bg, fg, sign) = _look(l.op);
    return Container(
      color: bg,
      child: Row(
        children: [
          _gutter(left ? l.oldNo : l.newNo, fg, l.op),
          _sign(sign, fg),
          Expanded(child: _code(l, lang)),
        ],
      ),
    );
  }

  Widget _sign(String s, Color fg) => SizedBox(
    width: 18,
    child: Text(s, style: mono(12.5, color: fg), textAlign: TextAlign.center),
  );

  Widget _code(DiffLine l, CodeLang lang) => Text.rich(
    TextSpan(
      children: highlightLine(
        l.text.replaceAll('\t', '    '),
        lang,
        base: l.op == DiffOp.equal ? WoiColors.textDim : CodeColors.plain,
      ),
    ),
    softWrap: false,
    overflow: TextOverflow.fade,
  );

  Widget _gutter(int? n, Color fg, DiffOp op) => Container(
    width: 44,
    padding: const EdgeInsets.only(right: 8),
    alignment: Alignment.centerRight,
    color: op == DiffOp.equal ? Colors.transparent : fg.withValues(alpha: 0.06),
    child: Text(
      n?.toString() ?? '',
      style: mono(11, color: op == DiffOp.equal ? WoiColors.textFaint : fg.withValues(alpha: 0.8)),
    ),
  );
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => Container(
    color: WoiColors.blue.withValues(alpha: 0.08),
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.only(left: 14),
    child: Text('⋯  unchanged lines hidden', style: mono(11, color: WoiColors.textFaint)),
  );
}
