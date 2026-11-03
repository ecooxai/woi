import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'note.dart';

/// Persists one note per conversation: `{dataDir}/notes/{conversationId}.json`
/// (atomic tmp + rename, like the conversations themselves).
class NoteStore {
  NoteStore(this.dataDir);
  final String dataDir;

  String get dir => p.join(dataDir, 'notes');
  String _file(String id) => p.join(dir, '$id.json');

  Future<Note> load(String conversationId) async {
    final f = File(_file(conversationId));
    try {
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          final n = Note.fromJson(j.cast());
          return Note(conversationId: conversationId, markdown: n.markdown, updatedAt: n.updatedAt);
        }
      }
    } catch (_) {}
    return Note(conversationId: conversationId);
  }

  Future<void> save(Note note) async {
    final f = File(_file(note.conversationId));
    await f.parent.create(recursive: true);
    if (note.isEmpty && !await f.exists()) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(note.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> delete(String conversationId) async {
    final f = File(_file(conversationId));
    if (await f.exists()) await f.delete();
  }
}
