import 'dart:typed_data';

enum DiffOp { equal, insert, delete }

class DiffLine {
  const DiffLine(this.op, this.text, {this.oldNo, this.newNo});
  final DiffOp op;
  final String text;

  /// 1-based line numbers; null when the line doesn't exist on that side.
  final int? oldNo;
  final int? newNo;
}

class LineDiff {
  LineDiff(this.lines);
  final List<DiffLine> lines;

  int get added => lines.where((l) => l.op == DiffOp.insert).length;
  int get removed => lines.where((l) => l.op == DiffOp.delete).length;
  bool get isEmpty => added == 0 && removed == 0;

  /// Lines grouped into hunks with [context] unchanged lines around changes.
  /// `null` entries mark skipped regions.
  List<DiffLine?> withContext([int context = 3]) {
    final keep = List<bool>.filled(lines.length, false);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].op != DiffOp.equal) {
        final from = (i - context).clamp(0, lines.length - 1);
        final to = (i + context).clamp(0, lines.length - 1);
        for (var k = from; k <= to; k++) {
          keep[k] = true;
        }
      }
    }
    final out = <DiffLine?>[];
    var skipping = false;
    for (var i = 0; i < lines.length; i++) {
      if (keep[i]) {
        out.add(lines[i]);
        skipping = false;
      } else if (!skipping) {
        out.add(null);
        skipping = true;
      }
    }
    return out;
  }

  /// Compact unified-style text (no headers), used in tool results.
  String unified({int context = 2, int maxLines = 80}) {
    final sb = StringBuffer();
    var n = 0;
    for (final l in withContext(context)) {
      if (n++ >= maxLines) {
        sb.writeln('… (diff truncated)');
        break;
      }
      if (l == null) {
        sb.writeln('@@');
        continue;
      }
      final prefix = switch (l.op) {
        DiffOp.equal => ' ',
        DiffOp.insert => '+',
        DiffOp.delete => '-',
      };
      sb.writeln('$prefix${l.text}');
    }
    return sb.toString();
  }
}

List<String> _splitLines(String s) {
  if (s.isEmpty) return const [];
  final parts = s.split('\n');
  if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
  return parts;
}

/// Line diff via common prefix/suffix trimming + LCS on the middle.
/// Falls back to a block replace when the middle is very large.
LineDiff diffLines(String oldText, String newText, {int maxCells = 4000000}) {
  final a = _splitLines(oldText);
  final b = _splitLines(newText);
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre &&
      suf < b.length - pre &&
      a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final out = <DiffLine>[];
  for (var i = 0; i < pre; i++) {
    out.add(DiffLine(DiffOp.equal, a[i], oldNo: i + 1, newNo: i + 1));
  }
  final am = a.sublist(pre, a.length - suf);
  final bm = b.sublist(pre, b.length - suf);
  final n = am.length, m = bm.length;

  if (n * m > maxCells) {
    for (var i = 0; i < n; i++) {
      out.add(DiffLine(DiffOp.delete, am[i], oldNo: pre + i + 1));
    }
    for (var j = 0; j < m; j++) {
      out.add(DiffLine(DiffOp.insert, bm[j], newNo: pre + j + 1));
    }
  } else {
    // dp[i][j] = LCS length of am[i..] and bm[j..]
    final w = m + 1;
    final dp = Uint32List((n + 1) * w);
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i * w + j] = am[i] == bm[j]
            ? dp[(i + 1) * w + j + 1] + 1
            : (dp[(i + 1) * w + j] >= dp[i * w + j + 1]
                ? dp[(i + 1) * w + j]
                : dp[i * w + j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && am[i] == bm[j]) {
        out.add(DiffLine(DiffOp.equal, am[i],
            oldNo: pre + i + 1, newNo: pre + j + 1));
        i++;
        j++;
      } else if (j < m && (i >= n || dp[i * w + j + 1] >= dp[(i + 1) * w + j])) {
        out.add(DiffLine(DiffOp.insert, bm[j], newNo: pre + j + 1));
        j++;
      } else {
        out.add(DiffLine(DiffOp.delete, am[i], oldNo: pre + i + 1));
        i++;
      }
    }
  }
  for (var k = 0; k < suf; k++) {
    final oi = a.length - suf + k;
    final ni = b.length - suf + k;
    out.add(DiffLine(DiffOp.equal, a[oi], oldNo: oi + 1, newNo: ni + 1));
  }
  return LineDiff(out);
}
