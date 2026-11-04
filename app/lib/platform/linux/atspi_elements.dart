import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dbus/dbus.dart';

import '../../core/vision/ui_elements.dart';
import 'x11_key_target.dart';

/// AT-SPI roles worth clicking (atspi-constants.h AtspiRole values).
const kAtspiClickableRoles = <int>{
  7, // check box
  8, // check menu item
  11, // combo box
  26, // icon
  32, // list item
  33, // menu
  35, // menu item
  37, // page tab
  40, // password text
  43, // push button
  44, // radio button
  45, // radio menu item
  51, // slider
  52, // spin button
  56, // table cell
  61, // text
  62, // toggle button
  79, // entry
  88, // link
  91, // tree item
  129, // push button menu
  130, // switch
};

const _stateShowing = 25, _stateVisible = 30;
const _matchAll = 1, _matchAny = 2;
const _rootPath = '/org/a11y/atspi/accessible/root';
const _iAccessible = 'org.a11y.atspi.Accessible';

/// Bit set over [values] as AT-SPI sends it (int32 words, low bit first).
List<int> atspiBitSet(Iterable<int> values, {int words = 2}) {
  final out = List<int>.filled(words, 0);
  for (final v in values) {
    out[v ~/ 32] |= 1 << (v % 32);
  }
  // DBus int32: wrap to signed.
  return [for (final w in out) w >= 0x80000000 ? w - 0x100000000 : w];
}

/// Normalized role name for [UiElement.role] ("push button" -> button).
String atspiRole(String roleName) => switch (roleName) {
  'push button' || 'push button menu' => 'button',
  'text' || 'password text' => 'entry',
  _ => roleName,
};

/// Clickable elements of the frontmost (non-Woi) application, read over the
/// AT-SPI bus with Collection.GetMatches (one call per app; GTK and Chromium
/// support it). Works without root; needs accessibility on (GNOME/KDE: on
/// by default for Chromium only with a screen reader or
/// --force-renderer-accessibility; Qt: QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1).
class AtspiElementSource implements ElementSource {
  AtspiElementSource({Future<Set<int>> Function()? targetPids, this.maxElements = 800})
    : targetPids = targetPids ?? frontWindowPids;

  /// Processes whose elements count (default: [frontWindowPids]).
  final Future<Set<int>> Function() targetPids;
  final int maxElements;

  DBusClient? _bus;
  final _pidOf = <String, int?>{};

  Future<DBusClient> _client() async {
    final c = _bus;
    if (c != null) return c;
    var addr = Platform.environment['AT_SPI_BUS_ADDRESS'];
    if (addr == null || addr.isEmpty) {
      final session = DBusClient.session();
      try {
        final r = await session.callMethod(
          destination: 'org.a11y.Bus',
          path: DBusObjectPath('/org/a11y/bus'),
          interface: 'org.a11y.Bus',
          name: 'GetAddress',
          replySignature: DBusSignature('s'),
        );
        addr = r.values.first.asString();
      } finally {
        await session.close();
      }
    }
    return _bus = DBusClient(DBusAddress(addr));
  }

  Future<void> close() async {
    await _bus?.close();
    _bus = null;
  }

  Future<List<(String, String)>> _children(DBusClient c, String dest, String path) async {
    final r = await c.callMethod(
      destination: dest,
      path: DBusObjectPath(path),
      interface: _iAccessible,
      name: 'GetChildren',
      replySignature: DBusSignature('a(so)'),
    );
    return _refs(r.values.first);
  }

  static List<(String, String)> _refs(DBusValue v) => [
    for (final s in v.asArray()) (s.asStruct()[0].asString(), s.asStruct()[1].asObjectPath().value),
  ];

  Future<int?> _pid(DBusClient c, String name) async {
    if (_pidOf.containsKey(name)) return _pidOf[name];
    int? pid;
    try {
      final r = await c.callMethod(
        destination: 'org.freedesktop.DBus',
        path: DBusObjectPath('/org/freedesktop/DBus'),
        interface: 'org.freedesktop.DBus',
        name: 'GetConnectionUnixProcessID',
        values: [DBusString(name)],
        replySignature: DBusSignature('u'),
      );
      pid = r.values.first.asUint32();
    } catch (_) {}
    return _pidOf[name] = pid;
  }

  @override
  Future<List<UiElement>> elements() async {
    final c = await _client();
    final List<(String, String)> apps;
    try {
      apps = await _children(c, 'org.a11y.atspi.Registry', _rootPath);
    } catch (_) {
      // The bus went away (session restart): reconnect next time.
      await close();
      rethrow;
    }
    final want = await targetPids();
    final out = <UiElement>[];
    for (final (name, path) in apps) {
      final pid = await _pid(c, name);
      if (pid == null || !want.contains(pid)) continue;
      out.addAll(await _appElements(c, name, path));
      if (out.length >= maxElements) break;
    }
    return out;
  }

  Future<List<UiElement>> _appElements(DBusClient c, String dest, String root) async {
    final rule = DBusStruct([
      DBusArray.int32(atspiBitSet([_stateShowing, _stateVisible])),
      const DBusInt32(_matchAll),
      DBusDict(DBusSignature('s'), DBusSignature('s')),
      const DBusInt32(_matchAll),
      DBusArray.int32(atspiBitSet(kAtspiClickableRoles, words: 5)),
      const DBusInt32(_matchAny),
      DBusArray.string(const []),
      const DBusInt32(_matchAll),
      const DBusBoolean(false),
    ]);
    final r = await c.callMethod(
      destination: dest,
      path: DBusObjectPath(root),
      interface: 'org.a11y.atspi.Collection',
      name: 'GetMatches',
      values: [rule, const DBusUint32(1), DBusInt32(maxElements), const DBusBoolean(true)],
      replySignature: DBusSignature('a(so)'),
    );
    final refs = _refs(r.values.first);
    final els = await Future.wait(refs.map((ref) => _element(c, ref.$1, ref.$2)));
    return [for (final e in els) ?e];
  }

  Future<UiElement?> _element(DBusClient c, String dest, String path) async {
    try {
      final p = DBusObjectPath(path);
      final res = await Future.wait([
        c.callMethod(
          destination: dest,
          path: p,
          interface: _iAccessible,
          name: 'GetRoleName',
          replySignature: DBusSignature('s'),
        ),
        c.callMethod(
          destination: dest,
          path: p,
          interface: 'org.freedesktop.DBus.Properties',
          name: 'Get',
          values: [const DBusString(_iAccessible), const DBusString('Name')],
          replySignature: DBusSignature('v'),
        ),
        c.callMethod(
          destination: dest,
          path: p,
          interface: 'org.a11y.atspi.Component',
          name: 'GetExtents',
          values: [const DBusUint32(0)],
          replySignature: DBusSignature('(iiii)'),
        ),
      ]);
      final ext = res[2].values.first.asStruct().map((v) => v.asInt32()).toList();
      if (ext[2] <= 1 || ext[3] <= 1 || ext[0] < -10 || ext[1] < -10) return null;
      return UiElement(
        role: atspiRole(res[0].values.first.asString()),
        name: res[1].values.first.asVariant().asString().trim(),
        bounds: Rectangle(ext[0], ext[1], ext[2], ext[3]),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Pid of the topmost usable (not Woi, not hidden) X11 window: the app the
/// user is looking at.
Future<Set<int>> frontWindowPids() async {
  final x = XpropWindows();
  final r = KeyTargetResolver(x);
  for (final id in await x.stackingTopFirst()) {
    final w = await x.info(id);
    if (w == null || w.hidden || w.special || r.isWoi(w) || w.pid == null) continue;
    return {w.pid!};
  }
  return {};
}
