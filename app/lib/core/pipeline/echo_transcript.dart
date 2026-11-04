import 'dart:math';

import 'barge_in.dart' show isStopPhrase;

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

/// Writing system of a transcript, by its letters (digits/punctuation ignored).
enum TranscriptScript { latin, han, kana, hangul, cyrillic, greek, arabic, hebrew, thai, devanagari, other }

TranscriptScript? _scriptOf(int r) {
  if (r < 0x80) return (r >= 0x41 && r <= 0x5a) || (r >= 0x61 && r <= 0x7a) ? TranscriptScript.latin : null;
  if (r >= 0xc0 && r <= 0x24f) return TranscriptScript.latin;
  if (r >= 0x370 && r <= 0x3ff) return TranscriptScript.greek;
  if (r >= 0x400 && r <= 0x52f) return TranscriptScript.cyrillic;
  if (r >= 0x590 && r <= 0x5ff) return TranscriptScript.hebrew;
  if (r >= 0x600 && r <= 0x6ff) return TranscriptScript.arabic;
  if (r >= 0x900 && r <= 0x97f) return TranscriptScript.devanagari;
  if (r >= 0xe00 && r <= 0xe7f) return TranscriptScript.thai;
  if (r >= 0x1100 && r <= 0x11ff || r >= 0x3130 && r <= 0x318f || r >= 0xac00 && r <= 0xd7af) {
    return TranscriptScript.hangul;
  }
  if (r >= 0x3040 && r <= 0x30ff) return TranscriptScript.kana;
  if (r >= 0x3400 && r <= 0x9fff || r >= 0xf900 && r <= 0xfaff) return TranscriptScript.han;
  if (r >= 0x1e00 && r <= 0x1eff) return TranscriptScript.latin;
  final c = String.fromCharCode(r);
  return RegExp(r'\p{L}', unicode: true).hasMatch(c) ? TranscriptScript.other : null;
}

/// The script most of [text]'s letters are written in (null: no letters).
/// Japanese kana with kanji counts as kana.
TranscriptScript? dominantScript(String text) {
  final n = <TranscriptScript, int>{};
  for (final r in text.runes) {
    final s = _scriptOf(r);
    if (s != null) n[s] = (n[s] ?? 0) + 1;
  }
  if (n.isEmpty) return null;
  if ((n[TranscriptScript.kana] ?? 0) > 0 && n.keys.every((k) => k == TranscriptScript.kana || k == TranscriptScript.han)) {
    return TranscriptScript.kana;
  }
  return n.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// Hesitation sounds in common languages: what the transcriber makes of a
/// fragment of echo ("아", "嗯", "uh").
const _fillers = {
  'uh', 'um', 'umm', 'uhm', 'hmm', 'hm', 'mm', 'mmm', 'mhm', 'ah', 'oh', 'eh', 'er', 'erm', 'huh', 'ha', 'ooh', //
  '아', '어', '오', '음', '으', '응', '흠', '에', '아아', '어어', //
  '嗯', '啊', '呃', '哦', '额', '唔', '噢', '诶', '欸', '嗯嗯', '啊啊', //
  'あ', 'え', 'ええ', 'うん', 'あの', 'えっと', 'ん', //
  'э', 'а', 'ну', 'хм',
};

/// Short stop / wait requests in other languages (English ones are
/// [isStopPhrase]'s): never treated as echo.
const _foreignStops = {
  '停', '停下', '停止', '停一下', '别说了', '别说', '等等', '等一下', '等下', '闭嘴', '够了', '算了', '暂停', '好了', //
  '멈춰', '그만', '잠깐', '잠깐만', '스톱', '멈춰요', '그만해', //
  'やめて', '止めて', '待って', 'ストップ', 'ちょっと待って', //
  'stopp', 'halt', 'warte', 'arrête', 'basta', 'para', 'espera', 'stój', 'czekaj', 'стоп', 'хватит', 'подожди',
};

String _bare(String s) => s.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}' ]", unicode: true), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

/// Whether [text] is an explicit stop / wait request (any language).
bool isStopRequest(String text) {
  final b = _bare(text);
  if (b.isEmpty) return false;
  return _foreignStops.contains(b) || _foreignStops.contains(b.replaceAll(' ', '')) || b.split(' ').every(_foreignStops.contains);
}

/// A user transcript that is short (≤ 2 words, ≤ 4 Han/kana characters).
bool isShortTranscript(String text) {
  final b = _bare(text);
  if (b.isEmpty) return false;
  final words = b.split(' ');
  if (words.length > 2) return false;
  final cjk = b.runes.where((r) {
    final s = _scriptOf(r);
    return s == TranscriptScript.han || s == TranscriptScript.kana;
  }).length;
  return cjk <= 4;
}

/// Why a short user transcript heard while Woi speaks (or in its echo
/// tail), with no local near-end onset, is most likely a mis-transcribed
/// fragment of Woi's own echo rather than the user; null when it may be the
/// user. Echo of English speech is often transcribed as another language
/// ("아", "하고"), which [isEchoOf] cannot match.
///
/// Echo when it is short ([isShortTranscript]) and either a pure filler
/// ("uh", "아", "嗯") or written in a script that is neither that of Woi's
/// reply ([said]) nor of any of the user's recent turns ([userRecent]).
/// Explicit stop requests ("stop", "停", "wait", "그만") are never echo.
String? shortEchoReason(String transcript, {required List<String> said, required List<String> userRecent}) {
  final t = transcript.trim();
  if (t.isEmpty || !isShortTranscript(t)) return null;
  if (isStopPhrase(t) || isStopRequest(t)) return null;
  final b = _bare(t);
  if (_fillers.contains(b) || b.split(' ').every(_fillers.contains)) return 'filler';
  final s = dominantScript(t);
  if (s == null) return null;
  final woi = dominantScript(said.join(' '));
  final user = {for (final u in userRecent) dominantScript(u)}..remove(null);
  if (woi == null && user.isEmpty) return null; // nothing to compare with
  if (s != woi && !user.contains(s)) return 'script ${s.name}';
  return null;
}
