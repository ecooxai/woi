import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/terminal/term_process.dart';
import 'package:woi/core/terminal/terminal_hub.dart';
import 'package:woi/platform/codex_bundle.dart';

void main() {
  late Directory tmp;
  late TerminalHub hub;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('woi-term-test-');
    hub = TerminalHub(
      starter: PipeTermProcess.start,
      shell: '/bin/bash',
      workingDirectory: () => tmp.path,
      codexDir: '/opt/fake-codex/bin',
    );
  });

  tearDown(() {
    hub.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('nothing is spawned until a tab is opened', () {
    expect(hub.sessions, isEmpty);
    hub.ensureTab();
    expect(hub.sessions, hasLength(1));
    hub.ensureTab();
    expect(hub.sessions, hasLength(1));
  });

  test('tabs: new, select, rename, close', () {
    final a = hub.newShell();
    final b = hub.newShell();
    expect(hub.activeIndex, 1);
    expect(a.title, 'Shell 1');
    hub.select(0);
    expect(hub.active, same(a));
    b.rename('  build  ');
    expect(b.title, 'build');
    b.rename('   ');
    expect(b.title, 'build');
    hub.close(a);
    expect(hub.sessions, [b]);
    expect(hub.activeIndex, 0);
  });

  test('environment puts the bundled codex first on PATH', () {
    final env = hub.environment();
    expect(env['PATH']!.split(':').first, '/opt/fake-codex/bin');
    expect(env['TERM'], 'xterm-256color');
    expect(env['WOI_TERMINAL'], '1');
  });

  test('runCommand returns output and exit code, runs in the cwd', () async {
    final r = await hub.runCommand('pwd; echo out; echo err >&2');
    expect(r.exitCode, 0);
    expect(r.stdout, contains(tmp.resolveSymbolicLinksSync()));
    expect(r.stdout, contains('out'));
    expect(r.stdout, contains('err'));
    expect(hub.active!.kind, TerminalKind.ai);
    expect(hub.active!.title, 'AI');

    final sub = Directory('${tmp.path}/sub')..createSync();
    final r2 = await hub.runCommand('pwd; exit 3', workingDirectory: sub.path);
    expect(r2.exitCode, 3);
    expect(r2.stdout, endsWith('/sub'));
  });

  test('commands are serialized and multi-line scripts work', () async {
    final results = await Future.wait([
      hub.runCommand('sleep 0.2; echo one'),
      hub.runCommand('for i in 1 2 3; do\n  echo "n=\$i"\ndone'),
    ]);
    expect(results[0].stdout, 'one');
    expect(results[1].stdout, 'n=1\nn=2\nn=3');
    expect(hub.sessions.where((s) => s.kind == TerminalKind.ai), hasLength(1));
  });

  test('timeout kills the command; the next command still runs', () async {
    final r = await hub.runCommand('sleep 5', timeout: const Duration(milliseconds: 300));
    expect(r.timedOut, isTrue);
    final r2 = await hub.runCommand('echo again');
    expect(r2.exitCode, 0);
    expect(r2.stdout, 'again');
  });

  test('closing the AI tab during a run finishes it', () async {
    final f = hub.runCommand('sleep 5', timeout: const Duration(seconds: 10));
    // Wait for the command to really start (a fixed delay raced the shell
    // spawn on a loaded machine: closing too early left nothing to kill).
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!hub.aiCommandRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(hub.aiCommandRunning, isTrue);
    final sw = Stopwatch()..start();
    hub.close(hub.aiSession());
    final r = await f;
    expect(r.exitCode, isNot(0));
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('output is truncated in the middle', () async {
    final r = await hub.runCommand('seq 1 5000', maxOutputChars: 200);
    expect(r.truncated, isTrue);
    expect(r.stdout, startsWith('1\n2\n'));
    expect(r.stdout, endsWith('5000'));
  });

  test('the tail of long output survives however it is chunked', () async {
    // The pause guarantees a second chunk after the kept head is full (the
    // tail used to be dropped then: only the first chunk was kept).
    final r = await hub.runCommand('seq 1 2000; sleep 0.3; seq 2001 4000', maxOutputChars: 200);
    expect(r.truncated, isTrue);
    expect(r.stdout, startsWith('1\n2\n'));
    expect(r.stdout, endsWith('3999\n4000'));
    final cut = int.parse(RegExp(r'\[(\d+) chars truncated\]').firstMatch(r.stdout)!.group(1)!);
    // seq 1 4000 prints 18893 chars; 200 are kept.
    expect(cut, closeTo(18893 - 200, 2));
  });

  test('cleanTerminalOutput strips escapes and CR redraws', () {
    expect(cleanTerminalOutput('\x1b[1;31mred\x1b[0m\r\n'), 'red');
    expect(cleanTerminalOutput('10%\r50%\r100%\r\ndone'), '100%\ndone');
    expect(cleanTerminalOutput('\x1b]0;title\x07a\x1b(Bb\x07'), 'ab');
  });

  test('TerminalShell delegates to the hub', () async {
    final r = await TerminalShell(hub).run('echo via-shell');
    expect(r.stdout, 'via-shell');
  });

  test('bundledCodexDir honours WOI_CODEX_DIR and the bundle layout', () {
    final bin = Directory('${tmp.path}/lib/codex/bin')..createSync(recursive: true);
    File('${bin.path}/codex').writeAsStringSync('#!/bin/sh\n');
    expect(bundledCodexDir(environment: {'WOI_CODEX_DIR': bin.path}), bin.path);
    expect(bundledCodexDir(environment: {'WOI_CODEX_DIR': '${tmp.path}/none'}), isNull);
    expect(bundledCodexDir(executable: '${tmp.path}/woi', environment: const {}), bin.path);
    expect(bundledCodexDir(executable: '/nonexistent/woi', environment: const {}), isNull);
    expect(kBundledCodexVersion, '0.166.0');
  });
}
