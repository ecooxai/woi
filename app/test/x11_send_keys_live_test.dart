// Live X11 check of LinuxInputControl.sendKeys (skipped by default):
//   WOI_LIVE_X11=1 DISPLAY=:11 flutter test test/x11_send_keys_live_test.dart
// Starts its own xterm (with Ctrl+Shift+A/C bound: stock xterm has no
// select-all or clipboard keys) and reads the clipboard back with xclip.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/platform/linux/linux_input_control.dart';

Future<String> _clipboard() async =>
    '${(await Process.run('xclip', ['-o', '-selection', 'clipboard'])).stdout}';

void main() {
  final live = Platform.environment['WOI_LIVE_X11'] == '1';
  final skip = live ? null : 'set WOI_LIVE_X11=1 and DISPLAY to a test display';

  test('select all + copy in xterm lands in the clipboard', () async {
    final xterm = await Process.start('xterm', [
      '-T',
      'woi-sendkeys-live',
      '-xrm',
      'XTerm*VT100.on2Clicks: all',
      '-xrm',
      r'XTerm*VT100.translations: #override Shift Ctrl <Key>A: select-start() select-end(PRIMARY) '
          r'select-start() select-end(PRIMARY) \n Shift Ctrl <Key>C: copy-selection(CLIPBOARD)',
      '-e',
      'sh',
      '-c',
      'echo live-marker-42; sleep 30',
    ]);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final p = await Process.start('xclip', ['-selection', 'clipboard']);
      p.stdin.write('before');
      await p.stdin.close();
      await p.exitCode;
      final input = LinuxInputControl();
      final a = await input.sendKeys(action: KeyAction.selectAll, target: const KeyTarget(window: 'woi-sendkeys-live'));
      expect('${a.chords.single}', 'ctrl+shift+a');
      final c = await input.sendKeys(action: KeyAction.copy, target: const KeyTarget(window: 'woi-sendkeys-live'));
      expect('${c.chords.single}', 'ctrl+shift+c');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await _clipboard(), contains('live-marker-42'));
    } finally {
      xterm.kill();
    }
  }, skip: skip);
}
