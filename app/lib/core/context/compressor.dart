import '../models/message.dart';

class CompressionResult {
  const CompressionResult({required this.summary, required this.tokensAfter});

  /// Replacement context: a dense summary of the compacted messages.
  final String summary;

  /// Estimated context size once the summary replaces the messages.
  final int tokensAfter;
}

/// Summarises older conversation into a compact form (e.g. with
/// gpt-6-luna through the Responses API). Must not touch the live session.
abstract class Compressor {
  Future<CompressionResult> compress(
    List<Message> messages, {
    required String model,
    String? previousSummary,
  });
}

/// Offline placeholder: extractive summary (first sentence of every turn).
class StubCompressor implements Compressor {
  StubCompressor({this.latency = const Duration(milliseconds: 800)});
  final Duration latency;

  @override
  Future<CompressionResult> compress(List<Message> messages,
      {required String model, String? previousSummary}) async {
    await Future<void>.delayed(latency);
    final sb = StringBuffer();
    if (previousSummary != null && previousSummary.isNotEmpty) {
      sb.writeln(previousSummary.trim());
    }
    for (final m in messages) {
      String line;
      switch (m.kind) {
        case MessageKind.user:
          line = 'User: ${_first(m.text)}';
        case MessageKind.assistant:
          line = 'Assistant: ${_first(m.text)}';
        case MessageKind.tool:
          final t = m.tool;
          line = t == null ? '' : 'Tool ${t.name} → ${t.status.name}';
        case MessageKind.system:
          continue;
      }
      if (m.image != null) line += ' [screenshot]';
      if (line.trim().isNotEmpty) sb.writeln('- $line');
    }
    final summary = sb.toString().trim();
    return CompressionResult(
        summary: summary, tokensAfter: (summary.length / 4).ceil());
  }

  static String _first(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    final cut = t.indexOf(RegExp(r'[.!?](\s|$)'));
    final first = cut > 0 ? t.substring(0, cut + 1) : t;
    return first.length > 140 ? '${first.substring(0, 137)}…' : first;
  }
}
