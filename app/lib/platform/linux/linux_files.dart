import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/util/diff.dart';
import '../files.dart';

/// dart:io based file access (also usable on macOS; mobile ports will
/// sandbox paths differently).
class LocalFiles implements Files {
  LocalFiles({required this.homeDir});

  final String homeDir;

  @override
  String resolve(String path) {
    var s = path.trim();
    if (s == '~') return homeDir;
    if (s.startsWith('~/')) s = p.join(homeDir, s.substring(2));
    if (!p.isAbsolute(s)) s = p.join(homeDir, s);
    return p.normalize(s);
  }

  static bool _looksBinary(Uint8List bytes) {
    final n = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  @override
  Future<FileReadResult> read(String path, {int maxBytes = 64 * 1024, int? offsetLine, int? limitLines}) async {
    final full = resolve(path);
    final file = File(full);
    final total = await file.length();
    final raf = await file.open();
    Uint8List head;
    try {
      // Reading by lines needs the whole (bounded) file.
      final want = offsetLine != null ? total.clamp(0, 8 * 1024 * 1024) : maxBytes;
      head = await raf.read(want.clamp(0, total));
    } finally {
      await raf.close();
    }
    if (_looksBinary(head)) {
      return FileReadResult(path: full, content: '', totalBytes: total, totalLines: 0, isBinary: true);
    }
    var text = const Utf8Decoder(allowMalformed: true).convert(head);
    var truncated = head.length < total;
    var lines = text.split('\n');
    final totalLines = truncated ? -1 : lines.length;
    var start = 1;
    if (offsetLine != null || limitLines != null) {
      start = (offsetLine ?? 1).clamp(1, lines.length);
      final end = limitLines == null ? lines.length : (start - 1 + limitLines).clamp(start - 1, lines.length);
      truncated = truncated || end < lines.length || start > 1;
      lines = lines.sublist(start - 1, end);
      text = lines.join('\n');
    }
    if (text.length > maxBytes) {
      text = text.substring(0, maxBytes);
      truncated = true;
    }
    return FileReadResult(
      path: full,
      content: text,
      totalBytes: total,
      totalLines: totalLines,
      truncated: truncated,
      startLine: start,
    );
  }

  @override
  Future<List<DirEntry>> list(String path, {bool showHidden = false}) async {
    final dir = Directory(resolve(path));
    final out = <DirEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (!showHidden && name.startsWith('.')) continue;
      FileStat? st;
      try {
        st = await e.stat();
      } catch (_) {}
      out.add(
        DirEntry(
          name: name,
          type: switch (e) {
            Link() => EntryType.link,
            Directory() => EntryType.directory,
            File() => EntryType.file,
            _ => EntryType.other,
          },
          size: st?.size ?? 0,
          modified: st?.modified,
        ),
      );
    }
    out.sort((a, b) {
      final ad = a.type == EntryType.directory ? 0 : 1;
      final bd = b.type == EntryType.directory ? 0 : 1;
      return ad != bd ? ad - bd : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Future<WriteOutcome> write(String path, String content, {required WriteApprover approve, String? reason}) async {
    final full = resolve(path);
    final file = File(full);
    String? old;
    if (await file.exists()) {
      try {
        old = await file.readAsString();
      } catch (_) {
        old = const Utf8Decoder(allowMalformed: true).convert(await file.readAsBytes());
      }
    }
    final diff = diffLines(old ?? '', content);
    final request = FileWriteRequest(path: full, oldContent: old, newContent: content, diff: diff, reason: reason);
    final ok = await approve(request);
    if (!ok) {
      return WriteOutcome(path: full, approved: false, written: false, added: diff.added, removed: diff.removed);
    }
    try {
      await file.parent.create(recursive: true);
      // Write atomically: temp file + rename.
      final tmp = File('$full.woi-tmp');
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(full);
      return WriteOutcome(
        path: full,
        approved: true,
        written: true,
        bytes: utf8.encode(content).length,
        added: diff.added,
        removed: diff.removed,
      );
    } catch (e) {
      return WriteOutcome(path: full, approved: true, written: false, error: '$e');
    }
  }
}
