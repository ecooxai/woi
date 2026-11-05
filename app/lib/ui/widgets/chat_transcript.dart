import 'package:flutter/material.dart';

import '../../core/models/message.dart';
import '../theme.dart';

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
  }

  @override
  void didUpdateWidget(ChatTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
          child: Text(label, style: body(11.5, weight: FontWeight.w500, color: WoiColors.textDim)),
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
