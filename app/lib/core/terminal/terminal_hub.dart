import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../../platform/codex_bundle.dart';
import '../../platform/shell.dart';
import 'term_process.dart';

enum TerminalKind {
  /// An interactive login-less shell ($SHELL).
  shell,

  /// Shows the AI's run_bash commands; each command gets its own PTY and the
  /// user can type into it while it runs.
  ai,
}

/// Lines of scrollback per tab.
const kTerminalScrollback = 10000;

/// One terminal tab: an xterm [Terminal] model plus the process behind it.
/// The model outlives the widget, so switching views keeps the scrollback.
class TerminalSession extends ChangeNotifier {
  TerminalSession._(this.hub, this.id, this.kind, this._title)
    : terminal = Terminal(maxLines: kTerminalScrollback, platform: TerminalTargetPlatform.linux),
      controller = TerminalController() {
    terminal.onOutput = _onInput;
    terminal.onResize = (w, h, pw, ph) => _proc?.resize(h, w);
    terminal.onTitleChange = (t) {
      if (_renamed || t.trim().isEmpty || kind == TerminalKind.ai) return;
      _title = t.trim();
      notifyListeners();
      hub._changed();
    };
  }

  final TerminalHub hub;
  final int id;
  final TerminalKind kind;
  final Terminal terminal;
  final TerminalController controller;

  String _title;
  bool _renamed = false;
  String get title => _title;

  TermProcess? _proc;
  StreamSubscription<String>? _out;

  /// Completes when the current process's output stream ended (EOF).
  Completer<void> _outDone = Completer<void>()..complete();
  int? _exitCode;
  bool _disposed = false;

  /// The shell (or AI command) is alive.
  bool get running => _proc != null;
  int? get lastExitCode => _exitCode;
  int? get pid => _proc?.pid;

  void rename(String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    _title = t;
    _renamed = true;
    notifyListeners();
    hub._changed();
  }

  /// Types [command] and Enter into this shell, as if the user typed it.
  void typeCommand(String command) => _onInput('$command\r');

  void _onInput(String data) {
    final p = _proc;
    if (kind == TerminalKind.ai && hub._aiRun == null) return; // nothing to type into
    if (p != null) {
      p.write(Uint8List.fromList(utf8.encode(data)));
    } else if (kind == TerminalKind.shell && !_disposed) {
      // The shell exited: any key starts a new one.
      _startShell();
    }
  }

  void _attach(TermProcess proc, {void Function(String chunk)? tap}) {
    _proc = proc;
    _exitCode = null;
    final done = _outDone = Completer<void>();
    // One decoder per process keeps split UTF-8 sequences intact. Each chunk
    // marks the view dirty once; Flutter coalesces repaints per frame.
    _out = proc.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (s) {
            terminal.write(s);
            tap?.call(s);
          },
          onError: (Object _) {},
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: false,
        );
    notifyListeners();
  }

  /// Waits (bounded) until the output of the exited process is drained: the
  /// exit code can arrive before the last output chunk, which a short
  /// command would otherwise lose.
  Future<void> _drain({Duration max = const Duration(seconds: 2)}) =>
      _outDone.future.timeout(max, onTimeout: () {});

  void _startShell() {
    final h = hub;
    try {
      final proc = h._starter(
        h.shellPath,
        const [],
        workingDirectory: h.workingDirectory(),
        environment: h.environment(),
        rows: terminal.viewHeight,
        columns: terminal.viewWidth,
      );
      _attach(proc);
      proc.exitCode.then((code) => _detached(code));
    } catch (e) {
      terminal.write('\x1b[31mCannot start ${h.shellPath}: $e\x1b[0m\r\n');
    }
  }

  void _detached(int code) {
    _exitCode = code;
    _proc = null;
    if (_disposed) return;
    // Let the last output drain before the footer.
    final sub = _out;
    _drain().then((_) {
      if (identical(_out, sub)) {
        sub?.cancel();
        _out = null;
      }
      if (_disposed) return;
      if (kind == TerminalKind.shell) {
        terminal.write('\r\n\x1b[2m[process exited with code $code; press any key to restart]\x1b[0m\r\n');
      }
      notifyListeners();
      hub._changed();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _proc?.kill(ProcessSignal.sighup);
    _proc = null;
    _out?.cancel();
    controller.dispose();
    super.dispose();
  }
}

/// All terminal tabs. Nothing is spawned until the first tab is opened.
class TerminalHub extends ChangeNotifier {
  TerminalHub({
    TermProcessStarter? starter,
    String? shell,
    String Function()? workingDirectory,
    Map<String, String>? baseEnvironment,
    String? codexDir,
  }) : _starter = starter ?? startPty,
       shellPath = shell ?? _defaultShell(),
       workingDirectory = workingDirectory ?? (() => Platform.environment['HOME'] ?? Directory.current.path),
       _baseEnv = baseEnvironment ?? Platform.environment,
       codexDir = codexDir ?? bundledCodexDir();

  final TermProcessStarter _starter;
  final String shellPath;
  final String Function() workingDirectory;
  final Map<String, String> _baseEnv;

  /// Bundled codex CLI directory, prepended to PATH (null: not bundled).
  final String? codexDir;

  final List<TerminalSession> _sessions = [];
  int _active = 0;
  int _nextId = 1;
  int _shellCount = 0;
  bool _disposed = false;

  List<TerminalSession> get sessions => List.unmodifiable(_sessions);
  int get activeIndex => _active;
  TerminalSession? get active => _sessions.isEmpty ? null : _sessions[_active.clamp(0, _sessions.length - 1)];

  static String _defaultShell() {
    final s = Platform.environment['SHELL'];
    if (s != null && s.isNotEmpty && File(s).existsSync()) return s;
    for (final c in ['/bin/bash', '/usr/bin/bash', '/system/bin/sh', '/bin/sh']) {
      if (File(c).existsSync()) return c;
    }
    return '/bin/sh';
  }

  /// Environment for every terminal process: the app's, plus TERM and the
  /// bundled codex on PATH.
  Map<String, String> environment() {
    final env = Map<String, String>.of(_baseEnv)
      ..['TERM'] = 'xterm-256color'
      ..['COLORTERM'] = 'truecolor'
      ..['WOI_TERMINAL'] = '1';
    env.remove('FLUTTER_ENGINE_SWITCHES');
    final dir = codexDir;
    if (dir != null) {
      final path = env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin';
      env['PATH'] = path.split(':').contains(dir) ? path : '$dir:$path';
    }
    if ((env['LANG'] ?? '').isEmpty) env['LANG'] = 'C.UTF-8';
    return env;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Opens the first shell tab if there is none (the view calls this).
  void ensureTab() {
    if (_sessions.isEmpty) newShell();
  }

  TerminalSession newShell() {
    final s = TerminalSession._(this, _nextId++, TerminalKind.shell, 'Shell ${++_shellCount}');
    _sessions.add(s);
    _active = _sessions.length - 1;
    s._startShell();
    _changed();
    return s;
  }

  void select(int index) {
    if (index < 0 || index >= _sessions.length || index == _active) return;
    _active = index;
    _changed();
  }

  void close(TerminalSession s) {
    final i = _sessions.indexOf(s);
    if (i < 0) return;
    _sessions.removeAt(i);
    if (_active >= _sessions.length) _active = _sessions.length - 1;
    if (_active > i) _active--;
    if (_active < 0) _active = 0;
    s.dispose();
    _changed();
  }

  // ------------------------------------------------------------ AI commands
  //
  // The AI tab runs one long-lived `bash` (one PTY for the whole session, so
  // no PTY/fd per command) that reads "<token> <id> <script>" lines from the
  // terminal, runs each script in a subshell and brackets its output with
  // private OSC markers, which xterm does not render. The command text never
  // goes through the line discipline (canonical lines are capped at 4 KiB):
  // it is a temp file.

  TerminalSession? _ai;
  Future<void> _aiTail = Future.value();
  Directory? _scratch;
  final String _token = _randomToken();
  int _cmdSeq = 0;
  _AiRun? _aiRun;

  /// The tab that shows the AI's commands (created on first use).
  TerminalSession aiSession() {
    final existing = _ai;
    if (existing != null && _sessions.contains(existing)) return existing;
    final s = TerminalSession._(this, _nextId++, TerminalKind.ai, 'AI');
    _sessions.add(s);
    _ai = s;
    _changed();
    return s;
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  static const _runner = r"""
stty -echo 2>/dev/null
while IFS=' ' read -r __tok __id __f; do
  [ "$__tok" = "$WOI_AI_TOKEN" ] || continue
  stty echo 2>/dev/null
  printf '\033]777;woi-start;%s\007' "$__id"
  ( . "$__f" ) 2>&1
  __ec=$?
  stty -echo 2>/dev/null
  printf '\033]777;woi-end;%s;%s\007' "$__id" "$__ec"
done
""";

  void _ensureAiShell(TerminalSession s) {
    if (s._proc != null) return;
    final bash = File('/bin/bash').existsSync() ? '/bin/bash' : shellPath;
    final env = environment()..['WOI_AI_TOKEN'] = _token;
    final proc = _starter(
      bash,
      ['--noprofile', '--norc', '-c', _runner],
      workingDirectory: workingDirectory(),
      environment: env,
      rows: s.terminal.viewHeight,
      columns: s.terminal.viewWidth,
    );
    s._attach(proc, tap: _onAiOutput);
    proc.exitCode.then((code) {
      final mine = identical(s._proc, proc);
      if (mine) s._proc = null;
      final sub = s._out;
      // Collect the dying shell's last output before finishing its command.
      (mine ? s._drain() : Future<void>.value()).then((_) {
        final run = _aiRun;
        if (run != null && identical(run.proc, proc)) run.finish(code == 0 ? -1 : code);
        if (!mine || !identical(s._out, sub)) return;
        sub?.cancel();
        s._out = null;
      });
    });
  }

  static final _marker = RegExp(r'\x1b\]777;woi-(start|end);([0-9]+)(?:;(-?[0-9]+))?\x07');

  /// Raw AI-shell output: collect what is between the markers of the
  /// running command.
  void _onAiOutput(String chunk) {
    final run = _aiRun;
    if (run == null) return;
    run.pending += chunk;
    while (true) {
      final m = _marker.firstMatch(run.pending);
      if (m == null) break;
      final before = run.pending.substring(0, m.start);
      final id = int.parse(m.group(2)!);
      if (id == run.id && run.started) run.add(before);
      run.pending = run.pending.substring(m.end);
      if (id != run.id) continue;
      if (m.group(1) == 'start') {
        run.started = true;
      } else {
        run.finish(int.tryParse(m.group(3) ?? '') ?? -1);
        return;
      }
    }
    // Keep a possible partial marker; flush the rest.
    if (run.started) {
      final esc = run.pending.lastIndexOf('\x1b');
      final keep = esc >= 0 && run.pending.length - esc < 64 ? esc : run.pending.length;
      run.add(run.pending.substring(0, keep));
      run.pending = run.pending.substring(keep);
    }
  }

  /// Runs [command] (bash) in the AI tab and returns its output (ANSI
  /// stripped, stdout and stderr merged). Commands run one after another.
  Future<ShellResult> runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) {
    final run = _aiTail.then(
      (_) => _runNow(command, timeout: timeout, cwd: workingDirectory, maxOutputChars: maxOutputChars),
    );
    _aiTail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<ShellResult> _runNow(
    String command, {
    required Duration timeout,
    String? cwd,
    required int maxOutputChars,
  }) async {
    final s = aiSession();
    _active = _sessions.indexOf(s);
    _changed();
    final t = s.terminal;
    final dir = cwd ?? workingDirectory();
    final sw = Stopwatch()..start();
    t.write('\x1b[1;34m${_shortDir(dir)} \$\x1b[0m \x1b[1m${command.replaceAll('\n', '\r\n  ')}\x1b[0m\r\n');
    final id = ++_cmdSeq;
    final scratch = _scratch ??= await Directory.systemTemp.createTemp('woi-term-');
    final file = File('${scratch.path}/cmd-$id.sh');
    final quoted = "'${dir.replaceAll("'", r"'\''")}'";
    await file.writeAsString('cd -- $quoted || exit 1\n$command\n', flush: true);
    final run = _AiRun(id, maxOutputChars * 4);
    _aiRun = run;
    var timedOut = false;
    int code;
    try {
      _ensureAiShell(s);
      run.proc = s._proc;
      s._proc!.write(Uint8List.fromList(utf8.encode('$_token $id ${file.path}\n')));
      code = await run.done.future.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      // Kill the AI shell with the command; the next command starts a new one.
      final proc = s._proc;
      s._proc = null;
      await s._out?.cancel();
      s._out = null;
      proc?.kill(ProcessSignal.sigkill);
      code = -9;
    } catch (e) {
      t.write('\x1b[31mcannot run: $e\x1b[0m\r\n');
      code = -1;
    } finally {
      _aiRun = null;
      unawaited(file.delete().then((_) {}, onError: (Object _) {}));
    }
    sw.stop();
    final status = timedOut
        ? '\x1b[33m[timed out after ${timeout.inSeconds}s]\x1b[0m'
        : code == 0
        ? '\x1b[2m[exit 0 · ${sw.elapsedMilliseconds} ms]\x1b[0m'
        : '\x1b[31m[exit $code · ${sw.elapsedMilliseconds} ms]\x1b[0m';
    final raw = run.out.toString();
    t.write('${raw.isEmpty || raw.endsWith('\n') ? '' : '\r\n'}$status\r\n\r\n');
    if (!s._disposed) s.notifyListeners();
    _changed();
    final (out, truncated) = truncateMiddle(cleanTerminalOutput(raw), maxOutputChars);
    return ShellResult(
      exitCode: code,
      stdout: out,
      stderr: '',
      elapsed: sw.elapsed,
      timedOut: timedOut,
      truncated: truncated,
    );
  }

  String _shortDir(String dir) {
    final home = _baseEnv['HOME'];
    if (home != null && home.isNotEmpty && (dir == home || dir.startsWith('$home/'))) {
      return '~${dir.substring(home.length)}';
    }
    return dir;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _sessions) {
      s.dispose();
    }
    _sessions.clear();
    try {
      _scratch?.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }
}

class _AiRun {
  _AiRun(this.id, this.cap);
  final int id;
  final int cap;
  TermProcess? proc;
  bool started = false;
  String pending = '';
  final out = StringBuffer();
  final done = Completer<int>();

  void add(String s) {
    if (s.isNotEmpty && out.length < cap) out.write(s);
  }

  void finish(int code) {
    if (!done.isCompleted) done.complete(code);
  }
}

final _csi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
final _osc = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');
final _esc2 = RegExp(r'\x1b[@-Z\\-_()*+][0-9A-Za-z]?');
final _ctl = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');

/// Terminal bytes -> plain text for the model: no escape sequences, CRLF ->
/// LF, and carriage-return redraws (progress bars) keep only the final text.
String cleanTerminalOutput(String s) {
  var t = s.replaceAll(_osc, '').replaceAll(_csi, '').replaceAll(_esc2, '');
  t = t.replaceAll('\r\n', '\n');
  final lines = t.split('\n').map((l) {
    final i = l.lastIndexOf('\r');
    return i < 0 ? l : l.substring(i + 1);
  });
  return lines.join('\n').replaceAll(_ctl, '').trimRight();
}

/// [Shell] that runs commands visibly in the terminal's AI tab
/// ("Run in terminal" setting). Same result shape as the pipe shell, with
/// stdout and stderr merged (a PTY has one stream).
class TerminalShell implements Shell {
  TerminalShell(this.hub);
  final TerminalHub hub;

  @override
  Future<ShellResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    int maxOutputChars = 8000,
  }) => hub.runCommand(command, timeout: timeout, workingDirectory: workingDirectory, maxOutputChars: maxOutputChars);
}
