import 'dart:io';

import 'package:path/path.dart' as p;

final Map<String, String?> _whichCache = {};

/// Locates [name] on PATH (cached). Returns null if not installed.
String? which(String name) {
  if (_whichCache.containsKey(name)) return _whichCache[name];
  final path = Platform.environment['PATH'] ?? '/usr/bin:/bin';
  for (final dir in path.split(':')) {
    if (dir.isEmpty) continue;
    final f = File(p.join(dir, name));
    if (f.existsSync()) {
      return _whichCache[name] = f.path;
    }
  }
  return _whichCache[name] = null;
}

bool? _envDefaultSignal;

/// Runs [exe] with SIGPIPE back at its default action (via
/// `env --default-signal=PIPE`, GNU coreutils 8.31+) when that is available.
///
/// The Dart VM ignores SIGPIPE and an ignored disposition survives exec, so a
/// child that writes to our stdout pipe (pw-record) would otherwise only get
/// EPIPE after Woi dies and keep running, holding the microphone open forever.
(String, List<String>) withDefaultSigpipe(String exe, List<String> args) {
  _envDefaultSignal ??= () {
    final env = which('env');
    if (env == null) return false;
    try {
      return Process.runSync(env, ['--default-signal=PIPE', 'true']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();
  if (!_envDefaultSignal!) return (exe, args);
  return (which('env')!, ['--default-signal=PIPE', exe, ...args]);
}

/// X display to target; defaults to :0 when DISPLAY is unset.
String x11Display() {
  final d = Platform.environment['DISPLAY'];
  return (d == null || d.isEmpty) ? ':0' : d;
}

Map<String, String> x11Env() => {'DISPLAY': x11Display()};

class CommandFailed implements Exception {
  CommandFailed(this.command, this.exitCode, this.stderr);
  final String command;
  final int exitCode;
  final String stderr;
  @override
  String toString() => '$command failed (exit $exitCode)${stderr.trim().isEmpty ? '' : ': ${stderr.trim()}'}';
}

class MissingTool implements Exception {
  MissingTool(this.tools);
  final List<String> tools;
  @override
  String toString() => 'Required tool not installed: ${tools.join(' or ')}';
}

Future<ProcessResult> runChecked(
  String exe,
  List<String> args, {
  Map<String, String>? environment,
  bool binary = false,
}) async {
  final r = await Process.run(exe, args, environment: environment, stdoutEncoding: binary ? null : systemEncoding);
  if (r.exitCode != 0) {
    throw CommandFailed('$exe ${args.join(' ')}', r.exitCode, '${r.stderr}');
  }
  return r;
}
