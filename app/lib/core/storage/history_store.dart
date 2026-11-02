import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../platform/app_paths.dart';
import '../audio/wav.dart';
import '../models/message.dart';

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messageCount,
  });
  final String id;
  final String title;
  final DateTime updatedAt;
  final int messageCount;
}

/// Persists conversations as JSON plus media (wav/png) under the data dir:
/// `conversations/{id}.json`, `audio/{msgId}.wav`, `images/{msgId}.png`.
class HistoryStore {
  HistoryStore(this.paths);
  final AppPaths paths;

  final Map<String, Timer> _pendingSaves = {};

  Future<void> init() async {
    for (final d in [paths.conversationsDir, paths.audioDir, paths.imagesDir]) {
      await Directory(d).create(recursive: true);
    }
  }

  String _file(String id) => p.join(paths.conversationsDir, '$id.json');

  Future<void> save(Conversation c) async {
    _pendingSaves.remove(c.id)?.cancel();
    final f = File(_file(c.id));
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(c.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  /// Coalesces bursts of updates (streaming deltas) into one write.
  void saveSoon(Conversation c,
      {Duration delay = const Duration(milliseconds: 600)}) {
    _pendingSaves[c.id]?.cancel();
    _pendingSaves[c.id] = Timer(delay, () {
      _pendingSaves.remove(c.id);
      save(c);
    });
  }

  Future<void> flush(Conversation c) async {
    if (_pendingSaves.containsKey(c.id)) await save(c);
  }

  Future<Conversation?> load(String id) async {
    final f = File(_file(id));
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map ? Conversation.fromJson(j.cast()) : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<ConversationSummary>> list() async {
    final dir = Directory(paths.conversationsDir);
    if (!await dir.exists()) return [];
    final out = <ConversationSummary>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await e.readAsString());
        if (j is! Map) continue;
        out.add(ConversationSummary(
          id: j['id'] as String,
          title: (j['title'] as String?)?.isNotEmpty == true
              ? j['title'] as String
              : 'Untitled conversation',
          updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
              (await e.lastModified()),
          messageCount: (j['messages'] as List?)?.length ?? 0,
        ));
      } catch (_) {}
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<Conversation?> loadLatest() async {
    final all = await list();
    return all.isEmpty ? null : load(all.first.id);
  }

  Future<void> delete(String id) async {
    final c = await load(id);
    if (c != null) {
      for (final m in c.messages) {
        for (final path in [m.audio?.path, m.image?.path]) {
          if (path != null && p.isWithin(paths.dataDir, path)) {
            try {
              await File(path).delete();
            } catch (_) {}
          }
        }
      }
    }
    final f = File(_file(id));
    if (await f.exists()) await f.delete();
  }

  Future<AudioClip> saveAudio(String messageId, Uint8List pcm16) async {
    final path = p.join(paths.audioDir, '$messageId.wav');
    await writeWav(path, pcm16);
    return AudioClip(path: path, durationMs: pcmDurationMs(pcm16.length));
  }

  Future<String> saveImage(String messageId, Uint8List png) async {
    final path = p.join(paths.imagesDir, '$messageId.png');
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }
}
