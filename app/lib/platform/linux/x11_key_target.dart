import 'dart:io';

import '../key_chords.dart';
import 'exec_util.dart';

/// A top-level X11 client window.
class X11Window {
  const X11Window({
    required this.id,
    this.title = '',
    this.wmClass = '',
    this.pid,
    this.hidden = false,
    this.special = false,
  });

  /// Window id as xdotool accepts it (decimal).
  final String id;
  final String title;

  /// WM_CLASS instance and class, joined by a space ("xterm XTerm").
  final String wmClass;
  final int? pid;

  /// Minimized / not viewable.
  final bool hidden;

  /// Dock, desktop or similar (never a key target).
  final bool special;

  @override
  String toString() => '$id "$title" [$wmClass]';
}

/// The window queries `send_keys` needs (faked in tests).
abstract class X11Windows {
  Future<String?> activeId();

  /// Client windows, topmost first.
  Future<List<String>> stackingTopFirst();
  Future<X11Window?> info(String id);
}

/// Picks the window `send_keys` targets. Woi's own windows (this process,
/// or WM_CLASS woi) are never the default target.
class KeyTargetResolver {
  KeyTargetResolver(this.x, {int? selfPid}) : selfPid = selfPid ?? pid;

  final X11Windows x;
  final int selfPid;

  /// Focused non-Woi window at the start of the latest turn.
  String? remembered;

  bool isWoi(X11Window w) => w.pid == selfPid || RegExp(r'\bwoi\b', caseSensitive: false).hasMatch(w.wmClass);

  bool _usable(X11Window? w) => w != null && !w.special && !w.hidden && !isWoi(w);

  /// Remembers the active window if it is not Woi.
  Future<void> remember() async {
    final id = await x.activeId();
    if (id == null) return;
    final w = await x.info(id);
    if (_usable(w)) remembered = id;
  }

  /// The target window and the currently active one (to know whether the
  /// target must be focused first, and where focus goes back).
  Future<(X11Window target, X11Window? active)> resolve(KeyTarget t) async {
    final activeId = await x.activeId();
    final active = activeId == null ? null : await x.info(activeId);
    if (!t.isDefault) {
      final want = t.window!.trim().toLowerCase();
      bool matches(X11Window w) => w.title.toLowerCase().contains(want) || w.wmClass.toLowerCase().contains(want);
      if (active != null && _usable(active) && matches(active)) return (active, active);
      for (final id in await x.stackingTopFirst()) {
        final w = await x.info(id);
        if (w != null && !w.special && !isWoi(w) && matches(w)) return (w, active);
      }
      throw StateError('no window matching "${t.window}"');
    }
    if (_usable(active)) return (active!, active);
    final r = remembered;
    if (r != null) {
      final w = await x.info(r);
      if (_usable(w)) return (w!, active);
      remembered = null;
    }
    for (final id in await x.stackingTopFirst()) {
      final w = await x.info(id);
      if (_usable(w)) return (w!, active);
    }
    throw StateError('no window to send keys to (only Woi is open)');
  }
}

/// [X11Windows] over xdotool and xprop.
class XpropWindows implements X11Windows {
  XpropWindows({Map<String, String>? environment}) : env = environment ?? x11Env();
  final Map<String, String> env;

  Future<ProcessResult?> _run(String tool, List<String> args) async {
    final exe = which(tool);
    if (exe == null) throw MissingTool([tool]);
    final r = await Process.run(exe, args, environment: env);
    return r.exitCode == 0 ? r : null;
  }

  @override
  Future<String?> activeId() async {
    final r = await _run('xdotool', ['getactivewindow']);
    final id = '${r?.stdout ?? ''}'.trim();
    return int.tryParse(id) == null ? null : id;
  }

  @override
  Future<List<String>> stackingTopFirst() async {
    final r = await _run('xprop', ['-root', '_NET_CLIENT_LIST_STACKING']);
    return parseStacking('${r?.stdout ?? ''}');
  }

  /// `_NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x1, 0x2` -> decimal
  /// ids, topmost (last in the list) first.
  static List<String> parseStacking(String out) => [
    for (final m in RegExp(r'0x[0-9a-fA-F]+').allMatches(out)) '${int.parse(m[0]!.substring(2), radix: 16)}',
  ].reversed.toList();

  @override
  Future<X11Window?> info(String id) async {
    final r = await _run('xprop', [
      '-id',
      id,
      'WM_CLASS',
      '_NET_WM_PID',
      '_NET_WM_NAME',
      'WM_NAME',
      '_NET_WM_WINDOW_TYPE',
      '_NET_WM_STATE',
      'WM_STATE',
    ]);
    if (r == null) return null;
    return parseXprop(id, '${r.stdout}');
  }

  static X11Window parseXprop(String id, String out) {
    String? line(String prop) {
      for (final l in out.split('\n')) {
        if (l.startsWith('$prop(') || l.startsWith('$prop:')) return l;
      }
      return null;
    }

    List<String> quoted(String? l) => l == null ? const [] : [for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(l)) m[1]!];
    final title = quoted(line('_NET_WM_NAME')).firstOrNull ?? quoted(line('WM_NAME')).firstOrNull ?? '';
    final cls = quoted(line('WM_CLASS')).join(' ');
    final pidLine = line('_NET_WM_PID');
    final pid = pidLine == null ? null : int.tryParse(RegExp(r'=\s*(\d+)').firstMatch(pidLine)?[1] ?? '');
    final type = line('_NET_WM_WINDOW_TYPE') ?? '';
    final state = line('_NET_WM_STATE') ?? '';
    final wmState = out.split('\n').where((l) => l.contains('window state:')).firstOrNull ?? '';
    return X11Window(
      id: id,
      title: title,
      wmClass: cls,
      pid: pid,
      hidden: state.contains('_NET_WM_STATE_HIDDEN') || wmState.contains('Iconic') || wmState.contains('Withdrawn'),
      special: RegExp(r'_NET_WM_WINDOW_TYPE_(DOCK|DESKTOP|SPLASH|NOTIFICATION|TOOLTIP)').hasMatch(type),
    );
  }
}

const _keysyms = {
  'enter': 'Return',
  'escape': 'Escape',
  'tab': 'Tab',
  'space': 'space',
  'backspace': 'BackSpace',
  'delete': 'Delete',
  'insert': 'Insert',
  'home': 'Home',
  'end': 'End',
  'pageup': 'Prior',
  'pagedown': 'Next',
  'up': 'Up',
  'down': 'Down',
  'left': 'Left',
  'right': 'Right',
  'plus': 'plus',
  'minus': 'minus',
  'period': 'period',
  'comma': 'comma',
  'slash': 'slash',
  'backslash': 'backslash',
  'semicolon': 'semicolon',
  'equal': 'equal',
  'print': 'Print',
  'menu': 'Menu',
  'capslock': 'Caps_Lock',
  'ctrl': 'Control_L',
  'shift': 'Shift_L',
  'alt': 'Alt_L',
  'super': 'Super_L',
};

/// xdotool keysym chord for [c] ("ctrl+shift+t", "Return").
String xdotoolChord(KeyChord c) {
  final key = _keysyms[c.key] ?? (RegExp(r'^f\d+$').hasMatch(c.key) ? c.key.toUpperCase() : c.key);
  return [
    if (c.modifiers.contains(KeyModifier.ctrl)) 'ctrl',
    if (c.modifiers.contains(KeyModifier.shift)) 'shift',
    if (c.modifiers.contains(KeyModifier.alt)) 'alt',
    if (c.modifiers.contains(KeyModifier.superKey)) 'super',
    key,
  ].join('+');
}

/// Modifier keys released before and after the chords. Plain key-ups, not
/// `--clearmodifiers` (which re-presses held modifiers afterwards and can
/// leave one stuck; see LinuxInputControl.typeArgs).
const kModifierReleases = [
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

/// One xdotool invocation for `send_keys`: optionally focus [activate]
/// (and wait for it), release modifiers, press the chords, release
/// modifiers again, optionally focus [restore] afterwards.
List<String> sendKeysArgs(List<KeyChord> chords, {String? activate, String? restore}) => [
  if (activate != null) ...['windowactivate', '--sync', activate, 'sleep', '0.08'],
  'keyup',
  ...kModifierReleases,
  'key',
  '--delay',
  '40',
  ...chords.map(xdotoolChord),
  'keyup',
  ...kModifierReleases,
  if (restore != null) ...['sleep', '0.05', 'windowactivate', restore],
];

/// Whether focus should go back to Woi after the keys: not when the keys
/// themselves switch windows (alt+tab, super).
bool shouldRestoreFocus(List<KeyChord> chords) => !chords.any(
  (c) =>
      (c.modifiers.contains(KeyModifier.alt) && c.key == 'tab') ||
      c.modifiers.contains(KeyModifier.superKey) ||
      c.key == 'super',
);
