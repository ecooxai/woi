import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import 'compressor.dart';

/// Raised after a background compaction finished.
class ContextCompacted {
  const ContextCompacted({
    required this.tokensBefore,
    required this.tokensAfter,
    required this.compactedMessages,
    required this.summary,
  });
  final int tokensBefore;
  final int tokensAfter;
  final int compactedMessages;
  final String summary;
}

/// Tracks the size of the model context and compacts it in the background
/// when it grows past [threshold].
///
/// Estimate = last `usage.totalContextTokens` reported by the backend
/// (adjusted for compactions since) + heuristic size of messages added after
/// that report. Without usage reports it is purely heuristic:
/// chars/4 + [imageTokenCost] per image + audio seconds × [audioTokensPerSecond].
class ContextManager extends ChangeNotifier {
  ContextManager({
    required this.compressor,
    this.threshold = 10000,
    this.compressionModel = 'gpt-6-luna',
    this.imageTokenCost = 765,
    this.audioTokensPerSecond = 10,
    this.keepRecent = 4,
    this.minInterval = const Duration(seconds: 10),
  });

  final Compressor compressor;
  int threshold;
  String compressionModel;
  int imageTokenCost;
  int audioTokensPerSecond;

  /// Most recent messages that are never compacted.
  int keepRecent;
  Duration minInterval;

  Conversation? _conv;
  int? _usageTotal;
  int _usageAtCount = 0;
  int _usageOffset = 0;
  bool _compressing = false;
  DateTime? _lastCompaction;
  Object? lastError;
  final _compactions = StreamController<ContextCompacted>.broadcast();

  Stream<ContextCompacted> get compactions => _compactions.stream;
  bool get compressing => _compressing;
  double get fill => threshold <= 0 ? 0 : estimatedTokens / threshold;

  void attach(Conversation c) {
    _conv = c;
    _usageTotal = null;
    _usageAtCount = 0;
    _usageOffset = 0;
    _lastCompaction = null;
    notifyListeners();
  }

  int estimateMessage(Message m) {
    if (m.compacted) return 0;
    var t = (m.text.length / 4).ceil() + 4;
    if (m.image != null) t += imageTokenCost;
    if (m.audio != null) {
      t += (m.audio!.durationMs / 1000 * audioTokensPerSecond).round();
    }
    final tool = m.tool;
    if (tool != null) {
      t += ((tool.argsJson.length + (tool.resultJson?.length ?? 0)) / 4).ceil() +
          8;
    }
    return t;
  }

  int _summaryTokens() => ((_conv?.summary?.length ?? 0) / 4).ceil();

  int heuristicTokens() {
    final c = _conv;
    if (c == null) return 0;
    var t = _summaryTokens();
    for (final m in c.messages) {
      t += estimateMessage(m);
    }
    return t;
  }

  int get estimatedTokens {
    final c = _conv;
    if (c == null) return 0;
    final u = _usageTotal;
    if (u == null) return heuristicTokens();
    var t = u + _usageOffset;
    for (var i = _usageAtCount; i < c.messages.length; i++) {
      t += estimateMessage(c.messages[i]);
    }
    return t < 0 ? 0 : t;
  }

  /// Authoritative size from the backend's usage event.
  void onUsage(int totalContextTokens) {
    _usageTotal = totalContextTokens;
    _usageAtCount = _conv?.messages.length ?? 0;
    notifyListeners();
    maybeCompress();
  }

  /// Call after the conversation changed (message added / updated).
  void onConversationChanged() {
    notifyListeners();
    maybeCompress();
  }

  List<Message> _compactable() {
    final c = _conv;
    if (c == null) return const [];
    final live = <Message>[
      for (final m in c.messages)
        if (!m.compacted && m.kind != MessageKind.system) m
    ];
    if (live.length <= keepRecent) return const [];
    return [
      for (final m in live.sublist(0, live.length - keepRecent))
        if (!m.streaming) m
    ];
  }

  /// Starts a background compaction if over threshold. Never blocks.
  /// Returns the running future (useful for tests), or null.
  Future<void>? maybeCompress({bool force = false}) {
    if (_compressing || _conv == null) return null;
    final before = estimatedTokens;
    if (!force && before <= threshold) return null;
    final last = _lastCompaction;
    if (!force && last != null && DateTime.now().difference(last) < minInterval) {
      return null;
    }
    final batch = _compactable();
    if (batch.isEmpty) return null;
    _compressing = true;
    notifyListeners();
    final conv = _conv!;
    return _run(conv, batch, before);
  }

  Future<void> _run(Conversation conv, List<Message> batch, int before) async {
    try {
      final result = await compressor.compress(batch,
          model: compressionModel, previousSummary: conv.summary);
      if (!identical(conv, _conv)) return; // conversation switched meanwhile
      // Messages already included in the backend's usage figure must be
      // subtracted via the offset; later ones simply stop being counted.
      var removed = 0;
      for (final m in batch) {
        if (conv.messages.indexOf(m) < _usageAtCount) {
          removed += estimateMessage(m);
        }
        m.compacted = true;
      }
      final oldSummary = _summaryTokens();
      conv.summary = result.summary;
      final newSummary = _summaryTokens();
      if (_usageTotal != null) {
        _usageOffset += newSummary - oldSummary - removed;
      }
      _lastCompaction = DateTime.now();
      lastError = null;
      final after = estimatedTokens;
      _compactions.add(ContextCompacted(
        tokensBefore: before,
        tokensAfter: after,
        compactedMessages: batch.length,
        summary: result.summary,
      ));
    } catch (e) {
      lastError = e;
      _lastCompaction = DateTime.now();
    } finally {
      _compressing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _compactions.close();
    super.dispose();
  }
}
