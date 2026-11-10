import 'message.dart';

/// Explicit provenance for links appended by Woi's attachment picker. The
/// complete Markdown remains in Message.text for storage, context and Copy.
class MessageFileAttachment {
  const MessageFileAttachment({required this.name, required this.uri});

  final String name;
  final String uri;

  String get markdown => '[$name]($uri)';

  Map<String, Object?> toJson() => {'name': name, 'uri': uri};
}

const messageFilesMeta = 'attachedFiles';

/// Only compact an exact generated suffix with complete saved provenance.
/// An authored file:// link, legacy message, or stale/malformed metadata stays
/// visible verbatim. Never guess from a filename, path or imageKind alone.
({String text, List<MessageFileAttachment> files})? messageFileDisplay(Message message) {
  if (message.kind != MessageKind.user) return null;
  final raw = message.meta[messageFilesMeta];
  if (raw is! List || raw.isEmpty || raw.length > 8) return null;
  final files = <MessageFileAttachment>[];
  for (final entry in raw) {
    if (entry is! Map) return null;
    final name = entry['name'];
    final target = entry['uri'];
    if (name is! String || target is! String) return null;
    final uri = Uri.tryParse(target);
    if (uri == null || uri.scheme != 'file' || !uri.path.startsWith('/')) return null;
    files.add(MessageFileAttachment(name: name, uri: target));
  }
  final suffix = files.map((file) => file.markdown).join('\n');
  if (message.text == suffix) return (text: '', files: files);
  final separated = '\n\n$suffix';
  if (!message.text.endsWith(separated)) return null;
  return (text: message.text.substring(0, message.text.length - separated.length), files: files);
}
