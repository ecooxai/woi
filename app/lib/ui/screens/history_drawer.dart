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
    return Drawer(
      width: 360,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Text('History', style: display(20)),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await c.newConversation();
                      if (context.mounted) Navigator.pop(context);
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: FutureBuilder<List<ConversationSummary>>(
                future: _items,
                builder: (context, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final items = snap.data!;
                  if (items.isEmpty) {
                    return Center(
                      child: Text('No saved conversations yet', style: body(13, color: WoiColors.textDim)),
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
                          selected: current,
                          selectedTileColor: WoiColors.cyan.withValues(alpha: 0.08),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          leading: Icon(
                            current ? Icons.graphic_eq : Icons.chat_bubble_outline,
                            size: 20,
                            color: current ? WoiColors.cyan : WoiColors.textDim,
                          ),
                          title: Text(
                            it.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: body(14, weight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            '${it.messageCount} messages · ${_when(it.updatedAt)}',
                            style: body(12, color: WoiColors.textFaint),
                          ),
                          trailing: IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete conversation?'),
                                  content: Text('"${it.title}" and its audio/screenshots will be removed.'),
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
                          onTap: () async {
                            await c.openConversation(it.id);
                            if (context.mounted) Navigator.pop(context);
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
