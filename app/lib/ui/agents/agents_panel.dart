import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/agents/agent_runs.dart';
import '../theme.dart';
import '../widgets/contextual_find.dart';

enum _RunFilter { all, active, completed, failed, cancelled }

/// The task store is the sole source of status and results. This view never
/// starts a task or manufactures progress when a provider has not reported it.
class AgentsPanel extends StatefulWidget {
  const AgentsPanel({super.key, required this.store, this.find});
  final AgentRunStore store;
  final ContextualFindController? find;

  @override
  State<AgentsPanel> createState() => _AgentsPanelState();
}

class _AgentsPanelState extends State<AgentsPanel> {
  String? _selectedId;
  _RunFilter _filter = _RunFilter.all;
  List<AgentRun> _matches = const [];

  @override
  void initState() {
    super.initState();
    _attachFind();
  }

  @override
  void didUpdateWidget(AgentsPanel old) {
    super.didUpdateWidget(old);
    if (old.find != widget.find) {
      old.find?.detach(this);
      _attachFind();
    }
  }

  void _attachFind() => widget.find?.attach(
    this,
    onQuery: () {
      if (mounted) setState(() => _selectedId = null);
    },
    onNavigate: (index) {
      if (!mounted || index < 0 || index >= _matches.length) return;
      setState(() => _selectedId = _matches[index].id);
    },
  );

  @override
  void dispose() {
    widget.find?.detach(this);
    super.dispose();
  }

  bool _included(AgentRun run) => switch (_filter) {
    _RunFilter.all => true,
    _RunFilter.active => run.status == AgentRunStatus.queued || run.status == AgentRunStatus.running,
    _RunFilter.completed => run.status == AgentRunStatus.completed,
    _RunFilter.failed => run.status == AgentRunStatus.failed,
    _RunFilter.cancelled => run.status == AgentRunStatus.cancelled,
  };

  String _searchText(AgentRun run) => [
    run.task, run.model, run.toolName, run.status.name, run.result ?? '', run.error ?? '',
    for (final step in run.steps) '${step.toolName}\n${step.arguments}\n${step.result ?? ''}',
  ].join('\n').toLowerCase();

  void _cancel(AgentRun run) {
    if (widget.store.cancel(run.id)) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('This run is no longer cancellable.')),
    );
  }

  Future<void> _loadOlder() async {
    try {
      await widget.store.loadOlder();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not load agent history: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final all = widget.store.runs;
      final query = widget.find?.query.trim().toLowerCase() ?? '';
      _matches = [
        for (final run in all)
          if (_included(run) && (query.isEmpty || _searchText(run).contains(query))) run,
      ];
      widget.find?.setMatches(query.isEmpty ? 0 : _matches.length, reveal: false);
      final selected = all.where((run) => run.id == _selectedId).firstOrNull;
      return LayoutBuilder(
        builder: (context, box) {
          final split = box.maxWidth >= 760;
          final detail = selected ?? (split ? _matches.firstOrNull : null);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Icon(Icons.account_tree_outlined, size: 22, color: WoiColors.cyan),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Agents', style: display(20)),
                          const SizedBox(height: 3),
                          Text(
                            '${_count(all.length, 'loaded run')} · ${widget.store.activeCount} active',
                            style: body(12, color: WoiColors.textDim),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (split || detail == null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      for (final filter in _RunFilter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: ChoiceChip(
                            key: ValueKey('agent-filter-${filter.name}'),
                            label: Text(switch (filter) {
                              _RunFilter.all => 'All',
                              _RunFilter.active => 'Active',
                              _RunFilter.completed => 'Completed',
                              _RunFilter.failed => 'Failed',
                              _RunFilter.cancelled => 'Cancelled',
                            }),
                            selected: filter == _filter,
                            onSelected: (_) => setState(() {
                              _filter = filter;
                              _selectedId = null;
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              Divider(height: 1, color: WoiColors.stroke),
              Expanded(
                child: split
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 310, child: _list(all.isEmpty, query, detail?.id)),
                          VerticalDivider(width: 1, color: WoiColors.stroke),
                          Expanded(
                            child: detail == null
                                ? const _EmptyAgents(title: 'Select a run', message: 'Its task, tool activity and result appear here.')
                                : _AgentRunDetail(run: detail, onCancel: () => _cancel(detail)),
                          ),
                        ],
                      )
                    : detail == null
                    ? _list(all.isEmpty, query, null)
                    : _AgentRunDetail(
                        run: detail,
                        onBack: () => setState(() => _selectedId = null),
                        onCancel: () => _cancel(detail),
                      ),
              ),
            ],
          );
        },
      );
    },
  );

  Widget _list(bool empty, String query, String? selectedId) {
    if (empty) {
      return Column(
        children: [
          Expanded(child: _EmptyAgents(
            title: widget.store.loading ? 'Loading agent history…' : widget.store.loadError == null ? 'No agent runs yet' : 'Agent history unavailable',
            message: 'Tasks delegated to GPT Luna appear here with their actual status, tool activity and result.',
          )),
          _historyFooter(),
        ],
      );
    }
    if (_matches.isEmpty) {
      return Column(
        children: [
          Expanded(child: _EmptyAgents(
            title: query.isEmpty ? 'No runs in this category' : 'No matching loaded runs',
            message: query.isEmpty ? 'Choose All to see loaded task history.' : 'Try another query or load older task history.',
          )),
          _historyFooter(),
        ],
      );
    }
    return ListView.builder(
      key: const ValueKey('agent-runs-list'),
      padding: const EdgeInsets.all(12),
      itemCount: _matches.length + 1,
      itemBuilder: (context, index) {
        if (index == _matches.length) return _historyFooter();
        final run = _matches[index];
        return _AgentRunCard(
          key: ValueKey('agent-run-${run.id}'),
          run: run,
          selected: run.id == selectedId,
          onTap: () => setState(() => _selectedId = run.id),
        );
      },
    );
  }

  Widget _historyFooter() {
    final store = widget.store;
    if (!store.hasMore && !store.loading && store.loadError == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (store.loadError case final String error) ...[
            Text(error, style: body(12, color: WoiColors.red)),
            const SizedBox(height: 8),
          ],
          if (store.hasMore || store.loading) OutlinedButton.icon(
            key: const ValueKey('agents-load-older'),
            onPressed: store.loading ? null : _loadOlder,
            icon: store.loading
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.history_rounded, size: 18),
            label: Text(store.loading ? 'Loading…' : 'Load older runs'),
          ),
        ],
      ),
    );
  }
}

class _AgentRunCard extends StatelessWidget {
  const _AgentRunCard({super.key, required this.run, required this.selected, required this.onTap});
  final AgentRun run;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Material(
      color: selected ? WoiColors.cyan.withValues(alpha: 0.06) : WoiColors.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? WoiColors.cyan : WoiColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _RunStatus(run: run),
                  const Spacer(),
                  Icon(Icons.chevron_right_rounded, size: 19, color: WoiColors.textFaint),
                ],
              ),
              const SizedBox(height: 9),
              Text(run.task, maxLines: 3, overflow: TextOverflow.ellipsis, style: body(14, weight: FontWeight.w600, height: 1.4)),
              const SizedBox(height: 8),
              Text('${run.toolName} · ${run.model}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11, color: WoiColors.textDim)),
              const SizedBox(height: 5),
              Text(_timestamp(run.createdAt), style: body(11.5, color: WoiColors.textFaint)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AgentRunDetail extends StatelessWidget {
  const _AgentRunDetail({required this.run, required this.onCancel, this.onBack});
  final AgentRun run;
  final VoidCallback onCancel;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: ValueKey('agent-detail-${run.id}'),
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onBack != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('agents-back'),
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('All agents'),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _RunStatus(run: run),
            if (run.canCancel || run.cancellationRequested)
              OutlinedButton.icon(
                key: ValueKey('agent-cancel-${run.id}'),
                onPressed: run.canCancel && !run.cancellationRequested ? onCancel : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(run.cancellationRequested ? 'Cancellation requested' : 'Cancel run'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Semantics(header: true, child: SelectableText(run.task, style: display(19).copyWith(height: 1.35))),
        const SizedBox(height: 14),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _RunMetadata(label: 'Model', value: run.model),
            _RunMetadata(label: 'Tool', value: run.toolName),
            _RunMetadata(label: 'Created', value: _timestamp(run.createdAt)),
            if (run.startedAt case final DateTime started) _RunMetadata(label: 'Started', value: _timestamp(started)),
            if (run.finishedAt case final DateTime finished) _RunMetadata(label: 'Finished', value: _timestamp(finished)),
          ],
        ),
        const SizedBox(height: 20),
        if (run.error case final String error when error.isNotEmpty) ...[
          _DetailBlock(title: 'Error', text: error, error: true),
          const SizedBox(height: 14),
        ],
        if (run.result case final String result)
          _DetailBlock(title: 'Result', text: result, json: true)
        else
          Text(
            switch (run.status) {
              AgentRunStatus.queued => 'Waiting to start.',
              AgentRunStatus.running => 'Running. Recorded tool activity appears below.',
              AgentRunStatus.completed => 'Completed without a recorded result.',
              AgentRunStatus.failed => 'No result was recorded for this failed run.',
              AgentRunStatus.cancelled => 'This run was cancelled.',
            },
            style: body(13, color: WoiColors.textDim, height: 1.5),
          ),
        if (run.steps.isNotEmpty) ...[
          const SizedBox(height: 22),
          Semantics(header: true, child: Text('Tool activity', style: body(15, weight: FontWeight.w600))),
          const SizedBox(height: 9),
          for (var index = 0; index < run.steps.length; index++)
            _ToolStep(key: ValueKey('agent-step-${run.id}-$index'), step: run.steps[index], number: index + 1),
        ],
      ],
    ),
  );
}

class _RunMetadata extends StatelessWidget {
  const _RunMetadata({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: body(11, color: WoiColors.textFaint)),
      const SizedBox(height: 3),
      SelectableText(value, style: mono(11.5, color: WoiColors.textDim)),
    ],
  );
}

class _ToolStep extends StatelessWidget {
  const _ToolStep({super.key, required this.step, required this.number});
  final AgentStep step;
  final int number;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: DecoratedBox(
      decoration: BoxDecoration(border: Border.all(color: WoiColors.stroke), borderRadius: BorderRadius.circular(10)),
      child: ExpansionTile(
        title: Text('$number. ${step.toolName}', style: body(13.5, weight: FontWeight.w600)),
        subtitle: Text(
          '${step.finishedAt == null ? 'Started' : 'Finished'} · ${_timestamp(step.finishedAt ?? step.startedAt)}',
          style: body(11.5, color: WoiColors.textDim),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DetailBlock(title: 'Arguments', text: step.arguments, json: true),
          const SizedBox(height: 12),
          _DetailBlock(title: 'Tool result', text: step.result ?? 'No result recorded yet.', json: true),
        ],
      ),
    ),
  );
}

class _DetailBlock extends StatefulWidget {
  const _DetailBlock({required this.title, required this.text, this.error = false, this.json = false});
  final String title;
  final String text;
  final bool error;
  final bool json;

  @override
  State<_DetailBlock> createState() => _DetailBlockState();
}

class _DetailBlockState extends State<_DetailBlock> {
  late bool _expanded = widget.text.length <= 8192;
  String? _rendered;

  @override
  void didUpdateWidget(_DetailBlock old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.json != widget.json) _rendered = null;
    if ((old.text.length <= 8192) != (widget.text.length <= 8192)) _expanded = widget.text.length <= 8192;
  }

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: widget.error ? WoiColors.red.withValues(alpha: 0.05) : WoiColors.glass,
      border: Border.all(color: widget.error ? WoiColors.red.withValues(alpha: 0.25) : WoiColors.stroke),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: body(12, weight: FontWeight.w600, color: widget.error ? WoiColors.red : WoiColors.textDim)),
        const SizedBox(height: 8),
        if (widget.text.length > 8192)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
              label: Text('${_expanded ? 'Fold' : 'Show complete'} ${widget.title.toLowerCase()} · ${widget.text.length} characters'),
            ),
          ),
        if (_expanded)
          SelectableText(
            widget.text.isEmpty ? '(empty)' : (_rendered ??= widget.json ? _pretty(widget.text) : widget.text),
            style: mono(12.5, color: WoiColors.text).copyWith(height: 1.5),
          ),
      ],
    ),
  );
}

class _RunStatus extends StatelessWidget {
  const _RunStatus({required this.run});
  final AgentRun run;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (run.status) {
      AgentRunStatus.queued => ('Queued', WoiColors.amber),
      AgentRunStatus.running => ('Running', WoiColors.cyan),
      AgentRunStatus.completed => ('Completed', WoiColors.mint),
      AgentRunStatus.failed => ('Failed', WoiColors.red),
      AgentRunStatus.cancelled => ('Cancelled', WoiColors.textDim),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: body(11.5, weight: FontWeight.w600, color: color)),
    );
  }
}

class _EmptyAgents extends StatelessWidget {
  const _EmptyAgents({required this.title, required this.message});
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 36, color: WoiColors.textFaint),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: body(16, weight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center, style: body(13, color: WoiColors.textDim, height: 1.5)),
        ],
      ),
    ),
  );
}

String _pretty(String source) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
  } on FormatException {
    return source;
  }
}

String _timestamp(DateTime at) {
  final value = at.toLocal();
  String two(int number) => '$number'.padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

String _count(int count, String word) => '$count $word${count == 1 ? '' : 's'}';
