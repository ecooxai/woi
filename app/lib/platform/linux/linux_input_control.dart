import 'dart:math';

import '../input_control.dart';
import 'exec_util.dart';
import 'x11_key_target.dart';

/// X11 input injection through xdotool.
class LinuxInputControl implements InputControl {
  LinuxInputControl({X11Windows? windows}) : targets = KeyTargetResolver(windows ?? XpropWindows());

  /// Default `send_keys` target selection (active / remembered non-Woi window).
  final KeyTargetResolver targets;

  String get _xdo => which('xdotool') ?? (throw MissingTool(['xdotool']));

  Future<String> _run(List<String> args) async {
    final r = await runChecked(_xdo, args, environment: x11Env());
    return '${r.stdout}';
  }

  static String _button(MouseButton b) => switch (b) {
    MouseButton.left => '1',
    MouseButton.middle => '2',
    MouseButton.right => '3',
  };

  @override
  Future<void> moveMouse(int x, int y) => _run(['mousemove', '--sync', '$x', '$y']);

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left}) =>
      _run(['mousemove', '--sync', '$x', '$y', 'click', _button(button)]);

  @override
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left}) =>
      _run(['mousemove', '--sync', '$x', '$y', 'click', '--repeat', '2', '--delay', '80', _button(button)]);

  @override
  Future<void> typeText(String text) async {
    if (text.isEmpty) return;
    await _run(typeArgs(text));
  }

  /// Modifier keys released (and not restored) before typing.
  static const typeReleases = [
    'Shift_L',
    'Shift_R',
    'Control_L',
    'Control_R',
    'Alt_L',
    'Alt_R',
    'Super_L',
    'Super_R',
    'ISO_Level3_Shift',
  ];

  /// xdotool arguments for [typeText]. Not `type --clearmodifiers`: that saves
  /// and *restores* every active modifier, Caps Lock and held mouse button
  /// around the text (re-pressing them afterwards), which injected stray key
  /// events into the target (QA saw `2⌫Hello, world`) and can leave a button
  /// stuck after a click. Plain key-ups of the modifiers give clean text.
  static List<String> typeArgs(String text) => ['keyup', ...typeReleases, 'type', '--delay', '12', '--', text];

  @override
  Future<void> keyCombo(String combo) async {
    final keys = combo.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).map(normalizeKeyCombo).toList();
    if (keys.isEmpty) return;
    await _run(['key', '--clearmodifiers', ...keys]);
  }

  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    if (keys == null && action == null) throw ArgumentError('keys or action required');
    final List<KeyChord>? parsed = keys == null ? null : parseKeySequence(keys);
    final (win, active) = await targets.resolve(target);
    final chords = parsed ?? chordsForAction(action!, windowClass: win.wmClass);
    final needsFocus = active?.id != win.id;
    final restore = needsFocus && active != null && targets.isWoi(active) && shouldRestoreFocus(chords);
    await _run(sendKeysArgs(chords, activate: needsFocus ? win.id : null, restore: restore ? active.id : null));
    if (!needsFocus || !restore) targets.remembered = win.id;
    return SendKeysResult(
      chords: chords,
      windowTitle: win.title,
      windowClass: win.wmClass,
      windowId: win.id,
      activated: needsFocus,
    );
  }

  @override
  Future<void> rememberTargetWindow() async {
    try {
      await targets.remember();
    } catch (_) {
      // No xdotool / X: send_keys reports the problem when used.
    }
  }

  @override
  Future<Point<int>> mouseLocation() async {
    final out = await _run(['getmouselocation', '--shell']);
    final x = RegExp(r'X=(\d+)').firstMatch(out);
    final y = RegExp(r'Y=(\d+)').firstMatch(out);
    if (x == null || y == null) {
      throw CommandFailed('xdotool getmouselocation', 0, 'unparseable: $out');
    }
    return Point(int.parse(x[1]!), int.parse(y[1]!));
  }
}

const _keyAliases = {
  'ctrl': 'ctrl',
  'control': 'ctrl',
  'shift': 'shift',
  'alt': 'alt',
  'option': 'alt',
  'super': 'super',
  'win': 'super',
  'meta': 'super',
  'cmd': 'super',
  'command': 'super',
  'enter': 'Return',
  'return': 'Return',
  'esc': 'Escape',
  'escape': 'Escape',
  'tab': 'Tab',
  'space': 'space',
  'backspace': 'BackSpace',
  'delete': 'Delete',
  'del': 'Delete',
  'insert': 'Insert',
  'home': 'Home',
  'end': 'End',
  'pageup': 'Prior',
  'pgup': 'Prior',
  'pagedown': 'Next',
  'pgdn': 'Next',
  'up': 'Up',
  'down': 'Down',
  'left': 'Left',
  'right': 'Right',
  'plus': 'plus',
  'minus': 'minus',
  'printscreen': 'Print',
  'print': 'Print',
};

/// Converts friendly names ("Ctrl+Shift+Enter") to xdotool keysyms.
String normalizeKeyCombo(String combo) {
  return combo
      .split('+')
      .where((s) => s.isNotEmpty)
      .map((k) {
        final lower = k.toLowerCase();
        final alias = _keyAliases[lower];
        if (alias != null) return alias;
        if (RegExp(r'^f([1-9]|1[0-9]|2[0-4])$').hasMatch(lower)) {
          return lower.toUpperCase();
        }
        return k.length == 1 ? k.toLowerCase() : k;
      })
      .join('+');
}
