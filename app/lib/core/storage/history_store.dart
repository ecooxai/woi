import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
  // A conversation ID is never reused. Reject stale callbacks after deletion,
  // including delayed autosaves and background completions.
  final Set<String> _deleted = {};
  // Include media from failed snapshots: otherwise deleting a chat whose most
  // recent save failed could leave the newly generated file orphaned.
  final Map<String, Set<String>> _knownMedia = {};

  Future<void> init() async {
    for (final d in [paths.conversationsDir, paths.audioDir, paths.imagesDir]) {
      await Directory(d).create(recursive: true);
    }
  }

  String _file(String id) => p.join(paths.conversationsDir, '$id.json');

  /// Last write per conversation: saves run one after another (they share
  /// the tmp file, so overlapping ones failed with "Cannot rename").
  final Map<String, Future<void>> _writes = {};

  Future<void> _serialize(String id, Future<void> Function() action) {
    final prev = _writes[id] ?? Future<void>.value();
    late final Future<void> next;
    next = prev.catchError((Object _) {}).then((_) => action()).whenComplete(() {
      if (identical(_writes[id], next)) _writes.remove(id);
    });
    _writes[id] = next;
    return next;
  }

  Future<void> save(Conversation c) {
    _pendingSaves.remove(c.id)?.cancel();
    if (_deleted.contains(c.id)) return Future<void>.value();
    (_knownMedia[c.id] ??= {}).addAll(_mediaPaths(c));
    final json = jsonEncode(c.toJson());
    return _serialize(c.id, () async {
      if (!_deleted.contains(c.id)) await writeSnapshot(c.id, json);
    });
  }

  /// Writes one snapshot after the per-conversation queue has acquired its turn.
  /// Subclasses may provide a different storage writer while retaining ordering.
  @protected
  Future<void> writeSnapshot(String id, String json) async {
    final f = File(_file(id));
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(f.path);
  }

  /// Coalesces bursts of updates (streaming deltas) into one write.
  void saveSoon(Conversation c, {Duration delay = const Duration(milliseconds: 600)}) {
    _pendingSaves.remove(c.id)?.cancel();
    if (_deleted.contains(c.id)) return;
    _pendingSaves[c.id] = Timer(delay, () {
      _pendingSaves.remove(c.id);
      save(c).catchError((Object e) => debugPrint('saving ${c.id} failed: $e'));
    });
  }

  Future<void> flush(Conversation c) async {
    if (_pendingSaves.containsKey(c.id)) await save(c);
    await _writes[c.id];
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
        out.add(
          ConversationSummary(
            id: j['id'] as String,
            title: (j['title'] as String?)?.isNotEmpty == true ? j['title'] as String : 'Untitled conversation',
            updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? (await e.lastModified()),
            messageCount: (j['messages'] as List?)?.length ?? 0,
          ),
        );
      } catch (_) {}
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<Conversation?> loadLatest() async {
    final all = await list();
    return all.isEmpty ? null : load(all.first.id);
  }

  Future<void> delete(String id) {
    _deleted.add(id);
    _pendingSaves.remove(id)?.cancel();
    // A write already performing I/O must finish before removal. Waiting inside
    // the same queue also makes concurrent deletion calls safe.
    return _serialize(id, () => _deleteStored(id));
  }

  Iterable<String> _mediaPaths(Conversation c) sync* {
    for (final m in c.messages) {
      for (final path in [m.audio?.path, m.image?.path]) {
        if (path != null && p.isWithin(paths.dataDir, path)) yield path;
      }
    }
  }

  Future<void> _deleteStored(String id) async {
    final c = await load(id);
    final media = <String>{...?_knownMedia.remove(id), if (c != null) ..._mediaPaths(c)};
    for (final path in media) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    final f = File(_file(id));
    if (await f.exists()) await f.delete();
    final tmp = File('${f.path}.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  // Resumed turns replace the same WAV. Order both bytes and returned clips
  // per message, while unrelated messages keep saving independently.
  final Map<String, Future<AudioClip>> _audioWrites = {};

  Future<AudioClip> saveAudio(String messageId, Uint8List pcm16) {
    final path = p.join(paths.audioDir, '$messageId.wav');
    final snapshot = Uint8List.fromList(pcm16);
    final previous = _audioWrites[messageId];
    final ready = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    late final Future<AudioClip> next;
    next = ready
        .then((_) async {
          await writeWav(path, snapshot);
          return AudioClip(path: path, durationMs: pcmDurationMs(snapshot.length));
        })
        .whenComplete(() {
          if (identical(_audioWrites[messageId], next)) _audioWrites.remove(messageId);
        });
    _audioWrites[messageId] = next;
    return next;
  }

  Future<String> saveImage(String messageId, Uint8List png, {String ext = 'png'}) async {
    final path = p.join(paths.imagesDir, '$messageId.$ext');
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(png, flush: true);
    return path;
  }
}
