import 'dart:math';

enum MouseButton { left, middle, right }

/// Synthetic mouse/keyboard input, in real screen coordinates.
abstract class InputControl {
  Future<void> moveMouse(int x, int y);
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left});
  Future<void> doubleClick(int x, int y,
      {MouseButton button = MouseButton.left});
  Future<void> typeText(String text);

  /// One or more combos separated by spaces, e.g. `ctrl+shift+t` or
  /// `ctrl+a ctrl+c`. Modifier names: ctrl, shift, alt, super.
  Future<void> keyCombo(String combo);

  Future<Point<int>> mouseLocation();
}
