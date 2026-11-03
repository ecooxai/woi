/// Platform-neutral key chords for `send_keys`: "ctrl+c", "esc",
/// "ctrl+a ctrl+c", spoken forms ("control c", "ctrl-shift-t").
library;

enum KeyModifier { ctrl, shift, alt, superKey }

/// Edit intents that map to different keys per app (a terminal copies with
/// Ctrl+Shift+C) and to AccessibilityService actions on Android.
enum KeyAction {
  copy,
  paste,
  cut,
  selectAll,
  undo,
  redo,
  escape,
  enter,
  back;

  String get wire => switch (this) {
    KeyAction.selectAll => 'select_all',
    _ => name,
  };

  static KeyAction? parse(String? s) {
    if (s == null) return null;
    final k = s.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    for (final a in values) {
      if (a.wire == k || a.name.toLowerCase() == k) return a;
    }
    return null;
  }
}

/// One chord: modifiers held while [key] is pressed.
class KeyChord {
  const KeyChord(this.key, [this.modifiers = const {}]);

  /// Canonical key name: a single lowercase character, or one of
  /// [kNamedKeys] ("enter", "escape", "f5", "up", ...).
  final String key;
  final Set<KeyModifier> modifiers;

  bool get hasModifiers => modifiers.isNotEmpty;

  /// "ctrl+shift+t" (canonical order ctrl, shift, alt, super).
  @override
  String toString() => [
    for (final m in KeyModifier.values)
      if (modifiers.contains(m)) m == KeyModifier.superKey ? 'super' : m.name,
    key,
  ].join('+');

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.key == key &&
      other.modifiers.length == modifiers.length &&
      other.modifiers.containsAll(modifiers);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(modifiers));
}

const _modifierNames = {
  'ctrl': KeyModifier.ctrl,
  'control': KeyModifier.ctrl,
  'ctl': KeyModifier.ctrl,
  'strg': KeyModifier.ctrl,
  'shift': KeyModifier.shift,
  'alt': KeyModifier.alt,
  'option': KeyModifier.alt,
  'opt': KeyModifier.alt,
  'super': KeyModifier.superKey,
  'win': KeyModifier.superKey,
  'windows': KeyModifier.superKey,
  'meta': KeyModifier.superKey,
  'cmd': KeyModifier.superKey,
  'command': KeyModifier.superKey,
};

/// Spoken / alternative names -> canonical key names.
const kNamedKeys = {
  'enter': 'enter',
  'return': 'enter',
  'esc': 'escape',
  'escape': 'escape',
  'tab': 'tab',
  'space': 'space',
  'spacebar': 'space',
  'backspace': 'backspace',
  'delete': 'delete',
  'del': 'delete',
  'insert': 'insert',
  'ins': 'insert',
  'home': 'home',
  'end': 'end',
  'pageup': 'pageup',
  'pgup': 'pageup',
  'pagedown': 'pagedown',
  'pgdn': 'pagedown',
  'up': 'up',
  'down': 'down',
  'left': 'left',
  'right': 'right',
  'plus': 'plus',
  'minus': 'minus',
  'dash': 'minus',
  'period': 'period',
  'dot': 'period',
  'comma': 'comma',
  'slash': 'slash',
  'backslash': 'backslash',
  'semicolon': 'semicolon',
  'equal': 'equal',
  'equals': 'equal',
  'printscreen': 'print',
  'print': 'print',
  'menu': 'menu',
  'capslock': 'capslock',
};

const _punctuation = {
  '+': 'plus',
  '-': 'minus',
  '.': 'period',
  ',': 'comma',
  '/': 'slash',
  '\\': 'backslash',
  ';': 'semicolon',
  '=': 'equal',
};

final _fKey = RegExp(r'^f([1-9]|1[0-9]|2[0-4])$');

String? _canonicalKey(String raw) {
  final k = raw.toLowerCase().replaceAll(RegExp(r'[\s_]'), '');
  if (k.isEmpty) return null;
  final named = kNamedKeys[k];
  if (named != null) return named;
  if (_fKey.hasMatch(k)) return k;
  if (k.length == 1) return _punctuation[k] ?? k;
  return null;
}

/// Parses a key sequence. Chords are separated by spaces or commas; keys in
/// a chord by `+` (or `-` after a modifier). A bare modifier followed by a
/// key joins it ("control c" = ctrl+c). Throws [FormatException] for
/// unknown key names.
List<KeyChord> parseKeySequence(String spec) {
  final s = spec.trim();
  if (s.isEmpty) throw const FormatException('no keys given');
  final tokens = s
      .replaceAllMapped(
        RegExp(r'\b(page|caps|print|space|back)\s+(up|down|lock|screen|bar|space)\b', caseSensitive: false),
        (m) => '${m[1]}${m[2]}',
      )
      .replaceAll(RegExp(r'\s*\+\s*'), '+')
      .split(RegExp(r'[\s,]+|\s+then\s+', caseSensitive: false))
      .where((t) => t.isNotEmpty && t.toLowerCase() != 'then' && t.toLowerCase() != 'and')
      .toList();
  final chords = <KeyChord>[];
  final pendingMods = <KeyModifier>{};
  for (final token in tokens) {
    var parts = token == '+' ? ['+'] : token.split('+');
    // "ctrl-c" / "ctrl-shift-t": '-' separates after a modifier.
    if (parts.length == 1 && token.length > 1 && token.contains('-')) {
      final dash = token.split('-');
      if (dash.length > 1 && _modifierNames.containsKey(dash.first.toLowerCase())) {
        parts = [for (final d in dash) d.isEmpty ? '-' : d];
      }
    }
    // "ctrl++" -> ["ctrl", "", ""]: the key is '+'.
    if (parts.length > 2 && parts.last.isEmpty && parts[parts.length - 2].isEmpty) {
      parts = [...parts.sublist(0, parts.length - 2), '+'];
    }
    final mods = <KeyModifier>{...pendingMods};
    String? key;
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.isEmpty) continue;
      final mod = _modifierNames[p.toLowerCase()];
      if (mod != null && (i < parts.length - 1 || key == null)) {
        mods.add(mod);
        continue;
      }
      if (key != null) throw FormatException('more than one key in "$token"');
      key = _canonicalKey(p);
      if (key == null) throw FormatException('unknown key "$p"');
    }
    if (key == null) {
      // Only modifiers so far: they apply to the next token.
      pendingMods
        ..clear()
        ..addAll(mods);
      continue;
    }
    pendingMods.clear();
    chords.add(KeyChord(key, mods));
  }
  if (pendingMods.isNotEmpty) {
    // A lone modifier ("press shift"): press the modifier key itself.
    final m = pendingMods.first;
    chords.add(KeyChord(m == KeyModifier.superKey ? 'super' : m.name));
  }
  if (chords.isEmpty) throw const FormatException('no keys given');
  return chords;
}

/// Window classes of terminal emulators (they copy/paste with Shift added,
/// since Ctrl+C is SIGINT there).
final _terminalClass = RegExp(
  r'xterm|urxvt|rxvt|terminal|konsole|alacritty|kitty|wezterm|foot|terminator|tilix|st-256color|^st$|termite|sakura|guake|yakuake|ghostty',
  caseSensitive: false,
);

bool isTerminalWindowClass(String? windowClass) => windowClass != null && _terminalClass.hasMatch(windowClass);

/// Keys for an edit intent in a window of [windowClass].
List<KeyChord> chordsForAction(KeyAction a, {String? windowClass}) {
  final term = isTerminalWindowClass(windowClass);
  KeyChord c(String k, [bool shift = false]) =>
      KeyChord(k, {KeyModifier.ctrl, if (shift || term) KeyModifier.shift});
  return switch (a) {
    KeyAction.copy => [c('c')],
    KeyAction.paste => [c('v')],
    KeyAction.cut => [c('x')],
    KeyAction.selectAll => [c('a')],
    KeyAction.undo => [const KeyChord('z', {KeyModifier.ctrl})],
    KeyAction.redo => [const KeyChord('z', {KeyModifier.ctrl, KeyModifier.shift})],
    KeyAction.escape => const [KeyChord('escape')],
    KeyAction.enter => const [KeyChord('enter')],
    KeyAction.back => const [KeyChord('left', {KeyModifier.alt})],
  };
}

/// Where keys go. Both null: the active window that is not Woi.
class KeyTarget {
  const KeyTarget({this.window});

  /// Case-insensitive match against window title or class ("xterm",
  /// "Firefox", "notes.txt - gedit").
  final String? window;

  bool get isDefault => window == null || window!.trim().isEmpty;
}

/// What [InputControl.sendKeys] did.
class SendKeysResult {
  const SendKeysResult({required this.chords, this.windowTitle, this.windowClass, this.windowId, this.activated = false});
  final List<KeyChord> chords;
  final String? windowTitle;
  final String? windowClass;
  final String? windowId;

  /// The target had to be focused first.
  final bool activated;

  Map<String, Object?> toJson() => {
    'keys': chords.map((c) => '$c').join(' '),
    if (windowTitle != null && windowTitle!.isNotEmpty) 'window': windowTitle,
    if (windowClass != null && windowClass!.isNotEmpty) 'class': windowClass,
    if (activated) 'focused_first': true,
  };
}
