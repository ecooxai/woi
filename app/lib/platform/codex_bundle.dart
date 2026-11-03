import 'dart:io';

import 'package:path/path.dart' as p;

/// Pinned Codex CLI version bundled with the Linux build
/// (linux/CMakeLists.txt -> tool/bundle_codex.sh).
const kBundledCodexVersion = '0.166.0';

/// Directory holding the bundled `codex` binary (put on PATH inside the
/// built-in terminal), or null if this build has none (e.g. Android, or the
/// binary was not available at build time).
///
/// Layout: `<bundle>/lib/codex/bin/codex` next to the `woi` executable.
/// `WOI_CODEX_DIR` overrides it (dev runs, tests).
String? bundledCodexDir({String? executable, Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env['WOI_CODEX_DIR'];
  if (override != null && override.isNotEmpty) {
    return File(p.join(override, 'codex')).existsSync() ? override : null;
  }
  if (!Platform.isLinux) return null;
  final exe = executable ?? Platform.resolvedExecutable;
  final dir = p.join(p.dirname(exe), 'lib', 'codex', 'bin');
  return File(p.join(dir, 'codex')).existsSync() ? dir : null;
}
