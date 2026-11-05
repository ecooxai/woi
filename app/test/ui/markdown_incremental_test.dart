import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/ui/notes/markdown_syntax.dart';

/// Per-character (char, style) of a span tree, resolving inherited styles.
List<(String, TextStyle?)> _flat(InlineSpan span) {
  final out = <(String, TextStyle?)>[];
  void walk(InlineSpan s, TextStyle? inherited) {
    if (s is! TextSpan) return;
    final st = s.style == null ? inherited : (inherited?.merge(s.style) ?? s.style);
    for (final c in (s.text ?? '').split('')) {
      out.add((c, st));
    }
    for (final ch in s.children ?? const <InlineSpan>[]) {
      walk(ch, st);
    }
  }

  walk(span, null);
  return out;
}

/// The reference: whole-note [highlightMarkdown], merged onto the root style.
List<(String, TextStyle?)> _expected(String text) {
  final root = MdEditorStyle.base();
  return [
    for (final r in highlightMarkdown(text))
      for (var i = r.start; i < r.end; i++) (text[i], root.merge(r.style)),
  ];
}

const _note = '''# Title

Some *intro* text with `code` and a [link](https://x.dev).

- [ ] todo **bold**
- [x] done
1. first

```dart
final a = 1; // # not a heading
- not a list
```

> quote _it_

## Tail
last line''';

void main() {
  late BuildContext ctx;
  late MarkdownEditingController c;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));
  }

  TextSpan build() => c.buildTextSpan(context: ctx, withComposing: true);

  void check(String text) {
    c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    final span = build();
    expect(_flat(span), _expected(text), reason: text);
  }

  List<InlineSpan> lineSpans() => build().children!;

  testWidgets('matches whole-note highlighting for edits at start / middle / end', (tester) async {
    await pump(tester);
    c = MarkdownEditingController(text: _note);
    check(_note);
    check('x$_note');
    check(_note.replaceFirst('intro', 'intr'));
    check('$_note!');
    check(_note.replaceFirst('## Tail', '##Tail'));
    check(_note.replaceFirst('- [ ] todo', '- [x] todo'));
    check('');
    check('\n\n');
    check(_note);
  });

  testWidgets('an edit re-highlights only the edited line; other lines keep their spans', (tester) async {
    await pump(tester);
    c = MarkdownEditingController(text: _note);
    final before = lineSpans();
    expect(c.lastHighlightedLines, _note.split('\n').toSet().length); // repeated lines share one entry
    c.text = _note.replaceFirst('intro', 'introX');
    final after = lineSpans();
    expect(c.lastHighlightedLines, 1);
    expect(after.length, before.length);
    var same = 0;
    for (var i = 0; i < before.length; i++) {
      if (identical(before[i], after[i])) same++;
    }
    expect(same, before.length - 1);
    expect(_flat(build()), _expected(c.text));
  });

  testWidgets('opening / closing a code fence by an edit', (tester) async {
    await pump(tester);
    c = MarkdownEditingController(text: _note);
    build();
    // Break the opening fence: everything after it changes state.
    final broken = _note.replaceFirst('```dart', '``dart');
    check(broken);
    expect(c.lastHighlightedLines, greaterThan(3));
    // Restore it: lines come back with the right state.
    check(_note);
    // Open a new fence near the top (unterminated until the old opener).
    check(_note.replaceFirst('# Title\n', '# Title\n```\n'));
    // Close it again on the next line.
    // (the lines below it were cached in the inverted state only, so they
    // are highlighted again here).
    check(_note.replaceFirst('# Title\n', '# Title\n```\n```\n'));
    // Remove the closing fence at the end.
    check(_note.replaceFirst('list\n```', 'list\n'));
  });

  testWidgets('paste and undo', (tester) async {
    await pump(tester);
    c = MarkdownEditingController(text: _note);
    build();
    const pasted = '\n## Pasted\n- a\n- b `c`\n```\ncode\n```\n';
    final at = _note.indexOf('> quote');
    final withPaste = _note.substring(0, at) + pasted + _note.substring(at);
    check(withPaste);
    check(_note); // undo
    expect(c.lastHighlightedLines, lessThanOrEqualTo(2));
    check(withPaste); // redo
    check(_note.substring(0, 20)); // delete most of the note
    check(_note);
  });

  testWidgets('AI range and composing range still split and style the runs', (tester) async {
    await pump(tester);
    c = MarkdownEditingController(text: _note);
    final start = _note.indexOf('intro');
    c.aiRange = TextRange(start: start, end: start + 3);
    final flat = _flat(build());
    expect(flat[start].$2!.backgroundColor, isNotNull);
    expect(flat[start + 3].$2!.backgroundColor, isNull);
    expect(flat.map((e) => e.$1).join(), _note);
    c.aiRange = null;
    final tail = _note.indexOf('Tail');
    c.value = TextEditingValue(
      text: _note,
      selection: TextSelection.collapsed(offset: tail + 4),
      composing: TextRange(start: tail, end: tail + 4),
    );
    final f2 = _flat(build());
    expect(f2[tail].$2!.decoration, TextDecoration.underline);
    expect(f2[tail - 1].$2!.decoration, isNot(TextDecoration.underline));
    expect(f2.map((e) => e.$1).join(), _note);
  });
}
