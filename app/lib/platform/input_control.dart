import 'dart:math';

import 'key_chords.dart';

export 'key_chords.dart';

enum MouseButton { left, middle, right }

/// Synthetic mouse/keyboard input, in real screen coordinates.
abstract class InputControl {
  Future<void> moveMouse(int x, int y);
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left});
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left});
  Future<void> typeText(String text);

  /// One or more combos separated by spaces, e.g. `ctrl+shift+t` or
  /// `ctrl+a ctrl+c`. Modifier names: ctrl, shift, alt, super.
  Future<void> keyCombo(String combo);

  Future<Point<int>> mouseLocation();

  /// `send_keys`: presses [keys] (see [parseKeySequence]) or the keys of an
  /// edit [action] (mapped per target app, e.g. Ctrl+Shift+C in terminals)
  /// in [target]. The default target is the active window that is not Woi
  /// (else the window remembered at the start of the turn, else the
  /// topmost other window). Modifiers are released before and after, so
  /// none stays stuck. Android: AccessibilityService actions.
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()});

  /// Called when a user turn starts: remembers the focused window if it is
  /// not Woi, as the default `send_keys` target.
  Future<void> rememberTargetWindow();
}
