import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/message.dart';
import '../theme.dart';
import 'contextual_find.dart';

/// Messages rendered when a conversation opens.
const kTranscriptInitialWindow = 50;

/// Older messages added each time the user reaches the top.
const kTranscriptLoadStep = 20;

/// Most messages ever rendered; older ones are in History.
const kTranscriptMaxWindow = 200;

/// Builds the bubble for `messages[index]`.
typedef TranscriptTileBuilder = Widget Function(BuildContext context, Message message, int index);

/// The chat transcript: a lazily built, bottom-anchored list of the newest
/// messages with day separators.
///
/// Only the rendering is windowed: it starts with the newest
/// [initialWindow] messages, grows by [loadStep] when the user scrolls to
/// the oldest one (the list is reversed, so the visible messages stay put),
/// up to [maxWindow], where a quiet footer points to History.
///
/// [messages] is the conversation's live list; the owner rebuilds this
/// widget when its shape changes (added / removed messages), each tile
/// follows its own message.
class ChatTranscript extends StatefulWidget {
  const ChatTranscript({
    super.key,
    required this.conversationId,
    required this.messages,
    required this.tileBuilder,
    this.find,
    this.textChanges,
    this.onOpenHistory,
    this.padding = EdgeInsets.zero,
    this.clock = DateTime.now,
    this.initialWindow = kTranscriptInitialWindow,
    this.loadStep = kTranscriptLoadStep,
    this.maxWindow = kTranscriptMaxWindow,
  });

  final String conversationId;
  final List<Message> messages;
  final TranscriptTileBuilder tileBuilder;
  final ContextualFindController? find;

  /// Streaming text changes do not otherwise rebuild the windowed list.
  final Listenable? textChanges;
  final VoidCallback? onOpenHistory;
  final EdgeInsets padding;

  /// "Now" for the day labels (injectable for tests).
  final DateTime Function() clock;

  final int initialWindow;
  final int loadStep;
  final int maxWindow;

  @override
  State<ChatTranscript> createState() => ChatTranscriptState();
}

/// One row of the list (newest first).
sealed class _Entry {
  const _Entry();
  Key get key;
}

class _MessageEntry extends _Entry {
  const _MessageEntry(this.index, this.message);
  final int index;
  final Message message;
  @override
  Key get key => ValueKey(message.id);
}

class _DayEntry extends _Entry {
  const _DayEntry(this.day, this.firstId);
  final DateTime day;

  /// The day's first rendered message (unique even if timestamps are out of order).
  final String firstId;
  @override
  Key get key => ValueKey('day-$firstId');
}

class _HistoryEntry extends _Entry {
  const _HistoryEntry();
  @override
  Key get key => const ValueKey('transcript-history-footer');
}

class ChatTranscriptState extends State<ChatTranscript> {
  final _scroll = ScrollController();
  final _findScroll = ScrollController();
  final _findKeys = <String, GlobalKey>{};
  bool _watchingText = false;
  List<({int message, TextRange range})> _findMatches = const [];
  Timer? _findTimer;
  bool _searching = false;
  double _normalOffset = 0;

  /// Messages rendered (the newest ones).
  late int _window;
  late int _lastLength;
  bool _loadQueued = false;

  /// Within this many pixels of the newest message counts as "at the bottom".
  static const _bottomSlack = 48.0;

  /// Within this many pixels of the oldest rendered message loads more.
  static const _topSlack = 120.0;

  @visibleForTesting
  int get window => _window;

  /// Messages actually rendered.
  @visibleForTesting
  int get renderedCount => _window < widget.messages.length ? _window : widget.messages.length;

  @visibleForTesting
  ScrollController get scrollController => _scroll;

  bool get _atBottom => !_scroll.hasClients || _scroll.position.pixels <= _bottomSlack;

  bool get _canLoadMore => _window < widget.maxWindow && _window < widget.messages.length;

  @override
  void initState() {
    super.initState();
    _window = widget.initialWindow;
    _lastLength = widget.messages.length;
    _attachFind();
  }

  @override
  void didUpdateWidget(ChatTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textChanges != widget.textChanges) {
      oldWidget.textChanges?.removeListener(_onMessageText);
      _watchingText = false;
      _watchTextChanges();
    }
    if (oldWidget.find != widget.find) {
      oldWidget.find?.detach(this);
      _attachFind();
    }
    final len = widget.messages.length;
    if (widget.conversationId != oldWidget.conversationId) {
      _window = widget.initialWindow;
    } else if (len > _lastLength && !_atBottom) {
      // Reading older messages: new ones extend the window (nothing that
      // is on screen drops out). At the bottom the window keeps its size,
      // so the oldest rendered messages drop instead.
      _window = (_window + len - _lastLength).clamp(widget.initialWindow, widget.maxWindow);
    }
    _lastLength = len;
    if (_searching) _refreshFind(reveal: false);
  }

  @override
  void dispose() {
    widget.find?.detach(this);
    _findTimer?.cancel();
    widget.textChanges?.removeListener(_onMessageText);
    _findScroll.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _attachFind() {
    widget.find?.attach(this, onQuery: _refreshFind, onNavigate: _revealFind);
    if (widget.find == null) _refreshFind(reveal: false);
  }

  void _watchTextChanges() {
    if (_watchingText == _searching) return;
    _watchingText = _searching;
    if (_searching) {
      widget.textChanges?.addListener(_onMessageText);
    } else {
      widget.textChanges?.removeListener(_onMessageText);
    }
  }

  void _onMessageText() {
    _findTimer ??= Timer(const Duration(milliseconds: 100), () {
      _findTimer = null;
      if (mounted) _refreshFind(reveal: false);
    });
  }

  void _refreshFind({bool reveal = true}) {
    _findTimer?.cancel();
    _findTimer = null;
    final query = widget.find?.query ?? '';
    final searching = query.trim().isNotEmpty;
    final wasSearching = _searching;
    if (searching && !wasSearching && _scroll.hasClients) _normalOffset = _scroll.offset;
    setState(() {
      _searching = searching;
      // Search the complete conversation, not the normal 50–200-message
      // rendering window. Newest matching messages are shown first.
      _findMatches = [
        if (searching)
          for (var i = widget.messages.length - 1; i >= 0; i--)
            for (final range in findTextRanges(widget.messages[i].text, query)) (message: i, range: range),
      ];
    });
    _watchTextChanges();
    widget.find?.setMatches(_findMatches.length, reveal: reveal);
    if (wasSearching && !searching) {
      _findKeys.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _searching || !_scroll.hasClients) return;
        _scroll.jumpTo(_normalOffset.clamp(0.0, _scroll.position.maxScrollExtent).toDouble());
      });
    }
  }

  void _revealFind(int index) {
    if (index < 0 || index >= _findMatches.length) return;
    final match = _findMatches[index];
    if (match.message >= widget.messages.length || match.range.end > widget.messages[match.message].text.length) {
      _refreshFind();
      return;
    }
    final message = widget.messages[match.message];
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searching || widget.find?.currentMatch != index) return;
      final context = _findKeys[message.id]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(context, alignment: 0.1, duration: const Duration(milliseconds: 160));
      }
    });
  }

  Widget _findResults() {
    if (_findMatches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No messages match "${widget.find?.query ?? ''}"', key: const ValueKey('chat-find-empty')),
        ),
      );
    }
    final selected = _findMatches[widget.find!.currentMatch];
    final messages = _findMatches.map((match) => match.message).toSet().toList();
    final position = messages.indexOf(selected.message);
    // Bound expensive message widgets while allowing navigation to every
    // result. All rows in this small search window are mounted, making the
    // selected result's scroll position exact even for very long messages.
    final start = math.max(0, position - 5);
    final end = math.min(messages.length, start + 16);
    return SingleChildScrollView(
      key: ValueKey('transcript-find-${widget.conversationId}'),
      controller: _findScroll,
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final index in messages.sublist(start, end))
            Container(
              key: _findKeys.putIfAbsent(widget.messages[index].id, () => GlobalKey()),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: index == selected.message ? Border.all(color: WoiColors.cyan.withValues(alpha: 0.6)) : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (index == selected.message) _findSnippet(widget.messages[index].text, selected.range),
                  widget.tileBuilder(context, widget.messages[index], index),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _findSnippet(String text, TextRange range) {
    // A streaming edit can shorten text before the throttled refresh runs.
    range = TextRange(start: range.start.clamp(0, text.length), end: range.end.clamp(0, text.length));
    final start = math.max(0, range.start - 60);
    final end = math.min(text.length, range.end + 100);
    String compact(String part) => part.replaceAll(RegExp(r'\s+'), ' ');
    return Padding(
      key: const ValueKey('chat-find-current'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${start > 0 ? '…' : ''}${compact(text.substring(start, range.start))}'),
            TextSpan(
              text: compact(text.substring(range.start, range.end)),
              style: TextStyle(backgroundColor: WoiColors.cyan.withValues(alpha: 0.3), fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '${compact(text.substring(range.end, end))}${end < text.length ? '…' : ''}'),
          ],
        ),
        style: body(12.5, color: WoiColors.text),
      ),
    );
  }

  /// Renders [loadStep] more older messages (capped at [maxWindow]).
  /// Returns whether the window grew.
  bool loadMore() {
    if (!_canLoadMore) return false;
    setState(() {
      final next = _window + widget.loadStep;
      _window = next > widget.maxWindow ? widget.maxWindow : next;
    });
    return true;
  }

  bool _onScroll(ScrollNotification n) {
    if (_searching) return false;
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final nearTop = n.metrics.extentAfter <= _topSlack;
    final pushingTop = n is OverscrollNotification && n.overscroll > 0;
    if ((nearTop || pushingTop) && (n is ScrollUpdateNotification || n is OverscrollNotification) && !_loadQueued) {
      if (_canLoadMore) {
        // One step per frame, however many notifications arrive.
        _loadQueued = true;
        loadMore();
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadQueued = false);
      }
    }
    return false;
  }

  /// Newest first: messages, a day chip above each day's first message,
  /// and the History footer above everything once the cap is reached.
  List<_Entry> _entries() {
    final msgs = widget.messages;
    final start = msgs.length - renderedCount;
    final out = <_Entry>[];
    for (var i = msgs.length - 1; i >= start; i--) {
      out.add(_MessageEntry(i, msgs[i]));
      final day = _day(msgs[i].createdAt);
      if (i == start || _day(msgs[i - 1].createdAt) != day) out.add(_DayEntry(day, msgs[i].id));
    }
    if (start > 0 && _window >= widget.maxWindow) out.add(const _HistoryEntry());
    return out;
  }

  static DateTime _day(DateTime t) {
    final l = t.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  @override
  Widget build(BuildContext context) {
    if (_searching) return _findResults();
    final entries = _entries();
    final index = <Key, int>{for (var i = 0; i < entries.length; i++) entries[i].key: i};
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        // A new conversation starts at its newest message.
        key: ValueKey('transcript-${widget.conversationId}'),
        controller: _scroll,
        reverse: true,
        padding: widget.padding,
        itemCount: entries.length,
        findChildIndexCallback: (key) => index[key],
        itemBuilder: (context, i) => switch (entries[i]) {
          final _MessageEntry e => KeyedSubtree(key: e.key, child: widget.tileBuilder(context, e.message, e.index)),
          final _DayEntry e => DayChip(key: e.key, label: dayLabel(e.day, widget.clock())),
          final _HistoryEntry e => _HistoryFooter(key: e.key, onOpenHistory: widget.onOpenHistory),
        },
      ),
    );
  }
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Today", "Yesterday", the weekday within the last week, otherwise
/// "Mar 4" (plus the year when it isn't this year's).
String dayLabel(DateTime day, DateTime now) {
  final d = day.toLocal();
  final n = now.toLocal();
  // Calendar-day difference, immune to DST hour shifts.
  final diff = DateTime.utc(n.year, n.month, n.day).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[d.weekday - 1];
  final md = '${_months[d.month - 1]} ${d.day}';
  return d.year == n.year ? md : '$md, ${d.year}';
}

/// A centered, subtle date chip between days.
class DayChip extends StatelessWidget {
  const DayChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: WoiColors.bg2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: WoiColors.stroke),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Text(
            label,
            style: body(11.5, weight: FontWeight.w500, color: WoiColors.textDim),
          ),
        ),
      ),
    ),
  );
}

/// At the cap: older messages live in History.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({super.key, this.onOpenHistory});

  final VoidCallback? onOpenHistory;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    child: Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        children: [
          Text('Older messages are in History', style: body(12, color: WoiColors.textFaint)),
          if (onOpenHistory != null)
            TextButton(
              key: const ValueKey('transcript-open-history'),
              onPressed: onOpenHistory,
              style: TextButton.styleFrom(
                foregroundColor: WoiColors.textDim,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                textStyle: body(12, weight: FontWeight.w600),
              ),
              child: const Text('Open History'),
            ),
        ],
      ),
    ),
  );
}
