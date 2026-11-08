import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../control_feedback.dart';

import '../input_control.dart';
import 'exec_util.dart';
import 'x11_key_target.dart';

/// X11 input injection through xdotool.
class LinuxInputControl implements InputControl {
  LinuxInputControl({X11Windows? windows, this.control}) : targets = KeyTargetResolver(windows ?? XpropWindows());

  final ControlGuard? control;
  ControlLease? _lease;

  /// Default `send_keys` target selection (active / remembered non-Woi window).
  final KeyTargetResolver targets;

  String get _xdo => which('xdotool') ?? (throw MissingTool(['xdotool']));

  Future<String> _run(List<String> args) async {
    final lease = _lease;
    if (lease == null) {
      final r = await runChecked(_xdo, args, environment: x11Env());
      return '${r.stdout}';
    }
    await lease.check();
    final process = await Process.start(_xdo, args, environment: x11Env());
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final exit = process.exitCode;
    final code = await Future.any<int?>([exit, lease.whenCancelled.then((_) => null)]);
    if (code == null || lease.cancelled) {
      process.kill(ProcessSignal.sigkill);
      await exit;
      await Future.wait([stdout, stderr]);
      // Do not restore user's modifiers after a takeover.
      try {
        await runChecked(_xdo, ['keyup', ...typeReleases], environment: x11Env());
      } catch (_) {
        // Preserve takeover even if the target/display disappeared.
      }
      throw const ControlInterrupted();
    }
    final output = await stdout;
    final error = await stderr;
    if (code != 0) throw CommandFailed('xdotool', code, error);
    await lease.check();
    return output;
  }

  Future<T> _visible<T>(String kind, Future<T> Function() action, {String keys = '', int? x, int? y}) async {
    if (control == null) return action();
    return control!.run(
      kind,
      (lease) async {
        _lease = lease;
        try {
          return await action();
        } finally {
          _lease = null;
        }
      },
      keys: keys,
      x: x,
      y: y,
    );
  }

  static String _button(MouseButton b) => switch (b) {
    MouseButton.left => '1',
    MouseButton.middle => '2',
    MouseButton.right => '3',
  };

  @override
  Future<void> moveMouse(int x, int y) => _visible(
    'pointer',
    () async {
      await _run(['mousemove', '--sync', '$x', '$y']);
    },
    x: x,
    y: y,
  );

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left}) => _visible(
    'pointer',
    () async {
      await _run(['mousemove', '--sync', '$x', '$y']);
      await _lease?.update(button: button.name);
      await _run(['click', _button(button)]);
    },
    x: x,
    y: y,
  );

  @override
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left}) => _visible(
    'pointer',
    () async {
      await _run(['mousemove', '--sync', '$x', '$y']);
      await _lease?.update(button: button.name);
      await _run(['click', '--repeat', '2', '--delay', '80', _button(button)]);
    },
    x: x,
    y: y,
  );

  @override
  Future<void> typeText(String text) async {
    if (text.isEmpty) return;
    await _visible('keyboard', () async {
      await _run(typeArgs(text));
    }, keys: text);
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
    if (combo.trim().isEmpty) return;
    final chords = parseKeySequence(combo);
    await _visible('keyboard', () async {
      await _run(sendKeysArgs(chords));
    }, keys: chords.join(' '));
  }

  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    if (keys == null && action == null) {
      throw ArgumentError('keys or action required');
    }
    final List<KeyChord>? parsed = keys == null ? null : parseKeySequence(keys);
    final (win, active) = await targets.resolve(target);
    final chords = parsed ?? chordsForAction(action!, windowClass: win.wmClass);
    final needsFocus = active?.id != win.id;
    final restore = needsFocus && active != null && targets.isWoi(active) && shouldRestoreFocus(chords);
    await _visible('keyboard', () async {
      await _run(sendKeysArgs(chords, activate: needsFocus ? win.id : null, restore: restore ? active.id : null));
    }, keys: chords.join(' '));
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
    await control?.reset();
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

/// Converts one friendly chord through the same parser as [InputControl.sendKeys].
String normalizeKeyCombo(String combo) {
  final chords = parseKeySequence(combo);
  if (chords.length != 1) throw const FormatException('give one key chord');
  return xdotoolChord(chords.single);
}
