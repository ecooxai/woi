import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/platform/key_chords.dart';
import 'package:woi/platform/linux/x11_key_target.dart';
import 'package:woi/tools/send_keys_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

class FakeWindows implements X11Windows {
  FakeWindows(this.windows, {this.active});
  final Map<String, X11Window> windows;
  String? active;

  /// Topmost first.
  List<String> stack = [];

  @override
  Future<String?> activeId() async => active;
  @override
  Future<X11Window?> info(String id) async => windows[id];
  @override
  Future<List<String>> stackingTopFirst() async => stack;
}

const _woiPid = 4242;

void main() {
  group('parseKeySequence', () {
    String p(String s) => parseKeySequence(s).join(' ');

    test('combos and named keys', () {
      expect(p('ctrl+c'), 'ctrl+c');
      expect(p('Ctrl+Shift+T'), 'ctrl+shift+t');
      expect(p('esc'), 'escape');
      expect(p('Escape'), 'escape');
      expect(p('enter'), 'enter');
      expect(p('return'), 'enter');
      expect(p('alt+tab'), 'alt+tab');
      expect(p('ctrl + v'), 'ctrl+v');
      expect(p('F5'), 'f5');
      expect(p('shift+ctrl+a'), 'ctrl+shift+a');
    });

    test('sequences', () {
      expect(p('ctrl+a ctrl+c'), 'ctrl+a ctrl+c');
      expect(p('ctrl+a, ctrl+c'), 'ctrl+a ctrl+c');
      expect(p('ctrl+a then ctrl+c'), 'ctrl+a ctrl+c');
      expect(p('down down enter'), 'down down enter');
    });

    test('spoken and dashed forms', () {
      expect(p('control c'), 'ctrl+c');
      expect(p('control shift t'), 'ctrl+shift+t');
      expect(p('ctrl-c'), 'ctrl+c');
      expect(p('ctrl-shift-t'), 'ctrl+shift+t');
      expect(p('ctrl+-'), 'ctrl+minus');
      expect(p('ctrl++'), 'ctrl+plus');
      expect(p('page down'), 'pagedown');
      expect(p('shift'), 'shift');
    });

    test('all shortcut modifiers and aliases are preserved', () {
      for (final key in ['c', 'v', 'x', 'a']) {
        expect(p('Ctrl+$key'), 'ctrl+$key');
      }
      expect(p('Ctrl+Alt+Shift+A'), 'ctrl+shift+alt+a');
      expect(p('Shift-Control-Alt-F9'), 'ctrl+shift+alt+f9');
      expect(p('control alt shift a'), 'ctrl+shift+alt+a');
      expect(p('Meta+Control+Alt+Shift+V'), 'ctrl+shift+alt+super+v');
      expect(p('Win+Option+Shift+X'), 'shift+alt+super+x');
      expect(p('Command+Control+C'), 'ctrl+super+c');
      expect(p('ctrl+alt++'), 'ctrl+alt+plus');
      for (final modifier in ['ctrl', 'alt', 'shift', 'super']) {
        expect(p(modifier), modifier);
      }
    });

    test('incomplete chords reject the entire sequence before input', () {
      for (final text in ['ctrl+', '+c', 'ctrl+++', 'ctrl+alt+shift', 'ctrl+a ctrl+shift']) {
        expect(() => parseKeySequence(text), throwsFormatException, reason: text);
      }
    });

    test('rejects unknown keys', () {
      expect(() => parseKeySequence('ctrl+banana'), throwsFormatException);
      expect(() => parseKeySequence('the button'), throwsFormatException);
      expect(() => parseKeySequence(''), throwsFormatException);
    });
  });

  group('chordsForAction', () {
    test('terminals copy and paste with shift', () {
      expect(chordsForAction(KeyAction.copy, windowClass: 'xterm XTerm').join(), 'ctrl+shift+c');
      expect(
        chordsForAction(KeyAction.paste, windowClass: 'gnome-terminal-server Gnome-terminal').join(),
        'ctrl+shift+v',
      );
      expect(chordsForAction(KeyAction.selectAll, windowClass: 'kitty kitty').join(), 'ctrl+shift+a');
    });
    test('other apps use plain ctrl', () {
      expect(chordsForAction(KeyAction.copy, windowClass: 'gedit Gedit').join(), 'ctrl+c');
      expect(chordsForAction(KeyAction.selectAll, windowClass: 'Navigator firefox').join(), 'ctrl+a');
      expect(chordsForAction(KeyAction.escape).join(), 'escape');
      expect(chordsForAction(KeyAction.redo).join(), 'ctrl+shift+z');
    });
    test('KeyAction.parse', () {
      expect(KeyAction.parse('select_all'), KeyAction.selectAll);
      expect(KeyAction.parse('select all'), KeyAction.selectAll);
      expect(KeyAction.parse('Copy'), KeyAction.copy);
      expect(KeyAction.parse('nope'), isNull);
    });
  });

  group('xdotool args', () {
    test('chord keysyms', () {
      expect(xdotoolChord(parseKeySequence('esc').single), 'Escape');
      expect(xdotoolChord(parseKeySequence('ctrl+shift+c').single), 'ctrl+shift+c');
      expect(xdotoolChord(parseKeySequence('Ctrl+Alt+Shift+A').single), 'ctrl+shift+alt+a');
      expect(xdotoolChord(parseKeySequence('Meta+Ctrl+Alt+Shift+V').single), 'ctrl+shift+alt+super+v');
      expect(xdotoolChord(parseKeySequence('enter').single), 'Return');
      expect(xdotoolChord(parseKeySequence('alt+f4').single), 'alt+F4');
      expect(xdotoolChord(parseKeySequence('page up').single), 'Prior');
    });

    test('activate, release modifiers, keys, release, restore', () {
      final args = sendKeysArgs(parseKeySequence('ctrl+a ctrl+c'), activate: '11', restore: '22');
      expect(args.take(3), ['windowactivate', '--sync', '11']);
      final key = args.indexOf('key');
      expect(args.indexOf('keyup'), lessThan(key));
      expect(args.sublist(key, key + 5), ['key', '--delay', '40', 'ctrl+a', 'ctrl+c']);
      expect(args.lastIndexOf('keyup'), greaterThan(key));
      expect(args.sublist(args.length - 2), ['windowactivate', '22']);
      expect(args, isNot(contains('--clearmodifiers')));
      expect(args.where((a) => a == 'Control_L').length, 2);
    });

    test('no activation when the target already has focus', () {
      final args = sendKeysArgs(parseKeySequence('esc'));
      expect(args, isNot(contains('windowactivate')));
      expect(args.first, 'keyup');
    });

    test('alt+tab does not restore focus', () {
      expect(shouldRestoreFocus(parseKeySequence('alt+tab')), isFalse);
      expect(shouldRestoreFocus(parseKeySequence('ctrl+c')), isTrue);
    });

    test('parse xprop output', () {
      const out = '''
WM_CLASS(STRING) = "xterm", "XTerm"
_NET_WM_PID(CARDINAL) = 1234
_NET_WM_NAME(UTF8_STRING) = "a@host: ~"
WM_NAME(STRING) = "fallback"
_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL
_NET_WM_STATE(ATOM) =
WM_STATE(WM_STATE):
		window state: Normal
		icon window: 0x0
''';
      final w = XpropWindows.parseXprop('77', out);
      expect(w.title, 'a@host: ~');
      expect(w.wmClass, 'xterm XTerm');
      expect(w.pid, 1234);
      expect(w.hidden, isFalse);
      expect(w.special, isFalse);
      final dock = XpropWindows.parseXprop('1', '_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_DOCK\n');
      expect(dock.special, isTrue);
      final min = XpropWindows.parseXprop('2', '_NET_WM_STATE(ATOM) = _NET_WM_STATE_HIDDEN\n');
      expect(min.hidden, isTrue);
    });

    test('parse stacking list (topmost first, decimal ids)', () {
      expect(XpropWindows.parseStacking('_NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x400001, 0x600003\n'), [
        '${0x600003}',
        '${0x400001}',
      ]);
    });
  });

  group('KeyTargetResolver', () {
    const woi = X11Window(id: '1', title: 'Woi', wmClass: 'woi Woi', pid: _woiPid);
    const viewer = X11Window(id: '5', title: 'viewer', wmClass: 'woi Woi', pid: _woiPid);
    const xterm = X11Window(id: '2', title: 'a@host: ~', wmClass: 'xterm XTerm', pid: 10);
    const gedit = X11Window(id: '3', title: 'notes.txt - gedit', wmClass: 'gedit Gedit', pid: 11);
    const panel = X11Window(id: '4', title: 'panel', wmClass: 'tint2 Tint2', special: true);
    late FakeWindows x;
    late KeyTargetResolver r;

    setUp(() {
      x = FakeWindows({'1': woi, '2': xterm, '3': gedit, '4': panel, '5': viewer});
      r = KeyTargetResolver(x, selfPid: _woiPid);
    });

    test('active non-Woi window is the target', () async {
      x.active = '3';
      final (t, a) = await r.resolve(const KeyTarget());
      expect(t.id, '3');
      expect(a?.id, '3');
    });

    test('Woi focused: the window remembered at turn start', () async {
      x.active = '2';
      await r.remember();
      x.active = '1';
      x.stack = ['1', '3', '2'];
      final (t, a) = await r.resolve(const KeyTarget());
      expect(t.id, '2');
      expect(a?.id, '1');
    });

    test('remember ignores Woi windows', () async {
      x.active = '1';
      await r.remember();
      expect(r.remembered, isNull);
      x.active = '5';
      await r.remember();
      expect(r.remembered, isNull);
    });

    test('nothing remembered: topmost usable window', () async {
      x.active = '1';
      x.stack = ['5', '1', '4', '3', '2'];
      final (t, _) = await r.resolve(const KeyTarget());
      expect(t.id, '3');
    });

    test('a closed remembered window falls back to the stack', () async {
      r.remembered = '99';
      x.active = '1';
      x.stack = ['1', '2'];
      final (t, _) = await r.resolve(const KeyTarget());
      expect(t.id, '2');
      expect(r.remembered, isNull);
    });

    test('named target by class or title', () async {
      x.active = '3';
      x.stack = ['3', '2', '1'];
      expect((await r.resolve(const KeyTarget(window: 'XTerm'))).$1.id, '2');
      expect((await r.resolve(const KeyTarget(window: 'notes.txt'))).$1.id, '3');
      expect(() => r.resolve(const KeyTarget(window: 'firefox')), throwsStateError);
      // Woi itself is never targeted by name either.
      expect(() => r.resolve(const KeyTarget(window: 'woi')), throwsStateError);
    });

    test('only Woi open: error', () async {
      x.active = '1';
      x.stack = ['1', '4'];
      expect(() => r.resolve(const KeyTarget()), throwsStateError);
    });
  });

  group('send_keys tool', () {
    late FakeInput input;
    late ToolRegistry reg;
    setUp(() {
      input = FakeInput();
      reg = ToolRegistry()..register(sendKeysTool(input));
    });

    test('keys and actions reach InputControl', () async {
      var o = await reg.dispatch('send_keys', '{"keys":"ctrl+a ctrl+c"}');
      expect(o.ok, isTrue);
      expect(jsonDecode(o.json)['keys'], 'ctrl+a ctrl+c');
      input.windowClass = 'xterm XTerm';
      o = await reg.dispatch('send_keys', '{"action":"copy","window":"xterm"}');
      expect(o.ok, isTrue);
      expect(input.log.last, 'keys ctrl+shift+c @xterm');
    });

    test('explicit terminal shortcuts do not acquire semantic Shift', () async {
      input.windowClass = 'xterm XTerm';
      final copy = await reg.dispatch('send_keys', '{"keys":"Ctrl+C"}');
      final combo = await reg.dispatch('send_keys', '{"keys":"Ctrl+Alt+Shift+A"}');
      expect(copy.ok, isTrue);
      expect(combo.ok, isTrue);
      expect(input.log, ['keys ctrl+c', 'keys ctrl+shift+alt+a']);
    });

    test('ambiguous or incomplete input never enters native control', () async {
      for (final args in [
        '{"keys":"ctrl+c","action":"copy"}',
        '{"keys":"ctrl+c ctrl+alt+shift"}',
        '{"keys":"ctrl+"}',
      ]) {
        expect((await reg.dispatch('send_keys', args)).ok, isFalse);
      }
      expect(input.log, isEmpty);
    });

    test('bad input is a tool error', () async {
      expect((await reg.dispatch('send_keys', '{}')).ok, isFalse);
      expect((await reg.dispatch('send_keys', '{"keys":"ctrl+banana"}')).json, contains('bad keys'));
      expect((await reg.dispatch('send_keys', '{"action":"fly"}')).ok, isFalse);
    });
  });

  group('delegation keys fast path', () {
    List<Map<String, Object?>>? f(String s) => DelegationExecutor.keysFastPath(s);

    test('press', () {
      expect(f('press ctrl c'), [
        {'keys': 'ctrl c'},
      ]);
      expect(f('Press Escape.'), [
        {'keys': 'Escape'},
      ]);
      expect(f('please hit control shift t'), [
        {'keys': 'control shift t'},
      ]);
      expect(f('press enter in the xterm'), [
        {'keys': 'enter', 'window': 'xterm'},
      ]);
    });

    test('edit intents', () {
      expect(f('copy that'), [
        {'action': 'copy'},
      ]);
      expect(f('paste'), [
        {'action': 'paste'},
      ]);
      expect(f('Select all.'), [
        {'action': 'select_all'},
      ]);
      expect(f('select all and copy in the xterm'), [
        {'action': 'select_all', 'window': 'xterm'},
        {'action': 'copy', 'window': 'xterm'},
      ]);
      expect(f('copy it to the clipboard'), [
        {'action': 'copy'},
      ]);
      expect(f('escape'), [
        {'action': 'escape'},
      ]);
    });

    test('everything else goes to the model', () {
      expect(f('press the blue button'), isNull);
      expect(f('copy README.md to /tmp'), isNull);
      expect(f('undo that'), isNull);
      expect(f('select the second line'), isNull);
      expect(f('open the terminal'), isNull);
    });

    test('typed key requests count as actions', () {
      expect(looksLikeAction('copy that'), isTrue);
      expect(looksLikeAction('undo that'), isTrue);
      expect(looksLikeAction('apply'), isTrue);
    });
  });
}
