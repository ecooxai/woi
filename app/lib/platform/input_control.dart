import 'dart:math';

import 'key_chords.dart';

export 'key_chords.dart';

enum MouseButton { left, middle, right }

/// What the platform can actually acknowledge about literal text insertion.
/// Dispatched input may still be ignored by the receiving editor. Applied
/// means its supported edit action acknowledged the change; noop sends nothing.
class TextInputReceipt {
  const TextInputReceipt({required this.delivery, required this.backend});

  final String delivery;
  final String backend;

  Map<String, Object?> toJson() => {'delivery': delivery, 'backend': backend};
}

/// Optional richer input contract. Existing InputControl implementations and
/// callers keep the asynchronous typeText API without inventing acknowledgment.
abstract interface class AcknowledgedTextInput {
  Future<TextInputReceipt> typeTextWithReceipt(String text);
}

enum ScrollDirection { up, down, left, right }

/// Optional viewport scrolling capability. Direction names where to read
/// next (down reveals later content); the platform owns the opposite gesture.
abstract interface class ScreenScrollInput {
  Future<Map<String, Object?>> scroll({
    required ScrollDirection direction,
    double amount = 1,
    Point<int>? at,
    String strategy = 'auto',
  });
}

/// A real touch keyboard can be visible without a receiving text editor.
/// Its receipt reports those two capabilities independently.
abstract interface class TouchKeyboardInput {
  Future<Map<String, Object?>> showKeyboard();
  Future<Map<String, Object?>> hideKeyboard();
}

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
