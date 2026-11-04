import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/auth/auth.dart';
import '../../core/usage/codex_usage.dart';
import '../../core/util/usage_limit.dart';
import '../theme.dart';

/// "14:31" today, "Mon 14:31" within the next 6 days, else "Thu 5 Nov 14:31".
String formatUsageReset(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final hm = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  final days = DateTime(l.year, l.month, l.day).difference(DateTime(n.year, n.month, n.day)).inDays;
  if (days == 0) return hm;
  if (days > 0 && days < 7) return '${_weekdays[l.weekday - 1]} $hm';
  return UsageLimit.formatReset(l);
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// ChatGPT/Codex usage: "5h 34% used · week 71% used", the reset times, and
/// which model delegation/compaction actually use when the usage guard
/// overrides the selection. Self-contained: give it the [AppController].
class CodexUsageMeter extends StatelessWidget {
  const CodexUsageMeter({super.key, required this.controller, this.now});

  final AppController controller;

  /// Clock for the reset times (tests).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.usage]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final usage = controller.usage;
    final s = usage.snapshot;
    final threshold = controller.settings.usageGuardPercent;
    final t = now?.call() ?? DateTime.now();
    final lines = <Widget>[];
    if (s == null) {
      lines.add(
        Text(
          usage.error != null
              ? 'Usage unavailable (${usage.error})'
              : controller.settings.authMode == AuthMode.codex
              ? 'No usage data yet'
              : 'Only with a ChatGPT login',
          style: body(12.5, color: WoiColors.textDim),
        ),
      );
    } else {
      lines.add(Text(s.compact, key: const Key('usage-compact'), style: mono(13)));
      for (final (label, w) in [(s.primaryLabel, s.primary), (s.secondaryLabel, s.secondary)]) {
        if (w == null) continue;
        lines.add(const SizedBox(height: 6));
        lines.add(_bar(label, w, threshold, t));
      }
      final meta = [
        if (s.plan != null) 'plan ${s.plan}',
        'updated ${formatUsageReset(s.updatedAt, now: t)}',
      ].join(' · ');
      lines.add(const SizedBox(height: 6));
      lines.add(Text(meta, style: body(11.5, color: WoiColors.textFaint)));
    }
    for (final (what, c) in [('Compaction', controller.compactionChoice), ('Delegation', controller.delegationChoice)]) {
      if (!c.downgraded) continue;
      lines.add(const SizedBox(height: 6));
      lines.add(
        Text(
          '$what: ${c.model} (${c.reason})',
          key: Key('usage-guard-${what.toLowerCase()}'),
          style: body(12, color: WoiColors.amber, height: 1.3),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
        ),
        IconButton(
          tooltip: 'Refresh usage',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () => usage.refresh(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _bar(String label, UsageWindow w, int threshold, DateTime now) {
    final low = threshold > 0 && w.remainingPercent < threshold;
    final r = w.resetsAt;
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label, style: body(11.5, color: WoiColors.textDim))),
        Expanded(
          flex: 2,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (w.usedPercent / 100).clamp(0, 1).toDouble(),
              minHeight: 5,
              backgroundColor: WoiColors.bg3,
              color: low ? WoiColors.amber : WoiColors.cyan,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 3,
          child: Text(
            r == null ? '${w.remainingPercent.round()}% left' : 'resets ${formatUsageReset(r, now: now)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: body(11.5, color: low ? WoiColors.amber : WoiColors.textDim),
          ),
        ),
      ],
    );
  }
}
