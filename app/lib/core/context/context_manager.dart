import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import 'compressor.dart';
import 'image_tiers.dart';

/// "950", "12.4k", "128k": how token counts are shown (meter and notes).
String formatTokenCount(int t) {
  if (t >= 100000) return '${(t / 1000).round()}k';
  if (t >= 1000) return '${(t / 1000).toStringAsFixed(1)}k';
  return '$t';
}

/// How the context of the active voice backend is measured.
enum ContextAccounting {
  /// The backend reports what the model saw after every response
  /// (Realtime `response.done.usage.input_tokens`). Server items keep their
  /// audio and every screenshot.
  usage,

  /// No usage events (gpt-live, research/REALTIME_API.md §6.2). The voice
  /// context is text only: instructions, summary, transcripts, typed text and
  /// tool/delegation output. Screenshots only reach the delegation model,
  /// which gets the latest one.
  textEstimate,
}

/// Raised after a background compaction finished. [tokensBefore] and
/// [tokensAfter] are [ContextManager.estimatedTokens] right before and right
/// after the summary replaced the messages, i.e. what the meter showed.
class ContextCompacted {
  const ContextCompacted({
    required this.tokensBefore,
    required this.tokensAfter,
    required this.compactedMessages,
    required this.summary,
    this.describedImages = 0,
    this.substantial = true,
  });
  final int tokensBefore;
  final int tokensAfter;
  final int compactedMessages;
  final String summary;

  /// Screenshots dropped from the context (described in the summary).
  final int describedImages;

  /// Whether the context shrank by at least [ContextManager.minGain] / 2 of
  /// its compressible part (everything but instructions and tools).
  final bool substantial;
}

/// Where the context tokens go, from the same estimator as the meter total.
class ContextParts {
  const ContextParts({
    required this.overhead,
    required this.summary,
    required this.text,
    required this.images,
    required this.imageCount,
    required this.audio,
    required this.tools,
    required this.toolCount,
    required this.compactedMessages,
    required this.total,
    required this.measured,
    this.imagesSaved = 0,
    this.imagesReduced = 0,
    this.imagesDescribed = 0,
    this.pinned = 0,
  });

  /// Tokens saved by sending screenshots at ⅕ size or as descriptions.
  final int imagesSaved;
  final int imagesReduced;
  final int imagesDescribed;

  /// Instructions and tool definitions (voice session and delegation).
  final int overhead;

  /// The conversation note, pinned every turn and never compacted.
  final int pinned;
  final int summary;
  final int text;
  final int images;
  final int imageCount;
  final int audio;
  final int tools;
  final int toolCount;
  final int compactedMessages;

  /// [ContextManager.estimatedTokens].
  final int total;

  /// [total] is anchored on a backend usage report.
  final bool measured;

  int get estimated => overhead + pinned + summary + text + images + audio + tools;
}

class _Baseline {
  _Baseline(this.tokens, this.ids, this.summaryTokens, this.scale, [this.pinned = 0]);
  final int pinned;
  final int tokens;

  /// Cost of every message in the context when the usage was reported.
  final Map<String, int> ids;
  final int summaryTokens;
  final double scale;
}

/// The single source of truth for the context size of the active backend,
/// used by the header meter, the compaction trigger and the compaction note.
///
/// * [ContextAccounting.usage] (direct Realtime): the last reported usage plus
///   the estimate of what changed since: messages added after it, minus
///   messages compacted since, plus the summary growth. The estimate of those
///   changes is calibrated with the ratio of the report to the estimate of
///   the same messages, so a compaction's before/after match the next report.
/// * [ContextAccounting.textEstimate] (gpt-live): [overheadTokens] + summary +
///   text of transcripts / notes / tool calls + the latest screenshot (the
///   one a delegation would attach).
///
/// Per message: chars/4 + 4, [imageTokenCost] per screenshot, audio at
/// [audioTokensPerSecond] (twice that for assistant audio). Error and status
/// notes are UI only and cost nothing.
///
/// Compaction summarizes every message before the [keepRecentTurns]-th last
/// user turn, screenshots included (the compressor describes them in words),
/// and only runs when that frees at least [minGain] of the context.
class ContextManager extends ChangeNotifier {
  ContextManager({
    required this.compressor,
    this.threshold = 10000,
    this.compressionModel = 'gpt-6-luna',
    this.imageTokenCost = 765,
    this.audioTokensPerSecond = 10,
    this.keepRecentTurns = kRawRecentTurns,
    this.minGain = 0.25,
    this.minInterval = const Duration(seconds: 10),
  });

  final Compressor compressor;

  /// Cost of a 1/5-size screenshot relative to a full one. Measured on
  /// gpt-realtime-2 (2026-11-03): 1280x720 ≈ 382 tokens, 256x144 ≈ 247;
  /// small images are not much cheaper, so the tile formula is no guide.
  static const reducedImageShare = 0.65;
  int threshold;
  String compressionModel;
  int imageTokenCost;
  int audioTokensPerSecond;

  /// User turns (with their replies, tools and screenshots) never compacted
  /// and always sent raw ([kRawRecentTurns], the product rule; tests lower it).
  int keepRecentTurns;

  /// Minimum share of the compressible context (total minus
  /// [overheadTokens]) a compaction must free.
  double minGain;
  Duration minInterval;

  ContextAccounting _accounting = ContextAccounting.usage;
  int _overhead = 0;
  Conversation? _conv;
  _Baseline? _baseline;
  bool _compressing = false;
  DateTime? _lastCompaction;
  Object? lastError;
  final _compactions = StreamController<ContextCompacted>.broadcast();

  Stream<ContextCompacted> get compactions => _compactions.stream;
  bool get compressing => _compressing;
  double get fill => threshold <= 0 ? 0 : estimatedTokens / threshold;
  ContextAccounting get accounting => _accounting;
  int get overheadTokens => _overhead;

  int _pinned = 0;

  /// Tokens of the pinned conversation note: counted every turn, never
  /// compacted (not part of what a compaction can free).
  int get pinnedTokens => _pinned;
  set pinnedTokens(int v) {
    if (v == _pinned) return;
    _pinned = v;
    notifyListeners();
  }

  /// Whether the total is anchored on a backend usage report.
  bool get measured => _accounting == ContextAccounting.usage && _baseline != null;

  /// Sets how the active backend's context is measured. [overheadTokens] is
  /// the fixed part (instructions, tool definitions, delegation prompt).
  void configure({required ContextAccounting accounting, int overheadTokens = 0}) {
    if (accounting == _accounting && overheadTokens == _overhead) return;
    _accounting = accounting;
    _overhead = overheadTokens;
    _baseline = null;
    notifyListeners();
    maybeCompress();
  }

  void attach(Conversation c) {
    _conv = c;
    _baseline = null;
    _lastCompaction = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ estimator

  static int textTokens(String s) => (s.length / 4).ceil();

  int _summaryTokens() => textTokens(_conv?.summary ?? '');

  String? _latestImageId(Conversation c) {
    if (_accounting != ContextAccounting.textEstimate) return null;
    for (var i = c.messages.length - 1; i >= 0; i--) {
      final m = c.messages[i];
      if (m.image != null && !m.compacted) return m.id;
    }
    return null;
  }

  static bool _uiOnly(Message m) => m.kind == MessageKind.system && m.meta['type'] != 'screenshot';

  /// Context cost of the screenshot on [m] at its current tier: full,
  /// ⅕ size or a description. gpt-live only carries the latest image (for
  /// delegations) and descriptions (in reconnect / delegation notes).
  int _imageCost(Message m, String? latestImageId) {
    final img = m.image;
    if (img == null) return 0;
    switch (imageTierOf(m)) {
      case ImageTier.described:
        return textTokens(imageDescriptionOf(m) ?? '') + 12;
      case ImageTier.reduced when _accounting == ContextAccounting.usage:
        return (imageTokenCost * reducedImageShare).round();
      case _:
        return _accounting == ContextAccounting.usage || m.id == latestImageId ? imageTokenCost : 0;
    }
  }

  /// Tokens saved on [m] by its tier versus a full screenshot (usage mode).
  int _imageSaving(Message m) {
    if (m.image == null || _accounting != ContextAccounting.usage) return 0;
    return math.max(0, imageTokenCost - _imageCost(m, null));
  }

  /// Cost of [m] whether or not it was compacted.
  int _cost(Message m, String? latestImageId) {
    if (_uiOnly(m)) return 0;
    var t = textTokens(m.text) + 4;
    t += _imageCost(m, latestImageId);
    final audio = m.audio;
    if (audio != null && _accounting == ContextAccounting.usage) {
      final rate = m.kind == MessageKind.assistant ? audioTokensPerSecond * 2 : audioTokensPerSecond;
      t += (audio.durationMs / 1000 * rate).round();
    }
    final tool = m.tool;
    if (tool != null) t += textTokens(tool.argsJson) + textTokens(tool.resultJson ?? '') + 8;
    return t;
  }

  /// Estimated tokens of [m] in the current context (0 once compacted).
  int estimateMessage(Message m) {
    if (m.compacted) return 0;
    final c = _conv;
    return _cost(m, c == null ? null : _latestImageId(c));
  }

  /// Overhead + summary + live messages, without usage calibration.
  int estimateTokens() {
    final c = _conv;
    if (c == null) return 0;
    final latest = _latestImageId(c);
    var t = _overhead + _pinned + _summaryTokens();
    for (final m in c.messages) {
      if (!m.compacted) t += _cost(m, latest);
    }
    return t;
  }

  double get _scale => measured ? _baseline!.scale : 1.0;

  /// The context size: what the meter shows and compaction is measured with.
  int get estimatedTokens {
    final c = _conv;
    if (c == null) return 0;
    final b = _baseline;
    if (_accounting != ContextAccounting.usage || b == null) return estimateTokens();
    var delta = _summaryTokens() - b.summaryTokens;
    for (final m in c.messages) {
      final was = b.ids[m.id];
      if (was != null) {
        // Compacted since, or cheaper now (screenshot downscaled/described).
        delta += m.compacted ? -was : _cost(m, null) - was;
      } else if (!m.compacted) {
        delta += _cost(m, null);
      }
    }
    return math.max(0, b.tokens + (delta * b.scale).round() + _pinned - b.pinned);
  }

  /// Breakdown for the meter; parts are calibrated like [estimatedTokens].
  ContextParts parts() {
    final c = _conv;
    var text = 0, images = 0, imageCount = 0, audio = 0, tools = 0, toolCount = 0, compacted = 0;
    var saved = 0, reduced = 0, described = 0;
    final latest = c == null ? null : _latestImageId(c);
    for (final m in c?.messages ?? const <Message>[]) {
      if (m.compacted) {
        compacted++;
        continue;
      }
      if (_uiOnly(m)) continue;
      text += textTokens(m.text) + 4;
      if (m.image != null) {
        final cost = _imageCost(m, latest);
        images += cost;
        final tier = imageTierOf(m);
        if (tier == ImageTier.reduced) reduced++;
        if (tier == ImageTier.described) described++;
        if (cost > 0 && tier != ImageTier.described) imageCount++;
        saved += _imageSaving(m);
      }
      final a = m.audio;
      if (a != null && _accounting == ContextAccounting.usage) {
        final rate = m.kind == MessageKind.assistant ? audioTokensPerSecond * 2 : audioTokensPerSecond;
        audio += (a.durationMs / 1000 * rate).round();
      }
      final t = m.tool;
      if (t != null) {
        tools += textTokens(t.argsJson) + textTokens(t.resultJson ?? '') + 8;
        toolCount++;
      }
    }
    final s = _scale;
    int k(int v) => (v * s).round();
    return ContextParts(
      overhead: _overhead,
      pinned: _pinned,
      summary: k(_summaryTokens()),
      text: k(text),
      images: k(images),
      imageCount: imageCount,
      audio: k(audio),
      tools: k(tools),
      toolCount: toolCount,
      compactedMessages: compacted,
      total: estimatedTokens,
      measured: measured,
      imagesSaved: k(saved),
      imagesReduced: reduced,
      imagesDescribed: described,
    );
  }

  /// Authoritative size from the backend's usage event (direct mode).
  void onUsage(int contextTokens) {
    final c = _conv;
    if (c == null || _accounting != ContextAccounting.usage) return;
    final ids = <String, int>{};
    var items = _summaryTokens();
    for (final m in c.messages) {
      if (m.compacted) continue;
      final cost = _cost(m, null);
      ids[m.id] = cost;
      items += cost;
    }
    final scale = items <= 0 ? 1.0 : ((contextTokens - _overhead - _pinned) / items).clamp(0.5, 4.0).toDouble();
    _baseline = _Baseline(contextTokens, ids, _summaryTokens(), scale, _pinned);
    notifyListeners();
    maybeCompress();
  }

  /// Call after the conversation changed (message added / updated).
  void onConversationChanged() {
    notifyListeners();
    maybeCompress();
  }

  // ----------------------------------------------------------- compaction

  /// Messages before the [keepRecentTurns]-th last user turn that are still
  /// in the context and finished.
  List<Message> _compactable() {
    final c = _conv;
    if (c == null) return const [];
    final cut = rawTurnsStart(c.messages, keepRecentTurns);
    if (cut == 0) return const [];
    return [
      for (final m in c.messages.take(cut))
        if (!m.compacted && !m.streaming && !_uiOnly(m) && !_toolInFlight(m)) m,
    ];
  }

  static bool _toolInFlight(Message m) {
    final s = m.tool?.status;
    return s == ToolStatus.pending || s == ToolStatus.awaitingApproval || s == ToolStatus.running;
  }

  /// Tokens a compaction of [batch] would free (before the summary is added).
  int _gain(List<Message> batch) {
    final c = _conv!;
    final latest = _latestImageId(c);
    var t = 0;
    for (final m in batch) {
      t += _cost(m, latest);
    }
    return (t * _scale).round();
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
    // Not worth a model call (and a session swap) if it barely helps.
    if (!force && _gain(batch) < (before - _overhead - _pinned) * minGain) return null;
    _compressing = true;
    notifyListeners();
    return _run(_conv!, batch);
  }

  Future<void> _run(Conversation conv, List<Message> batch) async {
    try {
      final result = await compressor.compress(batch, model: compressionModel, previousSummary: conv.summary);
      if (!identical(conv, _conv)) return; // conversation switched meanwhile
      // Re-measure: messages may have been added while compressing.
      final before = estimatedTokens;
      final oldSummary = conv.summary;
      final live = [
        for (final m in batch)
          if (!m.compacted && conv.messages.contains(m)) m,
      ];
      for (final m in live) {
        m.compacted = true;
      }
      conv.summary = result.summary;
      final after = estimatedTokens;
      _lastCompaction = DateTime.now();
      if (after >= before) {
        // The summary is no smaller than what it replaces: keep the messages.
        for (final m in live) {
          m.compacted = false;
        }
        conv.summary = oldSummary;
        lastError = StateError('compaction would not shrink the context ($before → $after tokens)');
        debugPrint('context: $lastError');
        return;
      }
      lastError = null;
      final substantial = before - after >= (before - _overhead - _pinned) * minGain / 2;
      if (!substantial) debugPrint('context: compaction only freed ${before - after} of $before tokens');
      _compactions.add(
        ContextCompacted(
          tokensBefore: before,
          tokensAfter: after,
          compactedMessages: live.length,
          summary: result.summary,
          describedImages: live.where((m) => m.image != null).length,
          substantial: substantial,
        ),
      );
    } catch (e) {
      lastError = e;
      _lastCompaction = DateTime.now();
    } finally {
      _compressing = false;
      notifyListeners();
    }
  }

  /// Plain-text rendering of the messages still in the context (the turns a
  /// compaction keeps), newest last, at most [maxChars]. A new gpt-live
  /// session gets it after the summary so it continues where the last left.
  String recentTurns({int maxChars = 4000}) {
    final c = _conv;
    if (c == null) return '';
    final lines = <String>[];
    var used = 0;
    for (final m in c.messages.reversed) {
      if (m.compacted) break;
      final line = renderForContext(m);
      if (line == null) continue;
      if (used + line.length > maxChars) break;
      used += line.length + 1;
      lines.add(line);
    }
    return lines.reversed.join('\n');
  }

  static String renderTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// One line for a message in a text-only context, or null if it has none.
  static String? renderForContext(Message m, {int maxToolChars = 400}) {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
    final t = m.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final desc = m.image == null ? null : imageDescriptionOf(m);
    final screen = desc == null ? '' : ' [screen: ${clip(desc, 300)}]';
    switch (m.kind) {
      case MessageKind.user:
        return t.isEmpty && screen.isEmpty ? null : 'User: $t$screen'.replaceFirst('User:  [', 'User: [');
      case MessageKind.assistant:
        return t.isEmpty ? null : 'Assistant: $t${m.interrupted ? ' (interrupted)' : ''}';
      case MessageKind.tool:
        final tool = m.tool;
        if (tool == null) return null;
        return 'Tool ${tool.name}(${clip(tool.argsJson, 200)}) -> ${tool.status.name}: '
            '${clip(tool.resultJson ?? '', maxToolChars)}';
      case MessageKind.system:
        return desc == null ? null : 'Earlier screen: ${clip(desc, 300)}';
    }
  }

  @override
  void dispose() {
    _compactions.close();
    super.dispose();
  }
}
