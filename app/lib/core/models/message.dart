import 'dart:math';

enum MessageKind { user, assistant, tool, system }

enum ToolStatus { pending, awaitingApproval, running, success, error, denied }

/// Screenshot metadata. [width]/[height] are what the model saw;
/// [originalWidth]/[originalHeight] are the real screen size.
class ImageAttachment {
  const ImageAttachment({
    required this.path,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
  });

  final String path;
  final int width;
  final int height;
  final int originalWidth;
  final int originalHeight;

  Map<String, Object?> toJson() => {'path': path, 'w': width, 'h': height, 'ow': originalWidth, 'oh': originalHeight};

  factory ImageAttachment.fromJson(Map<String, Object?> j) => ImageAttachment(
    path: j['path'] as String,
    width: (j['w'] as num?)?.toInt() ?? 0,
    height: (j['h'] as num?)?.toInt() ?? 0,
    originalWidth: (j['ow'] as num?)?.toInt() ?? 0,
    originalHeight: (j['oh'] as num?)?.toInt() ?? 0,
  );
}

class AudioClip {
  const AudioClip({required this.path, required this.durationMs});
  final String path;
  final int durationMs;

  Map<String, Object?> toJson() => {'path': path, 'ms': durationMs};
  factory AudioClip.fromJson(Map<String, Object?> j) =>
      AudioClip(path: j['path'] as String, durationMs: (j['ms'] as num?)?.toInt() ?? 0);
}

class ToolCallInfo {
  ToolCallInfo({
    required this.callId,
    required this.name,
    required this.argsJson,
    this.status = ToolStatus.pending,
    this.resultJson,
    DateTime? startedAt,
    this.finishedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final String callId;
  final String name;
  final String argsJson;
  ToolStatus status;
  String? resultJson;
  final DateTime startedAt;
  DateTime? finishedAt;

  Map<String, Object?> toJson() => {
    'callId': callId,
    'name': name,
    'args': argsJson,
    'status': status.name,
    if (resultJson != null) 'result': resultJson,
    'startedAt': startedAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
  };

  factory ToolCallInfo.fromJson(Map<String, Object?> j) => ToolCallInfo(
    callId: j['callId'] as String,
    name: j['name'] as String,
    argsJson: j['args'] as String? ?? '{}',
    status: ToolStatus.values.asNameMap()[j['status']] ?? ToolStatus.error,
    resultJson: j['result'] as String?,
    startedAt: DateTime.tryParse(j['startedAt'] as String? ?? ''),
    finishedAt: DateTime.tryParse(j['finishedAt'] as String? ?? ''),
  );
}

final _rng = Random();

String newId([String prefix = '']) {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = _rng.nextInt(1 << 32).toRadixString(36).padLeft(6, '0');
  return '$prefix$t$r';
}

/// One entry in a conversation. Mutable so streaming updates can be applied
/// in place; the owner is responsible for notifying listeners.
class Message {
  Message({
    String? id,
    required this.kind,
    this.text = '',
    this.image,
    this.audio,
    this.tool,
    DateTime? createdAt,
    this.interrupted = false,
    this.compacted = false,
    this.streaming = false,
    Map<String, Object?>? meta,
  }) : id = id ?? newId('m'),
       createdAt = createdAt ?? DateTime.now(),
       meta = meta ?? {};

  final String id;
  final MessageKind kind;
  String text;
  ImageAttachment? image;
  AudioClip? audio;
  ToolCallInfo? tool;
  final DateTime createdAt;

  /// Assistant reply cut off by barge-in.
  bool interrupted;

  /// Folded into a compaction summary; no longer counts toward the context.
  bool compacted;

  /// Still receiving deltas (not persisted).
  bool streaming;

  /// Free-form extras, e.g. compaction stats for system messages.
  final Map<String, Object?> meta;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'createdAt': createdAt.toIso8601String(),
    if (text.isNotEmpty) 'text': text,
    if (image != null) 'image': image!.toJson(),
    if (audio != null) 'audio': audio!.toJson(),
    if (tool != null) 'tool': tool!.toJson(),
    if (interrupted) 'interrupted': true,
    if (compacted) 'compacted': true,
    if (meta.isNotEmpty) 'meta': meta,
  };

  factory Message.fromJson(Map<String, Object?> j) => Message(
    id: j['id'] as String?,
    kind: MessageKind.values.asNameMap()[j['kind']] ?? MessageKind.system,
    text: j['text'] as String? ?? '',
    image: j['image'] is Map ? ImageAttachment.fromJson((j['image'] as Map).cast<String, Object?>()) : null,
    audio: j['audio'] is Map ? AudioClip.fromJson((j['audio'] as Map).cast<String, Object?>()) : null,
    tool: j['tool'] is Map ? ToolCallInfo.fromJson((j['tool'] as Map).cast<String, Object?>()) : null,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    interrupted: j['interrupted'] == true,
    compacted: j['compacted'] == true,
    meta: j['meta'] is Map ? (j['meta'] as Map).cast<String, Object?>() : null,
  );
}

class Conversation {
  Conversation({
    String? id,
    this.title = '',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Message>? messages,
    this.summary,
  }) : id = id ?? newId('c'),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<Message> messages;

  /// Rolling summary produced by context compaction.
  String? summary;

  Message add(Message m) {
    messages.add(m);
    updatedAt = DateTime.now();
    if (title.isEmpty && m.kind == MessageKind.user && m.text.isNotEmpty) {
      title = _titleFrom(m.text);
    }
    return m;
  }

  void touch() {
    updatedAt = DateTime.now();
    if (title.isEmpty) {
      for (final m in messages) {
        if (m.kind == MessageKind.user && m.text.trim().isNotEmpty) {
          title = _titleFrom(m.text);
          break;
        }
      }
    }
  }

  static String _titleFrom(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= 60 ? t : '${t.substring(0, 57)}…';
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (summary != null) 'summary': summary,
    'messages': [
      for (final m in messages)
        if (!(m.streaming && m.text.isEmpty && m.tool == null)) m.toJson(),
    ],
  };

  factory Conversation.fromJson(Map<String, Object?> j) => Conversation(
    id: j['id'] as String?,
    title: j['title'] as String? ?? '',
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    summary: j['summary'] as String?,
    messages: [
      for (final m in (j['messages'] as List? ?? const []))
        if (m is Map) Message.fromJson(m.cast<String, Object?>()),
    ],
  );
}
