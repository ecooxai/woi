import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// One notification banner.
class BannerData {
  BannerData({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    this.message,
    this.details,
    this.actionLabel,
    this.onAction,
    this.autoDismiss = const Duration(seconds: 8),
  });

  /// Banners with the same id replace each other.
  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String? message;

  /// Full diagnostic text, available without making the notification itself
  /// grow to the size of a log. Opening details does not dismiss the banner.
  final String? details;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration? autoDismiss;
}

/// Text of the compaction banner, e.g.
/// "Context compacted 12.4k → 2.1k — now using new context".
String compactionBannerText(String before, String after) =>
    'Context compacted $before → $after — now using new context';

/// Holds the visible banners; widgets add to it, [BannerStack] shows them.
class BannerController extends ChangeNotifier {
  final _items = <BannerData>[];
  final _timers = <String, Timer>{};
  List<BannerData> get items => List.unmodifiable(_items);

  void show(BannerData b) {
    _items.removeWhere((x) => x.id == b.id);
    _items.insert(0, b);
    if (_items.length > 3) _items.removeRange(3, _items.length);
    _timers.remove(b.id)?.cancel();
    final d = b.autoDismiss;
    if (d != null) _timers[b.id] = Timer(d, () => dismiss(b.id));
    notifyListeners();
  }

  void dismiss(String id) {
    _timers.remove(id)?.cancel();
    final before = _items.length;
    _items.removeWhere((x) => x.id == id);
    if (_items.length != before) notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }
}

/// Animated column of banners (slide + fade in, swipe or ✕ to dismiss).
class BannerStack extends StatefulWidget {
  const BannerStack({super.key, required this.controller, this.maxWidth = 560});
  final BannerController controller;
  final double maxWidth;

  @override
  State<BannerStack> createState() => _BannerStackState();
}

class _BannerStackState extends State<BannerStack> {
  final _listKey = GlobalKey<AnimatedListState>();
  late List<BannerData> _shown = widget.controller.items;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final next = widget.controller.items;
    final list = _listKey.currentState;
    if (list == null) {
      setState(() => _shown = next);
      return;
    }
    // Removals.
    for (var i = _shown.length - 1; i >= 0; i--) {
      final old = _shown[i];
      if (!next.any((n) => identical(n, old))) {
        list.removeItem(i, (context, a) => _animated(old, a), duration: WoiMotion.medium);
      }
    }
    final kept = [
      for (final o in _shown)
        if (next.any((n) => identical(n, o))) o,
    ];
    // Insertions (new items are always at the front).
    for (var i = 0; i < next.length; i++) {
      if (!kept.any((k) => identical(k, next[i]))) {
        kept.insert(i, next[i]);
        list.insertItem(i, duration: WoiMotion.slow);
      }
    }
    setState(() => _shown = kept);
  }

  Widget _animated(BannerData b, Animation<double> a) {
    final curved = CurvedAnimation(parent: a, curve: WoiMotion.emphasized);
    return SizeTransition(
      sizeFactor: curved,
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.4), end: Offset.zero).animate(curved),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: WoiBanner(data: b, onDismiss: () => widget.controller.dismiss(b.id)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: AnimatedList(
        key: _listKey,
        shrinkWrap: true,
        // Shrink to short content so the transcript below remains interactive;
        // when the chat pane is short, longer stacks scroll within its bounds.
        physics: const ClampingScrollPhysics(),
        initialItemCount: _shown.length,
        itemBuilder: (context, i, a) => _animated(_shown[i], a),
      ),
    ),
  );
}

/// A single glassy banner with an accent rail, optional action and ✕.
class WoiBanner extends StatelessWidget {
  const WoiBanner({super.key, required this.data, required this.onDismiss});
  final BannerData data;
  final VoidCallback onDismiss;

  Future<void> _showDetails(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      insetPadding: const EdgeInsets.all(16),
      scrollable: true,
      title: Text(data.title, style: body(16, weight: FontWeight.w600)),
      content: SelectableText(data.details!, style: body(13, color: WoiColors.textDim)),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );

  List<Widget> _actions(BuildContext context, {required bool compact}) => [
    if (data.actionLabel != null && data.onAction != null)
      TextButton(
        onPressed: () {
          data.onAction!();
          onDismiss();
        },
        style: TextButton.styleFrom(
          foregroundColor: data.color,
          minimumSize: compact ? const Size(kTouchTarget, kTouchTarget) : null,
        ),
        child: Text(data.actionLabel!),
      ),
    if (data.details != null)
      TextButton(
        onPressed: () => _showDetails(context),
        style: TextButton.styleFrom(
          foregroundColor: WoiColors.textDim,
          minimumSize: compact ? const Size(kTouchTarget, kTouchTarget) : null,
        ),
        child: const Text('Details'),
      ),
    IconButton(
      tooltip: 'Dismiss',
      onPressed: onDismiss,
      constraints: compact ? const BoxConstraints(minWidth: kTouchTarget, minHeight: kTouchTarget) : null,
      icon: const Icon(Icons.close_rounded, size: 18),
    ),
  ];

  Widget _content() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(data.title, style: body(13.5, weight: FontWeight.w600)),
      if (data.message != null) ...[
        const SizedBox(height: 2),
        Text(data.message!, style: body(12.5, color: WoiColors.textDim)),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: [data.title, ?data.message].join('. '),
    child: Dismissible(
      key: ValueKey('banner-${data.id}-${identityHashCode(data)}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => onDismiss(),
      child: Container(
        decoration: BoxDecoration(
          color: WoiColors.bg1,
          borderRadius: BorderRadius.circular(WoiRadii.md),
          border: Border.all(color: WoiColors.stroke),
          boxShadow: [BoxShadow(color: WoiColors.shadow, blurRadius: 12, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final compact = box.maxWidth < 440 * scale;
            return Stack(
              children: [
                Positioned(top: 0, bottom: 0, left: 0, width: 3, child: ColoredBox(color: data.color)),
                if (compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(15, 8, 8, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _content(),
                        const SizedBox(height: 2),
                        Wrap(alignment: WrapAlignment.end, children: _actions(context, compact: true)),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 15, right: 4),
                    child: Row(
                      children: [
                        Icon(data.icon, color: data.color, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(padding: const EdgeInsets.symmetric(vertical: 11), child: _content()),
                        ),
                        ..._actions(context, compact: false),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
