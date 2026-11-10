import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/clipboard/clipboard_history.dart';
import '../theme.dart';
import '../widgets/thumbnail_image_provider.dart';
import '../widgets/contextual_find.dart';

enum _ClipboardAction { paste, copy, send, remove }

/// Every action closes over the selected snapshot, never the latest clipboard.
class ClipboardPanel extends StatefulWidget {
  const ClipboardPanel({
    super.key,
    required this.history,
    required this.onSendToAi,
    this.onPaste,
    this.pasteLabel = 'Paste into note',
    this.find,
  });

  final ClipboardHistoryController history;
  final Future<void> Function(ClipboardHistoryEntry entry)? onPaste;
  final Future<void> Function(ClipboardHistoryEntry entry) onSendToAi;
  final String pasteLabel;
  final ContextualFindController? find;

  @override
  State<ClipboardPanel> createState() => _ClipboardPanelState();
}

class _ClipboardPanelState extends State<ClipboardPanel> {
  String? _busy;
  final _keys = <String, GlobalKey>{};
  List<ClipboardHistoryEntry> _matches = const [];
  ClipboardHistoryController get history => widget.history;

  @override
  void initState() {
    super.initState();
    _attachFind();
    unawaited(history.load());
  }

  @override
  void didUpdateWidget(ClipboardPanel old) {
    super.didUpdateWidget(old);
    if (old.find != widget.find) {
      old.find?.detach(this);
      _attachFind();
    }
  }

  void _attachFind() => widget.find?.attach(
    this,
    onQuery: () {
      if (mounted) setState(() {});
    },
    onNavigate: (index) {
      if (index < 0 || index >= _matches.length) return;
      final target = _keys[_matches[index].id]?.currentContext;
      if (target != null) unawaited(Scrollable.ensureVisible(target, alignment: 0.25));
      if (mounted) setState(() {});
    },
  );

  @override
  void dispose() {
    widget.find?.detach(this);
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _act(
    ClipboardHistoryEntry entry,
    _ClipboardAction action, {
    Future<void> Function(ClipboardHistoryEntry)? paste,
  }) async {
    if (_busy != null) return;
    setState(() => _busy = entry.id);
    try {
      switch (action) {
        case _ClipboardAction.paste:
          await paste?.call(entry);
        case _ClipboardAction.copy:
          await history.copy(entry);
          _notice(entry.hasImage ? 'Image copied' : 'Text copied');
        case _ClipboardAction.send:
          await widget.onSendToAi(entry);
        case _ClipboardAction.remove:
          await history.remove(entry.id);
      }
    } catch (error) {
      _notice(error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), ''));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear clipboard history?'),
        scrollable: true,
        content: const Text(
          'Remove all saved text and images from Woi’s clipboard history? The current system clipboard stays available.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear history')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await history.clear();
    } catch (error) {
      _notice('$error');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: history,
    builder: (context, _) {
      final query = widget.find?.query.trim().toLowerCase() ?? '';
      final entries = history.entries;
      final retainedIds = {for (final entry in entries) entry.id};
      _keys.removeWhere((id, _) => !retainedIds.contains(id));
      _matches = [
        for (final entry in entries)
          if (query.isEmpty || entry.searchableText.toLowerCase().contains(query)) entry,
      ];
      widget.find?.setMatches(query.isEmpty ? 0 : _matches.length, reveal: false);
      final selected = widget.find?.currentMatch ?? -1;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entries.length} saved ${entries.length == 1 ? 'item' : 'items'}',
                        style: body(14, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text('Select an item to paste, copy, or add to chat.', style: body(12, color: WoiColors.textDim)),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('clipboard-capture'),
                  tooltip: 'Capture current clipboard',
                  onPressed: history.capturing
                      ? null
                      : () async {
                          final entry = await history.capture();
                          if (entry == null && history.error == null) {
                            _notice('No text or image is available on the clipboard.');
                          }
                        },
                  icon: history.capturing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded, size: 21),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Clipboard options',
                  icon: const Icon(Icons.more_vert_rounded, size: 21),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'clear', enabled: entries.isNotEmpty, child: const Text('Clear history…')),
                  ],
                  onSelected: (_) => unawaited(_clear()),
                ),
              ],
            ),
          ),
          if (history.error case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                error,
                key: const ValueKey('clipboard-error'),
                style: body(12, color: WoiColors.red),
              ),
            ),
          Expanded(
            child: history.loading
                ? const Center(child: CircularProgressIndicator())
                : _matches.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.content_paste_rounded, size: 32, color: WoiColors.textFaint),
                          const SizedBox(height: 12),
                          Text(
                            query.isEmpty ? 'Your clipboard history is empty' : 'No matching clipboard items',
                            style: body(15, weight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            query.isEmpty
                                ? 'Copy text or an image while Woi is ${history.supportsBackgroundCapture ? 'running' : 'focused'}, or use Capture to import the current clipboard. Saved items stay here after restarting Woi.'
                                : 'Try a different word or image filename.',
                            style: body(13, color: WoiColors.textDim),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    key: const PageStorageKey('clipboard-history-scroll'),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      children: [
                        for (var i = 0; i < _matches.length; i++)
                          _item(_matches[i], selected: query.isNotEmpty && selected == i),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 10),
            child: Text(
              '${history.retentionLabel}\n${history.supportsBackgroundCapture ? 'Captures in the background while Woi is running.' : 'Captures only while Woi is focused.'}',
              style: body(11, color: WoiColors.textFaint),
            ),
          ),
        ],
      );
    },
  );

  Widget _item(ClipboardHistoryEntry entry, {required bool selected}) {
    final image = entry.content.image;
    final text = entry.content.text;
    final at = entry.copiedAt.toLocal();
    final stamp = '${at.month}/${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return Container(
      key: _keys.putIfAbsent(entry.id, GlobalKey.new),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected ? WoiColors.cyan.withValues(alpha: .07) : WoiColors.bg1,
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: selected ? WoiColors.cyan : WoiColors.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(image == null ? Icons.notes_rounded : Icons.image_outlined, size: 17, color: WoiColors.textDim),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    image?.name ?? 'Text',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: body(12, weight: FontWeight.w600, color: WoiColors.textDim),
                  ),
                ),
                const SizedBox(width: 8),
                Text(stamp, style: body(11, color: WoiColors.textFaint)),
                PopupMenuButton<Future<void> Function()>(
                  key: ValueKey('clipboard-menu-${entry.id}'),
                  tooltip: 'Actions for ${image?.name ?? 'text item'}',
                  enabled: _busy == null,
                  icon: _busy == entry.id
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.more_horiz_rounded, size: 22),
                  itemBuilder: (_) {
                    // The popup label and action form one snapshot. A parent
                    // rebuild or restored focus may change widget.onPaste while
                    // this menu is open, without changing the visible label.
                    final paste = widget.onPaste;
                    return [
                      PopupMenuItem(
                        value: () => _act(entry, _ClipboardAction.paste, paste: paste),
                        enabled: paste != null,
                        child: _menuRow(Icons.content_paste_rounded, widget.pasteLabel),
                      ),
                      PopupMenuItem(
                        value: () => _act(entry, _ClipboardAction.copy),
                        child: _menuRow(Icons.copy_rounded, 'Copy'),
                      ),
                      PopupMenuItem(
                        value: () => _act(entry, _ClipboardAction.send),
                        child: _menuRow(Icons.chat_bubble_outline_rounded, 'Send to AI'),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: () => _act(entry, _ClipboardAction.remove),
                        child: _menuRow(Icons.delete_outline_rounded, 'Remove from history'),
                      ),
                    ];
                  },
                  onSelected: (action) => unawaited(action()),
                ),
              ],
            ),
            if (image != null)
              Align(
                alignment: Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image(
                    image: ThumbnailImage(MemoryImage(image.bytes), width: 480, height: 288),
                    key: ValueKey('clipboard-image-${entry.id}'),
                    height: 120,
                    width: 200,
                    fit: BoxFit.contain,
                    semanticLabel: image.name,
                    errorBuilder: (_, _, _) => SizedBox(
                      width: 200,
                      height: 64,
                      child: Text(
                        'Image preview unavailable. The original bytes are retained.',
                        style: body(12, color: WoiColors.red),
                      ),
                    ),
                  ),
                ),
              ),
            if (text != null && text.isNotEmpty) ...[
              if (image != null) const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  text,
                  key: ValueKey('clipboard-text-${entry.id}'),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: body(13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _menuRow(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 19, color: WoiColors.textDim),
      const SizedBox(width: 12),
      Flexible(child: Text(label, style: body(13))),
    ],
  );
}
