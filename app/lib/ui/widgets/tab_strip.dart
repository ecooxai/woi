import 'package:flutter/material.dart';

import '../../core/app_actions.dart';
import '../theme.dart';

/// The one tab look used across Woi: a label (optionally with an icon) and
/// an accent underline on the selected tab. [primary] tabs are the app's
/// top-level tabs (Note, Chat, Terminal, Settings); secondary tabs (the
/// note's file tabs, terminal tabs) are smaller and quieter. No implicit
/// animations: selection changes repaint once.
class WoiTab extends StatelessWidget {
  const WoiTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.primary = false,
    this.showLabel = true,
    this.badge,
    this.tooltip,
    this.height = 40,
    this.minWidth = 0,
    this.maxWidth = double.infinity,
    this.inkKey,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final bool primary;

  /// Icon-only when false (narrow layouts show only the selected label).
  final bool showLabel;
  final Widget? badge;
  final String? tooltip;
  final double height;
  final double minWidth;
  final double maxWidth;

  /// Key of the tappable area (tests and QA find tabs by it).
  final Key? inkKey;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? WoiColors.text : WoiColors.textDim;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: body(
        primary ? 13.5 : 13,
        weight: selected ? FontWeight.w600 : (primary ? FontWeight.w500 : FontWeight.w400),
        color: fg,
      ),
    );
    final hasLabel = showLabel || icon == null;
    final hPad = primary ? (hasLabel ? 12.0 : 10.0) : 12.0;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip ?? label,
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          key: inkKey,
          onTap: onTap,
          hoverColor: WoiColors.text.withValues(alpha: 0.04),
          focusColor: WoiColors.text.withValues(alpha: 0.06),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(WoiRadii.sm)),
          child: Container(
            height: height,
            constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
            padding: EdgeInsets.symmetric(horizontal: hPad),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: selected ? WoiColors.cyan : Colors.transparent, width: 2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) Icon(icon, size: primary ? 17 : 15, color: selected ? WoiColors.cyan : fg),
                if (icon != null && hasLabel) const SizedBox(width: 7),
                if (hasLabel) Flexible(child: labelText),
                ?badge,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon and label of each top-level tab.
const kHomeTabs = <HomeView, (IconData, String)>{
  HomeView.note: (Icons.description_outlined, 'Note'),
  HomeView.chat: (Icons.chat_bubble_outline_rounded, 'Chat'),
  HomeView.terminal: (Icons.terminal_rounded, 'Terminal'),
  HomeView.clipboard: (Icons.content_paste_rounded, 'Clipboard'),
  HomeView.settings: (Icons.tune_rounded, 'Settings'),
};

/// The app's top-level tabs, left-aligned: Note, Chat, Terminal, Settings
/// (Ctrl+1..4), with activity badges on Note and Chat. In the side-by-side
/// layout both Note and Chat read as selected.
class HomeTabs extends StatelessWidget {
  const HomeTabs({
    super.key,
    required this.view,
    required this.onChanged,
    this.split = false,
    this.noteBadge = false,
    this.chatBadge = 0,
    this.compact = false,
    this.height = 44,
    this.hideChat = false,
    this.selectedTabKey,
  });

  final HomeView view;
  final GlobalKey? selectedTabKey;

  /// Wide two-pane layout: the chat is always on the right, so no Chat tab.
  final bool hideChat;
  final ValueChanged<HomeView> onChanged;

  /// Note and chat are both shown.
  final bool split;
  final bool noteBadge;
  final int chatBadge;

  /// Phone: only the selected tab shows its label.
  final bool compact;
  final double height;

  bool _selected(HomeView v) => v == view || (split && AppActions.isNoteOrChat(v) && AppActions.isNoteOrChat(view));

  @override
  Widget build(BuildContext context) {
    Widget? badgeFor(HomeView v) => switch (v) {
      HomeView.note when noteBadge => Container(
        key: const ValueKey('note-badge'),
        margin: const EdgeInsets.only(left: 6),
        width: 7,
        height: 7,
        decoration: BoxDecoration(shape: BoxShape.circle, color: WoiColors.violet),
      ),
      HomeView.chat when chatBadge > 0 => Container(
        key: const ValueKey('chat-badge'),
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: WoiColors.cyan, borderRadius: BorderRadius.circular(999)),
        child: Text(
          '$chatBadge',
          style: body(10.5, weight: FontWeight.w700, color: WoiColors.onAccent),
        ),
      ),
      _ => null,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final v in HomeView.values)
          if (!(hideChat && v == HomeView.chat))
            WoiTab(
              key: _selected(v) ? selectedTabKey : null,
              inkKey: ValueKey('view-${v.name}'),
              primary: true,
              icon: kHomeTabs[v]!.$1,
              label: kHomeTabs[v]!.$2,
              tooltip:
                  '${kHomeTabs[v]!.$2} (Ctrl+${v == HomeView.settings
                      ? 4
                      : v == HomeView.clipboard
                      ? 5
                      : v.index + 1})',
              selected: _selected(v),
              showLabel: !compact || v == view,
              badge: badgeFor(v),
              height: height,
              minWidth: compact ? kTouchTarget : 0,
              onTap: () => onChanged(v),
            ),
      ],
    );
  }
}

/// The draggable divider between two side-by-side panes: a hairline with
/// a wider grab area. Double-click (or double-tap) resets.
class PaneDivider extends StatelessWidget {
  const PaneDivider({super.key, required this.onDrag, required this.onDragEnd, required this.onReset});

  /// Horizontal drag delta in logical pixels.
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Resize panes',
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        onDoubleTap: onReset,
        child: const SizedBox(width: 9, child: Center(child: VerticalDivider(width: 1))),
      ),
    ),
  );
}
