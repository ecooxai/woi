import 'package:flutter/material.dart';

import '../theme.dart';

/// Token colours: One-Dark-ish on the dark theme, GitHub-ish on light.
abstract final class CodeColors {
  static bool get _dark => WoiColors.palette.isDark;
  static Color get plain => _dark ? const Color(0xFFD5E1F5) : const Color(0xFF1F2937);
  static Color get keyword => _dark ? const Color(0xFFC792EA) : const Color(0xFF8250DF);
  static Color get string => _dark ? const Color(0xFFA5E887) : const Color(0xFF0A7F3F);
  static Color get number => _dark ? const Color(0xFFFFB86C) : const Color(0xFFB45309);
  static Color get comment => _dark ? const Color(0xFF7A8CAB) : const Color(0xFF6B7280);
  static Color get type => _dark ? const Color(0xFF7FDBFF) : const Color(0xFF0550AE);
  static Color get punct => _dark ? const Color(0xFF9DAFCB) : const Color(0xFF57606A);
}

enum CodeLang { cLike, hash, markup, plain }

CodeLang langForPath(String? path) {
  final p = (path ?? '').toLowerCase();
  final dot = p.lastIndexOf('.');
  final ext = dot < 0 ? '' : p.substring(dot + 1);
  if (p.endsWith('makefile') || p.endsWith('dockerfile')) return CodeLang.hash;
  return switch (ext) {
    'dart' || 'js' || 'ts' || 'tsx' || 'jsx' || 'java' || 'kt' || 'c' || 'h' || 'cc' || 'cpp' || 'hpp' || 'cs' ||
    'go' || 'rs' || 'swift' || 'scala' || 'glsl' || 'frag' || 'vert' || 'css' || 'scss' || 'json' || 'jsonc' ||
    'gradle' || 'php' => CodeLang.cLike,
    'py' || 'sh' || 'bash' || 'zsh' || 'fish' || 'rb' || 'yaml' || 'yml' || 'toml' || 'ini' || 'conf' || 'cfg' ||
    'cmake' || 'r' || 'pl' || 'nix' || 'env' => CodeLang.hash,
    'html' || 'xml' || 'svg' || 'md' || 'markdown' => CodeLang.markup,
    'txt' || 'log' || 'csv' || '' => CodeLang.plain,
    _ => CodeLang.cLike,
  };
}

const _keywords = {
  // c-like / dart / js / go / rust / java
  'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'defer',
  'do', 'else', 'enum', 'export', 'extends', 'extension', 'false', 'final', 'finally', 'fn', 'for', 'func', 'function',
  'get', 'go', 'if', 'impl', 'implements', 'import', 'in', 'interface', 'is', 'late', 'let', 'match', 'mixin', 'mod',
  'mut', 'new', 'null', 'nil', 'of', 'override', 'package', 'private', 'protected', 'pub', 'public', 'required',
  'return', 'sealed', 'set', 'static', 'struct', 'super', 'switch', 'this', 'throw', 'throws', 'trait', 'true', 'try',
  'type', 'typedef', 'use', 'var', 'void', 'when', 'where', 'while', 'with', 'yield', 'typeof', 'undefined',
  // python / shell / ruby
  'def', 'elif', 'except', 'from', 'lambda', 'None', 'True', 'False', 'not', 'and', 'or', 'pass', 'raise', 'self',
  'global', 'nonlocal', 'del', 'assert', 'then', 'fi', 'esac', 'done', 'echo', 'local', 'end', 'begin',
  'unless', 'until', 'module', 'require',
};

final _token = RegExp(
  r'''(?<str>"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`[^`]*`?)'''
  r'|(?<num>\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)\b)'
  r'|(?<word>[A-Za-z_\$][A-Za-z0-9_\$]*)'
  r'|(?<punct>[{}()\[\];,.<>=+\-*/%!&|^~?:]+)',
);

/// Highlights one line. Multi-line strings/comments are not tracked
/// (good enough for diffs and previews; never mis-renders text).
List<TextSpan> highlightLine(String line, CodeLang lang, {double size = 12.5, Color? base}) {
  TextStyle st(Color c, {bool italic = false}) => mono(size, color: c).copyWith(fontStyle: italic ? FontStyle.italic : null);
  final plain = st(base ?? CodeColors.plain);
  if (lang == CodeLang.plain || line.isEmpty) return [TextSpan(text: line, style: plain)];

  // Find a line comment start outside of strings.
  var commentAt = -1;
  final marker = switch (lang) {
    CodeLang.cLike => '//',
    CodeLang.hash => '#',
    CodeLang.markup => '<!--',
    CodeLang.plain => '',
  };
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == '\\') {
        i++;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '"' || ch == "'" || ch == '`') {
      quote = ch;
      continue;
    }
    if (line.startsWith(marker, i) || (lang == CodeLang.cLike && line.startsWith('/*', i))) {
      // '#' inside c-like (e.g. #include) is a directive, not a comment.
      commentAt = i;
      break;
    }
  }
  final code = commentAt < 0 ? line : line.substring(0, commentAt);
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in _token.allMatches(code)) {
    if (m.start > last) spans.add(TextSpan(text: code.substring(last, m.start), style: plain));
    final s = m.group(0)!;
    final TextStyle style;
    if (m.namedGroup('str') != null) {
      style = st(CodeColors.string);
    } else if (m.namedGroup('num') != null) {
      style = st(CodeColors.number);
    } else if (m.namedGroup('word') != null) {
      style = _keywords.contains(s)
          ? st(CodeColors.keyword)
          : (s[0].toUpperCase() == s[0] && s[0] != '_' && s[0] != r'$' ? st(CodeColors.type) : plain);
    } else {
      style = st(CodeColors.punct);
    }
    spans.add(TextSpan(text: s, style: style));
    last = m.end;
  }
  if (last < code.length) spans.add(TextSpan(text: code.substring(last), style: plain));
  if (commentAt >= 0) spans.add(TextSpan(text: line.substring(commentAt), style: st(CodeColors.comment, italic: true)));
  return spans;
}
