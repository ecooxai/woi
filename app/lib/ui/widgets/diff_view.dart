import 'package:flutter/material.dart';

import '../../core/util/diff.dart';
import '../theme.dart';

/// Colored line diff with gutters; unchanged regions are collapsed.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff, this.contextLines = 3});

  final LineDiff diff;
  final int contextLines;

  @override
  Widget build(BuildContext context) {
    final rows = diff.withContext(contextLines);
    if (diff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No changes', style: body(13, color: WoiColors.textDim)),
      );
    }
    return Scrollbar(
      child: ListView.builder(
        itemCount: rows.length,
        itemExtent: 21,
        itemBuilder: (context, i) {
          final l = rows[i];
          if (l == null) {
            return Container(
              color: WoiColors.blue.withValues(alpha: 0.08),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 12),
              child: Text('⋯', style: mono(12, color: WoiColors.textFaint)),
            );
          }
          final (bg, fg, sign) = switch (l.op) {
            DiffOp.insert => (WoiColors.mint.withValues(alpha: 0.10), WoiColors.mint, '+'),
            DiffOp.delete => (WoiColors.red.withValues(alpha: 0.10), WoiColors.red, '−'),
            DiffOp.equal => (Colors.transparent, WoiColors.textDim, ' '),
          };
          return Container(
            color: bg,
            child: Row(
              children: [
                _gutter(l.oldNo),
                _gutter(l.newNo),
                SizedBox(
                  width: 18,
                  child: Text(
                    sign,
                    style: mono(12.5, color: fg),
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: Text(
                    l.text.replaceAll('\t', '    '),
                    style: mono(12.5, color: l.op == DiffOp.equal ? WoiColors.textDim : WoiColors.text),
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _gutter(int? n) => Container(
    width: 44,
    padding: const EdgeInsets.only(right: 8),
    alignment: Alignment.centerRight,
    child: Text(n?.toString() ?? '', style: mono(11, color: WoiColors.textFaint)),
  );
}
