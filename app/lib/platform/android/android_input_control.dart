import 'dart:math';

import 'package:flutter/services.dart';

import '../input_control.dart';
import '../control_feedback.dart';
import 'android_bridge.dart';

/// What an Android key request does through the accessibility service.
sealed class AndroidKeyOp {
  const AndroidKeyOp(this.name);
  final String name;
  Map<String, Object?> get wire;
}

/// Public system navigation actions (phone Home, Back, recents).
class GlobalKeyOp extends AndroidKeyOp {
  const GlobalKeyOp(super.name);
  @override
  Map<String, Object?> get wire => {'type': 'global', 'name': name};
}

/// A semantic edit intent, independent of an app's physical key bindings.
class NodeKeyOp extends AndroidKeyOp {
  const NodeKeyOp(super.name);
  @override
  Map<String, Object?> get wire => {'type': 'edit', 'name': name};
}

/// An exact chord, including every modifier, delivered through the public
/// accessibility input connection on Android 13 or newer.
class RawKeyOp extends AndroidKeyOp {
  RawKeyOp(this.chord) : super(chord.toString());
  final KeyChord chord;
  @override
  Map<String, Object?> get wire => {
    'type': 'key',
    'key': chord.key,
    'modifiers': [
      for (final modifier in KeyModifier.values)
        if (chord.modifiers.contains(modifier)) modifier == KeyModifier.superKey ? 'super' : modifier.name,
    ],
  };
}

const _androidNamedKeys = {
  'enter',
  'escape',
  'tab',
  'space',
  'backspace',
  'delete',
  'insert',
  'home',
  'end',
  'pageup',
  'pagedown',
  'up',
  'down',
  'left',
  'right',
  'plus',
  'minus',
  'period',
  'comma',
  'slash',
  'backslash',
  'semicolon',
  'equal',
  'print',
  'menu',
  'capslock',
  'ctrl',
  'shift',
  'alt',
  'super',
  "'",
  '[',
  ']',
  '`',
};

/// Keeps established phone navigation aliases, while preserving additional
/// modifiers and exact Ctrl+C/V/X/A shortcuts (including terminal semantics).
AndroidKeyOp? androidOpForChord(KeyChord chord) {
  final modifiers = chord.modifiers;
  if (modifiers.length == 1 && modifiers.contains(KeyModifier.alt)) {
    if (chord.key == 'tab') return const GlobalKeyOp('recents');
    if (chord.key == 'left') return const GlobalKeyOp('back');
  }
  if (modifiers.isEmpty) {
    switch (chord.key) {
      case 'escape':
        return const GlobalKeyOp('back');
      case 'home':
        return const GlobalKeyOp('home');
      case 'enter':
        return const NodeKeyOp('enter');
    }
  }
  final key = chord.key;
  if (!_androidNamedKeys.contains(key) && !RegExp(r'^[a-z0-9]$|^f([1-9]|1[0-2])$').hasMatch(key)) {
    return null;
  }
  if (modifiers.isNotEmpty && const {'ctrl', 'shift', 'alt', 'super'}.contains(key)) {
    return null;
  }
  return RawKeyOp(chord);
}

AndroidKeyOp androidOpForAction(KeyAction action) => switch (action) {
  KeyAction.copy => const NodeKeyOp('copy'),
  KeyAction.paste => const NodeKeyOp('paste'),
  KeyAction.cut => const NodeKeyOp('cut'),
  KeyAction.selectAll => const NodeKeyOp('select_all'),
  KeyAction.enter => const NodeKeyOp('enter'),
  KeyAction.escape || KeyAction.back => const GlobalKeyOp('back'),
  KeyAction.undo => RawKeyOp(const KeyChord('z', {KeyModifier.ctrl})),
  KeyAction.redo => RawKeyOp(const KeyChord('z', {KeyModifier.ctrl, KeyModifier.shift})),
};

/// Spoken names that only make sense on a phone ("recents", "home screen"),
/// plus legacy semantic edit aliases.
AndroidKeyOp? androidOpForName(String keys) => switch (keys.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '')) {
  'back' => const GlobalKeyOp('back'),
  'home' || 'homescreen' => const GlobalKeyOp('home'),
  'recents' || 'recentapps' || 'overview' || 'appswitch' => const GlobalKeyOp('recents'),
  'notifications' => const GlobalKeyOp('notifications'),
  'quicksettings' => const GlobalKeyOp('quick_settings'),
  'selectall' => const NodeKeyOp('select_all'),
  'copy' => const NodeKeyOp('copy'),
  'paste' => const NodeKeyOp('paste'),
  'cut' => const NodeKeyOp('cut'),
  'undo' => androidOpForAction(KeyAction.undo),
  'redo' => androidOpForAction(KeyAction.redo),
  _ => null,
};

/// click_screen / type_text / send_keys through WoiAccessibilityService.
/// Coordinates are real screen pixels (screenshots map back with
/// [Screenshot.toScreen]). If Woi is in front, the service sends it to the
/// back first so the action lands in the app below.
class AndroidInputControl implements InputControl, AcknowledgedTextInput, ScreenScrollInput, TouchKeyboardInput {
  AndroidInputControl({AndroidBridge? bridge, this.control}) : _bridge = bridge ?? AndroidBridge.instance;

  final ControlGuard? control;
  ControlLease? _lease;

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

  final AndroidBridge _bridge;
  Point<int> _last = const Point(0, 0);

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      await _lease?.check();
      final result = await _bridge.call<T>(method, args);
      await _lease?.check();
      return result;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<void> moveMouse(int x, int y) => _visible(
    'pointer',
    () async {
      _last = Point(x, y);
      await _lease?.update(x: x, y: y);
    },
    x: x,
    y: y,
  );

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left}) async {
    if (button == MouseButton.middle) {
      throw UnsupportedError('Android supports a left tap or a right long press; middle click is unavailable');
    }
    _last = Point(x, y);
    await _visible(
      'pointer',
      () async {
        await _call<bool>('click', {'x': x, 'y': y, 'button': button.name});
      },
      x: x,
      y: y,
    );
  }

  @override
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left}) async {
    if (button != MouseButton.left) {
      throw UnsupportedError(
        'Android supports double tap only for the left button; use a right click for a long press',
      );
    }
    _last = Point(x, y);
    await _visible(
      'pointer',
      () async {
        await _call<bool>('doubleClick', {'x': x, 'y': y, 'button': button.name});
      },
      x: x,
      y: y,
    );
  }

  @override
  Future<Map<String, Object?>> scroll({
    required ScrollDirection direction,
    double amount = 1,
    Point<int>? at,
    String strategy = 'auto',
  }) async {
    if (!amount.isFinite || amount < 0.1 || amount > 5) {
      throw ArgumentError('Scroll amount must be between 0.1 and 5 viewports');
    }
    if (!const {'auto', 'gesture'}.contains(strategy)) {
      throw ArgumentError('Scroll strategy must be auto or gesture');
    }
    return _visible(
      'pointer',
      () async {
        final reply = await _call<Object?>('scroll', {
          'direction': direction.name,
          'amount': amount,
          'strategy': strategy,
          if (at != null) ...{'x': at.x, 'y': at.y},
        });
        if (reply is! Map ||
            reply['direction'] != direction.name ||
            reply['completed_amount'] is! num ||
            !(reply['completed_amount'] as num).isFinite ||
            ((reply['completed_amount'] as num) - amount).abs() > 0.0001 ||
            !const {'accepted', 'dispatched'}.contains(reply['delivery']) ||
            reply['backend'] is! String ||
            (reply['backend'] as String).isEmpty ||
            reply['scroll_event_observed'] is! bool) {
          throw StateError('Android did not acknowledge the complete scroll; do not retry automatically');
        }
        if (at != null) _last = at;
        return {
          for (final entry in reply.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
      },
      x: at?.x,
      y: at?.y,
      keys: 'Scroll ${direction.name}',
    );
  }

  @override
  Future<void> typeText(String text) async {
    await typeTextWithReceipt(text);
  }

  @override
  Future<TextInputReceipt> typeTextWithReceipt(String text) async {
    if (text.isEmpty) {
      return const TextInputReceipt(delivery: 'noop', backend: 'android_accessibility');
    }
    if (text.length > 100000) {
      throw ArgumentError('Text insertion is limited to 100000 UTF-16 units per request');
    }
    return _visible('keyboard', () async {
      final delivery = await _call<String>('typeText', {'text': text});
      return switch (delivery) {
        'ime_dispatched' => const TextInputReceipt(
          delivery: 'dispatched',
          backend: 'android_accessibility_input_connection',
        ),
        'set_text' => const TextInputReceipt(delivery: 'applied', backend: 'android_accessibility_action'),
        _ => throw StateError('Android did not acknowledge text insertion; do not retry automatically'),
      };
    }, keys: text);
  }

  /// Shows Woi's non-focusable touch keyboard without selecting an editor.
  /// Visibility and the receiving editor/input connection remain distinct.
  @override
  Future<Map<String, Object?>> showKeyboard() => _visible('keyboard', () async {
    final reply = await _call<Object?>('showKeyboard');
    if (reply is! Map || reply['requested'] is! bool || reply['visible'] is! bool || reply['focus_changed'] != false) {
      throw StateError('Android did not acknowledge a keyboard visibility request');
    }
    return {
      'requested': reply['requested'],
      'visible': reply['visible'],
      'focus_changed': false,
      for (final name in const [
        'backend',
        'package',
        'text_target',
        'text_input_available',
        'input_connection',
        'exact_keys_available',
        'navigation_without_editor',
      ])
        if (reply.containsKey(name)) name: reply[name],
    };
  }, keys: 'Show keyboard');

  @override
  Future<Map<String, Object?>> hideKeyboard() async {
    // Dismissal remains available after user takeover; it sends no input.
    final reply = await _bridge.call<Object?>('hideKeyboard');
    if (reply is! Map || reply['hidden'] != true || reply['visible'] != false) {
      throw StateError('Android did not acknowledge keyboard dismissal');
    }
    return {
      'hidden': true,
      'visible': false,
      'backend': 'woi_touch_keyboard',
      if (reply['system_keyboard_visible'] is bool) 'system_keyboard_visible': reply['system_keyboard_visible'],
    };
  }

  List<AndroidKeyOp> _opsFor(List<KeyChord> chords) => [
    for (final chord in chords)
      androidOpForChord(chord) ??
          (throw UnsupportedError(
            'Android cannot send "$chord". Use type_text for literal characters; function keys stop at F12.',
          )),
  ];

  void _validateOps(List<AndroidKeyOp> ops, KeyTarget target) {
    if (ops.isEmpty || ops.length > 64) {
      throw ArgumentError('Send between 1 and 64 keyboard operations');
    }
    final hasGlobal = ops.any((op) => op is GlobalKeyOp);
    if (hasGlobal && ops.any((op) => op is! GlobalKeyOp)) {
      throw UnsupportedError('Send Android system navigation and editor shortcuts in separate requests');
    }
    if (hasGlobal && !target.isDefault) {
      throw UnsupportedError('Android system navigation cannot target a named application');
    }
  }

  Future<Map<Object?, Object?>> _dispatch(List<AndroidKeyOp> ops, KeyTarget target) async {
    final receipt = await _call<Object?>('sendKeys', {
      'operations': [for (final op in ops) op.wire],
      if (!target.isDefault) 'target': target.window!.trim(),
    });
    if (receipt is! Map<Object?, Object?> ||
        receipt['completed'] != ops.length ||
        !const {'applied', 'dispatched'}.contains(receipt['delivery']) ||
        receipt['backend'] is! String) {
      throw StateError('Android did not acknowledge the complete keyboard request; do not retry automatically');
    }
    return receipt;
  }

  @override
  Future<void> keyCombo(String combo) async {
    final named = androidOpForName(combo);
    final ops = named == null ? _opsFor(parseKeySequence(combo)) : [named];
    const target = KeyTarget();
    _validateOps(ops, target);
    await _visible('keyboard', () async {
      await _dispatch(ops, target);
    }, keys: combo);
  }

  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    if ((keys == null) == (action == null)) {
      throw ArgumentError('Provide exactly one of keys or action');
    }
    final List<AndroidKeyOp> ops;
    final List<KeyChord> chords;
    final named = keys == null ? null : androidOpForName(keys);
    if (named != null) {
      ops = [named];
      chords = named is RawKeyOp ? [named.chord] : [KeyChord(named.name.replaceAll('_', ''))];
    } else if (keys != null) {
      chords = parseKeySequence(keys);
      ops = _opsFor(chords);
    } else {
      ops = [androidOpForAction(action!)];
      chords = chordsForAction(action);
    }
    _validateOps(ops, target);
    final receipt = await _visible('keyboard', () => _dispatch(ops, target), keys: keys ?? action?.wire ?? '');
    final package = receipt['package'] as String?;
    return SendKeysResult(
      chords: chords,
      windowClass: package,
      windowTitle: package,
      delivery: receipt['delivery'] as String,
      backend: receipt['backend'] as String,
    );
  }

  @override
  Future<void> rememberTargetWindow() async {
    // Invalidate Dart's generation synchronously. A handled Apply may queue
    // its approved continuation as soon as this call yields.
    final reset = control?.reset();
    try {
      // Bypass _call: the active lease was just cancelled, so its check would
      // prevent the native Stop signal. Native reset itself waits behind the
      // current batch; this separate signal invalidates its delayed callbacks.
      await _bridge.call<Object?>('cancelKeyboard');
    } catch (_) {
      // A detached/unavailable service cannot accept this best-effort signal.
      // The queued guard reset still runs and remains fail-closed on failure.
    }
    await reset;
  }

  @override
  Future<Point<int>> mouseLocation() async => _last;
}
