import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/notes/note_copy.dart';

void main() {
  const doc = '''intro line

# Plan
first para line 1
first para line 2

second para

# Shopping
- milk
- eggs
```sh
# not a heading
echo hi
```
tail

''';
  int at(String needle, [int delta = 0]) => doc.indexOf(needle) + delta;

  group('line', () {
    test('the cursor line, without the newline', () {
      expect(noteCopyText(doc, at('first para line 2', 3), NoteCopyScope.line), 'first para line 2');
      expect(noteCopyText(doc, 0, NoteCopyScope.line), 'intro line');
      // Cursor at the end of a line (just before the newline).
      expect(noteCopyText(doc, at('- milk', 6), NoteCopyScope.line), '- milk');
      // Cursor at the start of a line.
      expect(noteCopyText(doc, at('- eggs'), NoteCopyScope.line), '- eggs');
      expect(noteCopyText(doc, at('\n\nsecond', 1), NoteCopyScope.line), '');
    });
    test('clamps the cursor', () {
      expect(noteCopyText('a\nb', 99, NoteCopyScope.line), 'b');
      expect(noteCopyText('a\nb', -5, NoteCopyScope.line), 'a');
      expect(noteCopyText('', 0, NoteCopyScope.line), '');
    });
  });

  group('paragraph', () {
    test('text between blank lines', () {
      expect(
        noteCopyText(doc, at('line 1'), NoteCopyScope.paragraph),
        '# Plan\nfirst para line 1\nfirst para line 2',
      );
      expect(noteCopyText(doc, at('second'), NoteCopyScope.paragraph), 'second para');
      expect(noteCopyText(doc, 3, NoteCopyScope.paragraph), 'intro line');
    });
    test('on a blank line: the paragraph above, else below', () {
      expect(noteCopyText(doc, at('\n\nsecond', 1), NoteCopyScope.paragraph), '# Plan\nfirst para line 1\nfirst para line 2');
      expect(noteCopyText('\n\nonly\nthis\n', 0, NoteCopyScope.paragraph), 'only\nthis');
      expect(noteCopyText('\n \n', 1, NoteCopyScope.paragraph), '');
      // End of a note ending in a newline.
      expect(noteCopyText(doc, doc.length, NoteCopyScope.paragraph), contains('tail'));
    });
    test('whitespace-only lines count as blank', () {
      expect(noteCopyText('a\n  \nb\nc', 5, NoteCopyScope.paragraph), 'b\nc');
    });
  });

  group('H1 section', () {
    test('from the H1 above to the next H1', () {
      expect(
        noteCopyText(doc, at('second'), NoteCopyScope.section),
        '# Plan\nfirst para line 1\nfirst para line 2\n\nsecond para',
      );
      // On the heading line itself.
      expect(noteCopyText(doc, at('# Plan'), NoteCopyScope.section), startsWith('# Plan\n'));
    });
    test('last section runs to the end; # inside code fences is not a heading', () {
      final s = noteCopyText(doc, at('echo'), NoteCopyScope.section);
      expect(s, startsWith('# Shopping\n- milk'));
      expect(s, contains('# not a heading'));
      expect(s, endsWith('tail'));
    });
    test('before the first H1: from the top; H2 does not split', () {
      expect(noteCopyText(doc, 2, NoteCopyScope.section), 'intro line');
      expect(noteCopyText('# A\n## B\nx\n# C\ny', 9, NoteCopyScope.section), '# A\n## B\nx');
      expect(noteCopyText('no headings\nat all', 3, NoteCopyScope.section), 'no headings\nat all');
    });
  });

  test('note copies everything', () {
    expect(noteCopyText(doc, 5, NoteCopyScope.note), doc);
  });

  test('parse and labels', () {
    expect(NoteCopyScope.parse('this paragraph'), NoteCopyScope.paragraph);
    expect(NoteCopyScope.parse('the current line'), NoteCopyScope.line);
    expect(NoteCopyScope.parse('heading section'), NoteCopyScope.section);
    expect(NoteCopyScope.parse('h1'), NoteCopyScope.section);
    expect(NoteCopyScope.parse(null), NoteCopyScope.note);
    expect(NoteCopyScope.parse('whole note'), NoteCopyScope.note);
    expect(NoteCopyScope.parse('banana'), isNull);
    expect(noteCopyLabel(NoteCopyScope.paragraph, 'a\nb'), 'Copied paragraph (2 lines)');
    expect(noteCopyLabel(NoteCopyScope.line, 'a'), 'Copied line');
  });
}
