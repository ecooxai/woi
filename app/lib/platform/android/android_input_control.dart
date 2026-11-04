import 'dart:math';

import 'package:flutter/services.dart';

import '../input_control.dart';
import 'android_bridge.dart';

/// What an Android key chord does through the accessibility service.
sealed class AndroidKeyOp {
  const AndroidKeyOp(this.name);
  final String name;
}

/// performGlobalAction: back, home, recents, notifications.
class GlobalKeyOp extends AndroidKeyOp {
  const GlobalKeyOp(super.name);
}

/// Action on the focused node: copy, paste, cut, select_all, enter.
class NodeKeyOp extends AndroidKeyOp {
  const NodeKeyOp(super.name);
}

/// Maps a chord to an accessibility action, or null when Android has no
/// equivalent (arbitrary letters, function keys, ...).
AndroidKeyOp? androidOpForChord(KeyChord c) {
  final m = c.modifiers;
  final ctrl = m.contains(KeyModifier.ctrl) || m.contains(KeyModifier.superKey);
  if (ctrl && !m.contains(KeyModifier.alt)) {
    switch (c.key) {
      case 'c':
        return const NodeKeyOp('copy');
      case 'v':
        return const NodeKeyOp('paste');
      case 'x':
        return const NodeKeyOp('cut');
      case 'a':
        return const NodeKeyOp('select_all');
    }
  }
  if (m.contains(KeyModifier.alt) && c.key == 'tab') return const GlobalKeyOp('recents');
  if (m.contains(KeyModifier.alt) && c.key == 'left') return const GlobalKeyOp('back');
  if (m.isNotEmpty) return null;
  return switch (c.key) {
    'escape' => const GlobalKeyOp('back'),
    'enter' => const NodeKeyOp('enter'),
    'home' => const GlobalKeyOp('home'),
    'super' => const GlobalKeyOp('home'),
    _ => null,
  };
}

AndroidKeyOp androidOpForAction(KeyAction a) => switch (a) {
  KeyAction.copy => const NodeKeyOp('copy'),
  KeyAction.paste => const NodeKeyOp('paste'),
  KeyAction.cut => const NodeKeyOp('cut'),
  KeyAction.selectAll => const NodeKeyOp('select_all'),
  KeyAction.enter => const NodeKeyOp('enter'),
  KeyAction.escape || KeyAction.back => const GlobalKeyOp('back'),
  KeyAction.undo || KeyAction.redo => throw UnsupportedError('${a.wire} has no accessibility action on Android'),
};

/// Spoken names that only make sense on a phone ("recents", "home screen").
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
  _ => null,
};

/// click_screen / type_text / send_keys through WoiAccessibilityService.
/// Coordinates are real screen pixels (screenshots map back with
/// [Screenshot.toScreen]). If Woi is in front, the service sends it to the
/// back first so the action lands in the app below.
class AndroidInputControl implements InputControl {
  AndroidInputControl({AndroidBridge? bridge}) : _bridge = bridge ?? AndroidBridge.instance;

  final AndroidBridge _bridge;
  Point<int> _last = const Point(0, 0);

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _bridge.call<T>(method, args);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<void> moveMouse(int x, int y) async => _last = Point(x, y);

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left}) async {
    _last = Point(x, y);
    await _call<bool>('click', {'x': x, 'y': y});
  }

  @override
  Future<void> doubleClick(int x, int y, {MouseButton button = MouseButton.left}) async {
    _last = Point(x, y);
    await _call<bool>('doubleClick', {'x': x, 'y': y});
  }

  @override
  Future<void> typeText(String text) async {
    if (text.isEmpty) return;
    await _call<String>('typeText', {'text': text});
  }

  Future<void> _run(AndroidKeyOp op) async {
    if (op is GlobalKeyOp) {
      final ok = await _call<bool>('global', {'name': op.name});
      if (ok != true) throw StateError('${op.name} was refused');
    } else {
      await _call<String>('node', {'name': op.name});
    }
  }

  List<AndroidKeyOp> _opsFor(List<KeyChord> chords) => [
    for (final c in chords)
      androidOpForChord(c) ??
          (throw UnsupportedError(
            'Android cannot press "$c". Supported: back/esc, home, recents (alt+tab), enter, '
            'copy (ctrl+c), paste (ctrl+v), cut (ctrl+x), select all (ctrl+a).',
          )),
  ];

  @override
  Future<void> keyCombo(String combo) async {
    final named = androidOpForName(combo);
    if (named != null) return _run(named);
    for (final op in _opsFor(parseKeySequence(combo))) {
      await _run(op);
    }
  }

  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    if (keys == null && action == null) throw ArgumentError('keys or action required');
    final List<AndroidKeyOp> ops;
    final List<KeyChord> chords;
    final named = keys == null ? null : androidOpForName(keys);
    if (named != null) {
      ops = [named];
      chords = [KeyChord(named.name.replaceAll('_', ''))];
    } else if (keys != null) {
      chords = parseKeySequence(keys);
      ops = _opsFor(chords);
    } else {
      ops = [androidOpForAction(action!)];
      chords = chordsForAction(action);
    }
    for (final op in ops) {
      await _run(op);
    }
    String? pkg;
    try {
      pkg = (await _call<Map<Object?, Object?>>('focusTarget'))?['package'] as String?;
    } catch (_) {}
    return SendKeysResult(chords: chords, windowClass: pkg, windowTitle: pkg);
  }

  @override
  Future<void> rememberTargetWindow() async {}

  @override
  Future<Point<int>> mouseLocation() async => _last;
}
