import 'package:flutter/material.dart';

import '../theme.dart';
import 'clipboard_selection_area.dart';
import 'code_highlight.dart';

/// One piece of a reply: running text, or the body of a fenced code block.
class BubbleSegment {
  const BubbleSegment.text(this.text) : code = false, lang = '';
  const BubbleSegment.code(this.text, this.lang) : code = true;

  final String text;
  final bool code;

  /// Language tag after the opening fence ("dart", "sh"); empty when absent.
  final String lang;
}

final _fenceLine = RegExp(r'^\s{0,3}(```|~~~)\s*([\w+#.-]*)\s*$');
final _inlineMarkup = RegExp(r'(`[^`\n]+`)|\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*');

/// True when [text] has anything [BubbleText] renders specially. Plain
/// replies (nearly all spoken ones) skip parsing entirely.
bool hasBubbleMarkup(String text) => text.contains('`') || text.contains('**') || text.contains('~~~');

/// Splits a reply into text and fenced-code segments. A fence that is still
/// open (the reply is streaming) runs to the end, so the block does not
/// flicker between text and code while it arrives. Line breaks inside text
/// are kept as written.
List<BubbleSegment> splitBubbleText(String text) {
  if (!text.contains('```') && !text.contains('~~~')) return [BubbleSegment.text(text)];
  final out = <BubbleSegment>[];
  final lines = text.split('\n');
  final buf = <String>[];
  void flushText() {
    while (buf.isNotEmpty && buf.first.trim().isEmpty) {
      buf.removeAt(0);
    }
    while (buf.isNotEmpty && buf.last.trim().isEmpty) {
      buf.removeLast();
    }
    if (buf.isNotEmpty) out.add(BubbleSegment.text(buf.join('\n')));
    buf.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final open = _fenceLine.firstMatch(lines[i]);
    if (open == null) {
      buf.add(lines[i]);
      i++;
      continue;
    }
    flushText();
    final fence = open.group(1)!;
    final code = <String>[];
    i++;
    while (i < lines.length && !lines[i].trimLeft().startsWith(fence)) {
      code.add(lines[i]);
      i++;
    }
    i++; // closing fence (or past the end while streaming)
    out.add(BubbleSegment.code(code.join('\n'), open.group(2) ?? ''));
  }
  flushText();
  return out;
}

/// Inline spans of one text segment: `code` and **bold**; everything else
/// stays exactly as written.
List<InlineSpan> bubbleInlineSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var pos = 0;
  for (final m in _inlineMarkup.allMatches(text)) {
    if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
    final code = m.group(1);
    if (code != null) {
      spans.add(
        TextSpan(
          text: code.substring(1, code.length - 1),
          style: mono((base.fontSize ?? 15) * 0.9, color: _inlineCodeText).copyWith(backgroundColor: _inlineCodeFill),
        ),
      );
    } else {
      spans.add(TextSpan(text: m.group(2), style: weighted(base, FontWeight.w700)));
    }
    pos = m.end;
  }
  if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
  return spans;
}

// Bubbles are light in both app themes, so inline code uses fixed colours.
const _inlineCodeText = Color(0xFF1F2937);
const _inlineCodeFill = Color(0x140F172A);

/// The text of a reply bubble. Plain text renders as one [Text] (selectable
/// through the transcript's SelectionArea); fenced code gets its own block
/// with syntax colours and a copy button, `inline code` and **bold** are
/// styled in place.
class BubbleText extends StatelessWidget {
  const BubbleText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (!hasBubbleMarkup(text)) return Text(text, style: style);
    final segments = splitBubbleText(text);
    Widget run(String t) => _inlineMarkup.hasMatch(t)
        ? Text.rich(TextSpan(children: bubbleInlineSpans(t, style)), style: style)
        : Text(t, style: style);
    if (segments.length == 1 && !segments.first.code) return run(segments.first.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
            child: segments[i].code
                ? BubbleCodeBlock(code: segments[i].text, lang: segments[i].lang)
                : run(segments[i].text),
          ),
      ],
    );
  }
}

/// A fenced code block inside a bubble: language label, copy button and
/// highlighted, horizontally scrollable code. Follows the app theme (dark
/// block on the dark theme, tinted block on the light one).
class BubbleCodeBlock extends StatefulWidget {
  const BubbleCodeBlock({super.key, required this.code, required this.lang});

  final String code;
  final String lang;

  @override
  State<BubbleCodeBlock> createState() => _BubbleCodeBlockState();
}

class _BubbleCodeBlockState extends State<BubbleCodeBlock> {
  bool _copied = false;
  int _copySeq = 0;

  // Highlighted spans, rebuilt only when the code, language or theme change
  // (the bubble around it rebuilds for unrelated reasons too).
  List<InlineSpan>? _spans;
  String? _spansCode;
  String? _spansLang;
  bool? _spansDark;

  List<InlineSpan> _highlighted(bool dark) {
    final cached = _spans;
    if (cached != null && _spansCode == widget.code && _spansLang == widget.lang && _spansDark == dark) return cached;
    final lang = langForPath('x.${widget.lang.isEmpty ? 'txt' : widget.lang.toLowerCase()}');
    final lines = widget.code.split('\n');
    final spans = <InlineSpan>[
      for (var i = 0; i < lines.length; i++) ...[
        ...highlightLine(lines[i], lang, size: 13),
        if (i < lines.length - 1) const TextSpan(text: '\n'),
      ],
    ];
    _spans = spans;
    _spansCode = widget.code;
    _spansLang = widget.lang;
    _spansDark = dark;
    return spans;
  }

  Future<void> _copy() async {
    final seq = ++_copySeq;
    try {
      await ClipboardSelectionArea.clipboardOf(context).writeText(widget.code);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Copy failed: $error')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && seq == _copySeq) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final dark = WoiColors.palette.isDark;
    final fill = dark ? const Color(0xFF0E131C) : const Color(0xFFEDF1F5);
    final edge = dark ? const Color(0xFF1F2937) : const Color(0xFFD5DCE5);
    final faint = dark ? const Color(0xFF8A919C) : const Color(0xFF6B7280);
    return Container(
      key: const ValueKey('bubble-code-block'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(WoiRadii.sm),
        border: Border.all(color: edge),
      ),
      // No rounded clip: the padding keeps the code off the corners, and an
      // anti-aliased clip is costly to raster on every scrolled frame.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Chrome, not content: kept out of a transcript selection.
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.lang.isEmpty ? 'code' : widget.lang.toLowerCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11, color: faint),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('bubble-code-copy'),
                    tooltip: _copied ? 'Copied' : 'Copy code',
                    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                    padding: EdgeInsets.zero,
                    iconSize: 15,
                    color: _copied ? (dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857)) : faint,
                    onPressed: _copy,
                    icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
                  ),
                ],
              ),
            ),
          ),
          ScrollConfiguration(
            // No desktop auto-scrollbar per block; wide code still scrolls.
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text.rich(
                TextSpan(children: _highlighted(dark)),
                style: mono(13, height: 1.5, color: CodeColors.plain),
                softWrap: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
