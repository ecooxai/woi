import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/util/diff.dart';

void main() {
  test('identical text has no changes', () {
    final d = diffLines('a\nb\n', 'a\nb\n');
    expect(d.isEmpty, isTrue);
    expect((d.added, d.removed), (0, 0));
  });

  test('replacement in the middle keeps line numbers', () {
    final d = diffLines('a\nb\nc\n', 'a\nB\nc\n');
    expect((d.added, d.removed), (1, 1));
    final del = d.lines.firstWhere((l) => l.op == DiffOp.delete);
    final ins = d.lines.firstWhere((l) => l.op == DiffOp.insert);
    expect((del.text, del.oldNo), ('b', 2));
    expect((ins.text, ins.newNo), ('B', 2));
    expect(d.unified(), contains('-b'));
    expect(d.unified(), contains('+B'));
  });

  test('new file is all insertions', () {
    final d = diffLines('', 'x\ny\n');
    expect(d.added, 2);
    expect(d.removed, 0);
  });

  test('withContext collapses far-away unchanged lines', () {
    final old = List.generate(50, (i) => 'line $i').join('\n');
    final changed = old.replaceFirst('line 25', 'LINE 25');
    final rows = diffLines(old, changed).withContext(2);
    expect(rows.whereType<DiffLine>().where((l) => l.op == DiffOp.equal), hasLength(4));
    expect(rows.where((r) => r == null), isNotEmpty);
  });
}
