import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/terminal/term_process.dart';
import 'package:woi/core/terminal/terminal_hub.dart';
import 'package:woi/ui/terminal/terminal_panel.dart';
import 'package:xterm/xterm.dart';

/// In-memory process: echoes input back, records resizes.
class _EchoProcess implements TermProcess {
  _EchoProcess(this.pid);
  @override
  final int pid;
  final _out = StreamController<Uint8List>();
  final _exit = Completer<int>();
  final written = StringBuffer();
  (int, int)? size;
  bool killed = false;

  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void write(Uint8List data) {
    written.write(utf8.decode(data));
    _out.add(data);
  }

  @override
  void resize(int rows, int cols) => size = (rows, cols);
  @override
  void kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
  }
}

void main() {
  late List<_EchoProcess> procs;
  late TerminalHub hub;

  setUp(() {
    procs = [];
    hub = TerminalHub(
      starter: (exe, args, {workingDirectory, environment, rows = 24, columns = 80}) {
        final p = _EchoProcess(1000 + procs.length);
        procs.add(p);
        return p;
      },
      shell: '/bin/sh',
      workingDirectory: () => '/tmp',
      codexDir: null,
    );
  });

  Future<void> pump(WidgetTester t, {Brightness brightness = Brightness.light, bool? hardwareKeyboardOnly}) async {
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: TerminalPanel(hub: hub, hardwareKeyboardOnly: hardwareKeyboardOnly),
        ),
      ),
    );
    await t.pump();
    await t.pump();
  }

  testWidgets('opening the panel starts one shell tab', (t) async {
    expect(procs, isEmpty);
    await pump(t);
    expect(hub.sessions, hasLength(1));
    expect(procs, hasLength(1));
    expect(find.text('Shell 1'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('new, rename and close tabs', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('terminal-new-tab')));
    await t.pump();
    expect(find.text('Shell 2'), findsOneWidget);
    expect(hub.activeIndex, 1);

    final second = hub.sessions[1];
    await t.tap(find.byKey(ValueKey('terminal-tab-${second.id}')));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byKey(ValueKey('terminal-tab-${second.id}')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('terminal-rename-field')), 'logs');
    await t.tap(find.text('Rename'));
    await t.pumpAndSettle();
    expect(find.text('logs'), findsOneWidget);

    await t.tap(find.byKey(ValueKey('terminal-close-${second.id}')));
    await t.pump();
    expect(hub.sessions, hasLength(1));
    expect(procs[1].killed, isTrue);
    expect(find.text('logs'), findsNothing);
  });

  testWidgets('rename dialog keeps keyboard focus when both clicks land before a frame', (t) async {
    await pump(t);
    final tab = find.byKey(ValueKey('terminal-tab-${hub.sessions.first.id}'));
    // Under load both clicks are handled before the select's post-frame focus.
    await t.tap(tab);
    await t.tap(tab);
    await t.pumpAndSettle();
    final field = t.widget<EditableText>(
      find.descendant(of: find.byKey(const ValueKey('terminal-rename-field')), matching: find.byType(EditableText)),
    );
    expect(field.focusNode.hasFocus, isTrue);
    expect(terminalHasFocus(), isFalse);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(terminalHasFocus(), isTrue);
  });

  testWidgets('typing goes to the shell; Ctrl+Shift+T opens a tab', (t) async {
    await pump(t);
    await t.tap(find.byType(TerminalView));
    await t.pump();
    expect(terminalHasFocus(), isTrue);
    hub.sessions.first.terminal.textInput('ls');
    hub.sessions.first.terminal.keyInput(TerminalKey.enter);
    expect(procs.first.written.toString(), 'ls\r');

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyT);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(hub.sessions, hasLength(2));
    await t.pump(const Duration(seconds: 1)); // TerminalView's double-tap timer
  });

  testWidgets('desktop key input: fast typing reaches the shell exactly once', (t) async {
    await pump(t, hardwareKeyboardOnly: true);
    await t.tap(find.byType(TerminalView));
    await t.pump();
    // No frames between keys, like a fast typist or xdotool.
    for (final k in [
      LogicalKeyboardKey.keyE,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.enter,
    ]) {
      await t.sendKeyEvent(k, platform: 'linux');
    }
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft, platform: 'linux');
    await t.sendKeyEvent(LogicalKeyboardKey.keyC, platform: 'linux');
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft, platform: 'linux');
    expect(procs.first.written.toString(), 'echo hi\r\x03');
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('closing every tab shows a New terminal button', (t) async {
    await pump(t);
    await t.tap(find.byKey(ValueKey('terminal-close-${hub.sessions.first.id}')));
    await t.pump();
    expect(find.byKey(const ValueKey('terminal-empty-new')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('terminal-empty-new')));
    await t.pump();
    expect(hub.sessions, hasLength(1));
  });

  test('terminal theme follows the app brightness', () {
    final light = terminalThemeFor(ThemeData(brightness: Brightness.light));
    final dark = terminalThemeFor(ThemeData(brightness: Brightness.dark));
    expect(light.background.computeLuminance(), greaterThan(0.5));
    expect(dark.background.computeLuminance(), lessThan(0.2));
    expect(light.foreground.computeLuminance(), lessThan(0.1));
  });
}
