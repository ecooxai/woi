import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/notes/note.dart';
import '../../core/storage/history_store.dart';
import '../theme.dart';
import '../widgets/tab_strip.dart';

/// How many recent notes get their own tab.
const kNoteTabs = 4;

/// One tab entry.
class NoteTabItem {
  const NoteTabItem({required this.id, required this.title, this.updatedAt, this.current = false});
  final String id;
  final String title;
  final DateTime? updatedAt;
  final bool current;
}

/// The tabs for [all] (newest first): the [max] most recent notes, with the
/// current one always included (it replaces the last tab when it is older,
/// and is added first when it is not saved yet). Returns (tabs, rest).
(List<NoteTabItem>, List<NoteTabItem>) splitNoteTabs(
  List<ConversationSummary> all, {
  required String currentId,
  required String currentTitle,
  int max = kNoteTabs,
}) {
  final items = [
    for (final s in all)
      NoteTabItem(
        id: s.id,
        title: s.id == currentId ? currentTitle : s.title,
        updatedAt: s.updatedAt,
        current: s.id == currentId,
      ),
  ];
  if (!items.any((i) => i.current)) {
    items.insert(0, NoteTabItem(id: currentId, title: currentTitle, current: true));
  }
  final tabs = items.take(max).toList();
  if (!tabs.any((t) => t.current)) {
    tabs[tabs.length - 1] = items.firstWhere((i) => i.current);
  }
  final ids = {for (final t in tabs) t.id};
  return (
    tabs,
    [
      for (final i in items)
        if (!ids.contains(i.id)) i,
    ],
  );
}

/// Title of the active conversation's note tab.
String currentNoteTitle(AppController c) {
  final conv = c.pipeline.conversation;
  if (!c.usesNoteTitle && conv.title.isNotEmpty) return conv.title;
  final t = noteTitle(c.notes.text, max: 40);
  return t.isEmpty ? 'New note' : t;
}

/// Recent notes as tabs, a "More" button with a searchable list of the
/// others, and a "New note" button on the right.
class NoteTabsBar extends StatefulWidget {
  const NoteTabsBar({super.key, required this.controller, this.compact = false, this.trailing});
  final AppController controller;

  /// Phone: 48dp tall tabs, scrollable.
  final bool compact;

  /// Extra actions between "More" and "New note".
  final Widget? trailing;

  @override
  State<NoteTabsBar> createState() => _NoteTabsBarState();
}

class _NoteTabsBarState extends State<NoteTabsBar> {
  final _moreKey = GlobalKey();
  List<ConversationSummary> _all = const [];
  String? _convId;
  int _listRevision = -1;
  String _title = '';
  Timer? _titleDebounce;
  Future<void>? _reloadFuture;
  bool _reloadPending = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant NoteTabsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, c)) return;
    oldWidget.controller.removeListener(_onController);
    oldWidget.controller.notes.removeListener(_onNotes);
    _titleDebounce?.cancel();
    _titleDebounce = null;
    _all = const [];
    _listen();
  }

  void _listen() {
    _convId = c.pipeline.conversation.id;
    _listRevision = c.conversationListRevision;
    _title = currentNoteTitle(c);
    c.addListener(_onController);
    c.notes.addListener(_onNotes);
    _reload();
  }

  @override
  void dispose() {
    _titleDebounce?.cancel();
    c.removeListener(_onController);
    c.notes.removeListener(_onNotes);
    super.dispose();
  }

  void _onController() {
    final id = c.pipeline.conversation.id;
    final revision = c.conversationListRevision;
    if (id == _convId && revision == _listRevision) return;
    _convId = id;
    _listRevision = revision;
    _title = currentNoteTitle(c);
    _reload();
  }

  /// The current tab's title follows the note's first line; checked at most
  /// a few times per second so typing does not rebuild the bar.
  void _onNotes() {
    _titleDebounce ??= Timer(const Duration(milliseconds: 400), () {
      _titleDebounce = null;
      final t = currentNoteTitle(c);
      if (t != _title && mounted) setState(() => _title = t);
    });
  }

  Future<void> _reload() {
    _reloadPending = true;
    if (_reloadFuture case final pending?) return pending;
    final done = Completer<void>();
    _reloadFuture = done.future;
    unawaited(_drainReloads(done));
    return done.future;
  }

  /// One filesystem read at a time. A switch or mutation during the read
  /// requests one fresh snapshot and prevents the older result being shown.
  Future<void> _drainReloads(Completer<void> done) async {
    try {
      while (mounted && _reloadPending) {
        _reloadPending = false;
        final controller = c;
        final all = await controller.actions.listNotes();
        if (!mounted) break;
        if (_reloadPending || !identical(controller, c)) continue;
        setState(() {
          _all = all;
          _title = currentNoteTitle(c);
        });
      }
    } catch (error, stack) {
      done.completeError(error, stack);
    } finally {
      _reloadFuture = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _open(String id) async {
    if (id == c.pipeline.conversation.id) return;
    await c.history.flush(c.pipeline.conversation);
    await c.actions.openNote(id);
  }

  Future<void> _more() async {
    await _reload();
    if (!mounted) return;
    final (_, fresh) = splitNoteTabs(_all, currentId: c.pipeline.conversation.id, currentTitle: _title);
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final id = await Navigator.of(context).push<String>(_NotePickerRoute(anchor: rect, items: fresh));
    if (id != null) await _open(id);
  }

  @override
  Widget build(BuildContext context) {
    final (tabs, rest) = splitNoteTabs(_all, currentId: c.pipeline.conversation.id, currentTitle: _title);
    final h = widget.compact ? kTouchTarget : 40.0;
    return SizedBox(
      height: h,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final t in tabs) _Tab(item: t, height: h, compact: widget.compact, onTap: () => _open(t.id)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            key: _moreKey,
            message: rest.isEmpty ? 'No other notes' : 'All notes',
            child: TextButton.icon(
              key: const ValueKey('note-tab-more'),
              onPressed: _more,
              style: TextButton.styleFrom(
                foregroundColor: WoiColors.textDim,
                minimumSize: Size(widget.compact ? kTouchTarget : 0, h - 4),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: body(13, weight: FontWeight.w500),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoiRadii.sm + 2)),
              ),
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              label: Text(rest.isEmpty ? 'More' : 'More (${rest.length})'),
            ),
          ),
          ?widget.trailing,
          const SizedBox(width: 2),
          Tooltip(
            message: 'New note (Ctrl+N)',
            child: IconButton(
              key: const ValueKey('note-new'),
              onPressed: c.actions.newNote,
              style: IconButton.styleFrom(
                minimumSize: Size.square(widget.compact ? kTouchTarget : 36),
                foregroundColor: WoiColors.text,
              ),
              icon: const Icon(Icons.add_rounded, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.height, required this.onTap, this.compact = false});
  final NoteTabItem item;
  final double height;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WoiTab(
    inkKey: ValueKey('note-tab-${item.id}'),
    label: item.title,
    tooltip: 'Note: ${item.title}',
    selected: item.current,
    onTap: onTap,
    height: height,
    minWidth: compact ? 64 : 72,
    maxWidth: compact ? 150 : 200,
  );
}

/// Searchable list of notes shown under the "More" button.
class _NotePickerRoute extends PopupRoute<String> {
  _NotePickerRoute({required this.anchor, required this.items});
  final Rect anchor;
  final List<NoteTabItem> items;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close notes list';

  @override
  Duration get transitionDuration => WoiMotion.fast;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final screen = MediaQuery.sizeOf(context);
    final w = (screen.width - 16).clamp(200.0, 360.0);
    final left = (anchor.right - w).clamp(8.0, screen.width - w - 8);
    final top = anchor.bottom + 4;
    final maxH = (screen.height - top - 16).clamp(160.0, 440.0);
    return FadeTransition(
      opacity: animation,
      child: Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: w,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  decoration: surfaceDecoration(radius: WoiRadii.md, elevated: true),
                  child: _NotePicker(items: items),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotePicker extends StatefulWidget {
  const _NotePicker({required this.items});
  final List<NoteTabItem> items;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  String _q = '';

  String _when(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    if (d.inDays < 30) return '${d.inDays}d';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty ? widget.items : widget.items.where((i) => i.title.toLowerCase().contains(q)).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const ValueKey('note-more-search'),
            autofocus: true,
            onChanged: (v) => setState(() => _q = v),
            onSubmitted: (_) {
              if (shown.isNotEmpty) Navigator.pop(context, shown.first.id);
            },
            style: body(14),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search notes',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        ),
        Divider(height: 1, color: WoiColors.stroke),
        Flexible(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    widget.items.isEmpty ? 'No other notes yet.' : 'No notes match "$_q".',
                    textAlign: TextAlign.center,
                    style: body(13, color: WoiColors.textDim),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final it = shown[i];
                    return InkWell(
                      key: ValueKey('note-more-item-${it.id}'),
                      onTap: () => Navigator.pop(context, it.id),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: kTouchTarget - 4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              Icon(Icons.description_outlined, size: 16, color: WoiColors.textFaint),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(13.5)),
                              ),
                              const SizedBox(width: 8),
                              Text(_when(it.updatedAt), style: body(12, color: WoiColors.textFaint)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
