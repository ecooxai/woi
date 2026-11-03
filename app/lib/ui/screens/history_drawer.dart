import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/storage/history_store.dart';
import '../theme.dart';

/// Conversation history: open, start new, delete.
class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({super.key, required this.controller});
  final AppController controller;

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  late Future<List<ConversationSummary>> _items = _load();

  Future<List<ConversationSummary>> _load() async {
    await widget.controller.history.flush(widget.controller.pipeline.conversation);
    return widget.controller.listConversations();
  }

  void _reload() => setState(() => _items = _load());

  String _when(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (d.inDays < 1 && now.day == t.day) return hm;
    if (d.inDays < 7) return '${d.inDays < 1 ? 'yesterday' : '${d.inDays} d ago'} $hm';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final currentId = c.pipeline.conversation.id;
    final w = MediaQuery.sizeOf(context).width;
    return Drawer(
      width: w < 420 ? w * 0.88 : 360,
      backgroundColor: WoiColors.bg1.withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(WoiRadii.xl)),
        side: BorderSide(color: WoiColors.stroke),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CONVERSATIONS', style: eyebrow()),
                      const SizedBox(height: 2),
                      Semantics(header: true, child: Text('History', style: display(22))),
                    ],
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, kTouchTarget)),
                    // Close first: starting a conversation reconnects the session.
                    onPressed: () {
                      Navigator.pop(context);
                      c.newConversation();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            Divider(color: WoiColors.stroke),
            Expanded(
              child: FutureBuilder<List<ConversationSummary>>(
                future: _items,
                builder: (context, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final items = snap.data!;
                  if (items.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined, size: 36, color: WoiColors.textFaint),
                          const SizedBox(height: 10),
                          Text('No saved conversations yet', style: body(13, color: WoiColors.textDim)),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final it = items[i];
                      final current = it.id == currentId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: ListTile(
                          minTileHeight: 60,
                          selected: current,
                          selectedTileColor: WoiColors.cyan.withValues(alpha: 0.08),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(WoiRadii.md),
                            side: BorderSide(color: current ? WoiColors.cyan.withValues(alpha: 0.3) : Colors.transparent),
                          ),
                          leading: Icon(
                            current ? Icons.graphic_eq : Icons.chat_bubble_outline,
                            size: 20,
                            color: current ? WoiColors.cyan : WoiColors.textDim,
                          ),
                          title: Text(
                            displayTitle(it.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: body(14, weight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            '${it.messageCount} messages · ${_when(it.updatedAt)}',
                            style: body(12, color: WoiColors.textFaint),
                          ),
                          trailing: IconButton(
                            tooltip: 'Delete conversation',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete conversation?'),
                                  content: Text('"${displayTitle(it.title)}" and its audio/screenshots will be removed.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await c.deleteConversation(it.id);
                                _reload();
                              }
                            },
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            c.openConversation(it.id);
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Conversation titles from voice-only turns are placeholders like
/// "[5.0 s of speech]"; show something friendlier.
String displayTitle(String t) {
  final s = t.trim();
  if (s.isEmpty) return 'New conversation';
  final m = RegExp(r'^\[(\d+(?:\.\d+)?) s of speech\]$').firstMatch(s);
  if (m != null) return 'Voice conversation · ${m.group(1)} s';
  return s;
}
