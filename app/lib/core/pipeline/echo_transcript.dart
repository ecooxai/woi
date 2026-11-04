import 'dart:math';

/// Whether a user transcript is (most likely) Woi's own speech heard back:
/// residual echo that reached the server's VAD and transcriber. The
/// transcriber mis-hears it ("Pointer moved." → "Boiner moot.", "Jasne." →
/// "Ja"), so words are compared by sound: a consonant skeleton with
/// voiced/voiceless pairs merged.
///
/// [recent] is what Woi said recently (reply texts). The transcript is echo
/// when most of it (weighted by sound content) matches, in order, a short
/// stretch of that text. Short function words must match by spelling and
/// one-word transcripts by spelling or prefix ("Ja" of "Jasne"), so common
/// answers ("yes", "no") are not mistaken for "is" / "know".
bool isEchoOf(String transcript, List<String> recent) => echoScore(transcript, recent) >= echoThreshold;

const echoThreshold = 0.8;

/// 0..1: the share of [transcript] explained by [recent] (see [isEchoOf]).
double echoScore(String transcript, List<String> recent) {
  final a = [for (final w in _words(transcript)) _Word(w)];
  if (a.isEmpty) return 0;
  final b = [for (final w in _words(recent.join(' '))) _Word(w)];
  if (b.isEmpty) return 0;
  final total = a.fold(0.0, (s, w) => s + w.weight);
  final single = a.length == 1;
  // Best in-order match within a window of the reference a bit longer than
  // the transcript (echo is a contiguous stretch of what was played).
  final win = a.length * 2 + 2;
  var best = 0.0;
  for (var j = 0; j < b.length; j++) {
    final m = _fuzzyLcs(a, b.sublist(j, min(b.length, j + win)), single);
    if (m > best) best = m;
    if (best >= total) break;
  }
  return best / total;
}

class _Word {
  _Word(String w) : text = _fold(w), skeleton = _skeleton(w);
  final String text;
  final String skeleton;

  /// Sound content: one-consonant words ("it", "the") count half.
  double get weight => skeleton.length <= 1 ? 0.5 : skeleton.length.toDouble();

  bool matches(_Word o, {bool single = false}) {
    if (text == o.text) return true;
    if (single) {
      // A lone word: spelling, or a clipped start ("ja" of "jasne").
      return text.length >= 2 && o.text.startsWith(text);
    }
    final n = max(skeleton.length, o.skeleton.length);
    if (n <= 1) return false; // spelling only (above)
    if (n == 2) return skeleton == o.skeleton;
    return _lev(skeleton, o.skeleton) <= (n <= 5 ? 1 : 2);
  }
}

final _wordRe = RegExp(r"[\p{L}\p{N}']+", unicode: true);

List<String> _words(String s) => [for (final m in _wordRe.allMatches(s.toLowerCase())) m.group(0)!];

/// Consonant skeleton with confusable sounds merged; a word with no
/// consonants keeps its first vowel ("a", "oh").
String _skeleton(String w) {
  final s = _fold(w);
  final out = StringBuffer();
  String? last;
  for (var i = 0; i < s.length; i++) {
    final c = _class(s, i);
    if (c == null || c == last) {
      last = c ?? last;
      continue;
    }
    out.write(c);
    last = c;
  }
  if (out.isEmpty && s.isNotEmpty) return 'a';
  return out.toString();
}

/// Lowercase ASCII-ish fold of common Latin diacritics (Polish, German,
/// French, Spanish).
String _fold(String w) {
  const map = {
    'ą': 'a', 'ć': 'c', 'ę': 'e', 'ł': 'l', 'ń': 'n', 'ó': 'o', 'ś': 's', 'ź': 'z', 'ż': 'z', //
    'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 's', 'é': 'e', 'è': 'e', 'ê': 'e', 'à': 'a', 'ç': 'c', //
    'ñ': 'n', 'á': 'a', 'í': 'i', 'ú': 'u',
  };
  final b = StringBuffer();
  for (final ch in w.split('')) {
    b.write(map[ch] ?? ch);
  }
  return b.toString();
}

/// Sound class of the letter at [i] (null for vowels and silent letters).
String? _class(String s, int i) {
  final c = s[i];
  switch (c) {
    case 'a' || 'e' || 'i' || 'o' || 'u' || 'y' || "'" || 'h' || 'w':
      return null;
    case 'b' || 'p':
      return 'P';
    case 'd' || 't':
      return 'T';
    case 'g' || 'k' || 'q' || 'c' || 'x':
      return 'K';
    case 'f' || 'v':
      return 'F';
    case 's' || 'z' || 'j':
      return 'S';
    case 'm' || 'n':
      return 'N';
    case 'l' || 'r':
      return 'L';
    default:
      return RegExp(r'\d').hasMatch(c) ? c : null;
  }
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Longest common subsequence of [a] in [b] (word matches per
/// [_Word.matches]), weighted by [_Word.weight].
double _fuzzyLcs(List<_Word> a, List<_Word> b, bool single) {
  var prev = List<double>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<double>.filled(b.length + 1, 0);
    for (var j = 1; j <= b.length; j++) {
      cur[j] = a[i - 1].matches(b[j - 1], single: single)
          ? prev[j - 1] + a[i - 1].weight
          : max(prev[j], cur[j - 1]);
    }
    prev = cur;
  }
  return prev[b.length];
}
