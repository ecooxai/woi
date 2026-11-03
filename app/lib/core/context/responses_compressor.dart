import 'dart:io';

import '../models/message.dart';
import '../responses/responses_client.dart';
import 'compressor.dart';

const kCompressorInstructions = '''
You compress the history of a voice assistant conversation into a dense memory that replaces it.
Write plain text (no markdown headings), at most about 250 words, in these labelled lines when they apply:
Facts: durable facts about the user, their machine and preferences.
Tasks: what the user asked for and the status of each (done / pending / failed).
Files: exact file paths, commands and URLs that matter.
Decisions: choices made and constraints agreed on.
Screen: the screenshots are removed from the context after this, so describe each attached one in a short phrase
(app, document or page, and anything the user referred to), merging near-identical ones.
Keep exact names, numbers and paths. Drop greetings, filler, repetition and tool chatter.
If a previous summary is given, merge it: keep what is still relevant, update what changed.
''';

/// [Compressor] backed by the Responses API (default model gpt-6-luna).
/// Screenshots are sent as images (the newest [maxImages]) so their content
/// survives as short text descriptions once they leave the context.
class ResponsesCompressor implements Compressor {
  ResponsesCompressor(this.client, {this.maxImages = 6, this.maxToolChars = 500});

  final ResponsesClient client;
  final int maxImages;
  final int maxToolChars;

  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    final content = <Map<String, Object?>>[];
    final sb = StringBuffer();
    if (previousSummary != null && previousSummary.trim().isNotEmpty) {
      sb
        ..writeln('PREVIOUS SUMMARY:')
        ..writeln(previousSummary.trim())
        ..writeln();
    }
    sb.writeln('CONVERSATION TO COMPRESS:');
    // Only the most recent screenshots are attached; older ones are noted.
    final withImages = [
      for (final m in messages)
        if (m.image != null) m,
    ];
    final attach = withImages.length <= maxImages ? withImages : withImages.sublist(withImages.length - maxImages);
    var imageNo = 0;
    final images = <Map<String, Object?>>[];
    for (final m in messages) {
      final line = _render(m);
      final img = m.image;
      var imgNote = '';
      if (img != null) {
        if (attach.contains(m)) {
          final f = File(img.path);
          if (await f.exists()) {
            imageNo++;
            images.add(inputImage(await f.readAsBytes()));
            imgNote = ' [screenshot #$imageNo attached]';
          }
        }
        if (imgNote.isEmpty) imgNote = ' [screenshot, not attached]';
      }
      if (line == null && imgNote.isEmpty) continue;
      sb.writeln('${line ?? 'Screen:'}$imgNote');
    }
    content
      ..add(inputText(sb.toString()))
      ..addAll(images);
    if (images.isNotEmpty) {
      content.add(inputText('Screenshots #1..#${images.length} are attached above in order.'));
    }
    final r = await client.create(model: model, instructions: kCompressorInstructions, input: [userMessage(content)]);
    final summary = r.text.trim();
    if (summary.isEmpty) throw StateError('compressor returned an empty summary');
    return CompressionResult(summary: summary, tokensAfter: (summary.length / 4).ceil());
  }

  String? _render(Message m) {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
    final t = m.text.trim();
    switch (m.kind) {
      case MessageKind.user:
        return t.isEmpty ? null : 'User: $t';
      case MessageKind.assistant:
        return t.isEmpty ? null : 'Assistant: $t${m.interrupted ? ' (interrupted)' : ''}';
      case MessageKind.tool:
        final tool = m.tool;
        if (tool == null) return null;
        return 'Tool ${tool.name}(${clip(tool.argsJson, 300)}) → ${tool.status.name}: '
            '${clip(tool.resultJson ?? '', maxToolChars)}';
      case MessageKind.system:
        return t.isEmpty || m.meta['type'] == 'compaction' ? null : 'Note: ${clip(t, 300)}';
    }
  }
}
