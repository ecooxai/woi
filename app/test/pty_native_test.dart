// Native PTY checks (the vendored, patched flutter_pty). The plugin library
// is not built for `flutter test`; run against a built bundle:
//   LD_LIBRARY_PATH=build/linux/x64/release/bundle/lib flutter test test/pty_native_test.dart
// Without it the tests skip.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/terminal/terminal_hub.dart';

bool _ptyAvailable() {
  if (!Platform.isLinux) return false;
  try {
    DynamicLibrary.open('libflutter_pty.so');
    return true;
  } catch (_) {
    return false;
  }
}

/// Open fds of this process pointing at a PTY (master or slave).
int _ptyFds() {
  var n = 0;
  for (final e in Directory('/proc/self/fd').listSync(followLinks: false)) {
    try {
      final t = Link(e.path).targetSync();
      if (t == '/dev/ptmx' || t.startsWith('/dev/pts/')) n++;
    } catch (_) {}
  }
  return n;
}

void main() {
  final skip = _ptyAvailable() ? null : 'libflutter_pty.so not loadable (set LD_LIBRARY_PATH to a built bundle lib/)';

  test('very short commands keep all their output', () async {
    for (var i = 0; i < 25; i++) {
      final pty = Pty.start('/bin/sh', arguments: ['-c', 'printf "out-$i"']);
      final chunks = <int>[];
      final done = pty.output.listen(chunks.addAll).asFuture<void>();
      await pty.exitCode;
      await done.timeout(const Duration(seconds: 3));
      expect(utf8.decode(chunks), contains('out-$i'), reason: 'run $i');
    }
  }, skip: skip);

  test('no fd is leaked per PTY (process exit and killed tab)', () async {
    final before = _ptyFds();
    for (var i = 0; i < 10; i++) {
      final pty = Pty.start('/bin/sh', arguments: ['-c', 'true']);
      final done = pty.output.drain<void>();
      await pty.exitCode;
      await done.timeout(const Duration(seconds: 3));
    }
    final hub = TerminalHub(shell: '/bin/bash', workingDirectory: () => Directory.systemTemp.path);
    for (var i = 0; i < 5; i++) {
      final s = hub.newShell();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hub.close(s);
    }
    hub.dispose();
    // Release happens after the exit code and EOF arrive.
    final sw = Stopwatch()..start();
    while (_ptyFds() > before && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(_ptyFds(), before);
  }, skip: skip);
}
