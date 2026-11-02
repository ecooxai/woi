import 'package:flutter/material.dart';

import '../../core/context/context_manager.dart';
import '../theme.dart';

String formatTokens(int t) {
  if (t >= 100000) return '${(t / 1000).round()}k';
  if (t >= 1000) return '${(t / 1000).toStringAsFixed(1)}k';
  return '$t';
}

/// tokens / threshold bar with a compaction indicator.
class ContextMeter extends StatelessWidget {
  const ContextMeter({super.key, required this.manager, this.compact = false, this.onCompact});

  final ContextManager manager;
  final bool compact;
  final VoidCallback? onCompact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final used = manager.estimatedTokens;
        final limit = manager.threshold;
        final fill = (used / limit).clamp(0.0, 1.0);
        final color = fill < 0.6
            ? WoiColors.cyan
            : fill < 0.9
            ? WoiColors.amber
            : WoiColors.red;
        final label = '${formatTokens(used)} / ${formatTokens(limit)}';
        final bar = ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: Stack(
            children: [
              Container(height: 6, color: WoiColors.glassStrong),
              TweenAnimationBuilder<double>(
                tween: Tween(end: fill),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => FractionallySizedBox(
                  widthFactor: v,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [color.withValues(alpha: 0.6), color]),
                      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        final tooltip =
            'Context ≈ $used tokens; compaction at $limit'
            '${manager.compressing ? ' · compacting…' : ''}';
        if (compact) {
          return Tooltip(
            message: tooltip,
            child: SizedBox(
              width: 120,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(manager.compressing ? Icons.compress : Icons.memory, size: 12, color: color),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          label,
                          style: mono(11, color: WoiColors.textDim),
                          overflow: TextOverflow.fade,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  bar,
                ],
              ),
            ),
          );
        }
        return Tooltip(
          message: tooltip,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    'CONTEXT',
                    style: body(11, weight: FontWeight.w700, color: WoiColors.textFaint).copyWith(letterSpacing: 1.6),
                  ),
                  const Spacer(),
                  if (manager.compressing)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox.square(
                        dimension: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
                      ),
                    ),
                  Text(label, style: mono(12, color: color)),
                  if (onCompact != null) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: manager.compressing ? null : onCompact,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Tooltip(message: 'Compact now', child: Icon(Icons.compress, size: 14)),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              bar,
            ],
          ),
        );
      },
    );
  }
}
