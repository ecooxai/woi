import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/ui/widgets/bubble_markdown.dart';

void main() {
  group('splitBubbleText', () {
    test('plain text is one segment, untouched', () {
      final s = splitBubbleText('Hello\n\nworld');
      expect(s, hasLength(1));
      expect(s.single.code, isFalse);
      expect(s.single.text, 'Hello\n\nworld');
    });

    test('fenced code splits into text / code / text', () {
      final s = splitBubbleText('Run this:\n```sh\nflutter build linux\nls build\n```\nDone.');
      expect([for (final x in s) x.code], [false, true, false]);
      expect(s[0].text, 'Run this:');
      expect(s[1].text, 'flutter build linux\nls build');
      expect(s[1].lang, 'sh');
      expect(s[2].text, 'Done.');
    });

    test('an unclosed fence (streaming) runs to the end', () {
      final s = splitBubbleText('Code:\n```dart\nvoid main() {');
      expect(s, hasLength(2));
      expect(s[1].code, isTrue);
      expect(s[1].text, 'void main() {');
    });

    test('fence without a language', () {
      final s = splitBubbleText('```\nx\n```');
      expect(s.single.code, isTrue);
      expect(s.single.lang, '');
    });
  });

  test('inline code and bold drop their markers', () {
    final spans = bubbleInlineSpans('Use `ls -la` and **save** it', const TextStyle(fontSize: 15));
    final plain = TextSpan(children: spans).toPlainText();
    expect(plain, 'Use ls -la and save it');
  });

  test('lone backticks and asterisks stay literal', () {
    final spans = bubbleInlineSpans('2 * 3 = 6, a ` alone', const TextStyle(fontSize: 15));
    expect(TextSpan(children: spans).toPlainText(), '2 * 3 = 6, a ` alone');
  });

  testWidgets('BubbleText renders a code block with a copy button', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: BubbleText(
              text: 'Build:\n```sh\nflutter build linux --release\n```',
              style: TextStyle(fontSize: 15),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('bubble-code-block')), findsOneWidget);
    expect(find.byKey(const ValueKey('bubble-code-copy')), findsOneWidget);
    expect(find.text('Build:'), findsOneWidget);
    expect(find.text('flutter build linux --release'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('plain BubbleText is a single Text', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: BubbleText(text: 'Just words.', style: TextStyle(fontSize: 15)),
      ),
    );
    expect(find.text('Just words.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bubble-code-block')), findsNothing);
  });
}
