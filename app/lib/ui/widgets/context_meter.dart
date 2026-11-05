import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/context/context_manager.dart';
import '../../core/models/message.dart';
import '../theme.dart';
import 'low_fps.dart';

String formatTokens(int t) => formatTokenCount(t);

/// Where the context tokens go: the parts of [ContextManager.estimatedTokens].
class ContextBreakdown {
  const ContextBreakdown({
    this.overhead = 0,
    this.note = 0,
    required this.summary,
    required this.text,
    required this.images,
    required this.imageCount,
    required this.audio,
    required this.tools,
    required this.toolCount,
    required this.total,
    required this.threshold,
    required this.compactedMessages,
    this.measured = false,
    this.textOnly = false,
    this.imagesSaved = 0,
    this.imagesReduced = 0,
    this.imagesDescribed = 0,
    this.status,
  });

  /// [ContextManager.status]: why compaction failed / cannot help, or null.
  final String? status;

  /// Tokens saved by the screenshot tiers (⅕ size / described).
  final int imagesSaved;
  final int imagesReduced;
  final int imagesDescribed;

  final int overhead;

  /// The pinned conversation note.
  final int note;
  final int summary;
  final int text;
  final int images;
  final int imageCount;
  final int audio;
  final int tools;
  final int toolCount;

  /// What the meter shows ([ContextManager.estimatedTokens]).
  final int total;
  final int threshold;
  final int compactedMessages;

  /// [total] is anchored on the backend's usage report.
  final bool measured;

  /// gpt-live: text-only voice context, screenshots only for delegations.
  final bool textOnly;

  int get heuristic => overhead + note + summary + text + images + audio + tools;
  double get fill => threshold <= 0 ? 0 : total / threshold;

  static ContextBreakdown of(ContextManager m, Conversation? conv) {
    final p = m.parts();
    return ContextBreakdown(
      overhead: p.overhead,
      note: p.pinned,
      summary: p.summary,
      text: p.text,
      images: p.images,
      imageCount: p.imageCount,
      audio: p.audio,
      tools: p.tools,
      toolCount: p.toolCount,
      total: p.total,
      threshold: m.threshold,
      compactedMessages: p.compactedMessages,
      measured: p.measured,
      textOnly: m.accounting == ContextAccounting.textEstimate,
      imagesSaved: p.imagesSaved,
      imagesReduced: p.imagesReduced,
      imagesDescribed: p.imagesDescribed,
      status: m.status,
    );
  }
}

Color meterColor(double fill) => fill < 0.6
    ? WoiColors.cyan
    : fill < 0.9
    ? WoiColors.amber
    : WoiColors.red;

enum ContextMeterStyle {
  panel,
  bar,
  ring,

  /// Input-bar status row: a short bar plus "12k / 32k" (or "37%" when
  /// [ContextMeter.dense]).
  compact,
}

/// tokens / threshold gauge with a breakdown tooltip, a "compacting…"
/// shimmer, and (tap) a details sheet with a "Compact now" action.
class ContextMeter extends StatelessWidget {
  const ContextMeter({
    super.key,
    required this.manager,
    this.conversation,
    this.style = ContextMeterStyle.panel,
    this.onCompact,
    this.dense = false,
  });

  final ContextManager manager;
  final Conversation? conversation;
  final ContextMeterStyle style;
  final VoidCallback? onCompact;

  /// [ContextMeterStyle.compact] only: percentage instead of token counts.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final b = ContextBreakdown.of(manager, conversation);
        final fill = b.fill.clamp(0.0, 1.0);
        final color = manager.compressing ? WoiColors.violet : meterColor(b.fill);
        final busy = manager.compressing;
        final label = '${formatTokens(b.total)} / ${formatTokens(b.threshold)}';
        final semantics =
            'Context ${formatTokens(b.total)} of ${formatTokens(b.threshold)} tokens'
            '${busy ? ', compacting' : ''}'
            '${b.status == null ? '' : '. ${b.status}'}';

        final Widget gauge = switch (style) {
          ContextMeterStyle.ring => _Ring(fill: fill, color: color, busy: busy),
          ContextMeterStyle.compact => Row(
            key: const ValueKey('context-compact'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: dense ? 28 : 40, child: MeterBar(fill: fill, color: color, busy: busy, height: 4)),
              const SizedBox(width: 6),
              Text(
                busy ? 'compacting…' : (dense ? '${(b.fill * 100).round()}%' : label),
                style: mono(11, color: busy ? color : WoiColors.textDim).copyWith(fontFeatures: kTabular),
                softWrap: false,
              ),
            ],
          ),
          ContextMeterStyle.bar => SizedBox(
            width: 190,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(busy ? Icons.compress_rounded : Icons.memory_rounded, size: 13, color: color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: WoiMotion.fast,
                        child: Text(
                          busy ? 'compacting…' : label,
                          key: ValueKey(busy),
                          style: mono(11, color: busy ? color : WoiColors.textDim).copyWith(fontFeatures: kTabular),
                          overflow: TextOverflow.fade,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                MeterBar(fill: fill, color: color, busy: busy),
              ],
            ),
          ),
          ContextMeterStyle.panel => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('CONTEXT', style: eyebrow()),
                  const SizedBox(width: 8),
                  if (busy)
                    Text(
                      'compacting…',
                      style: body(11, weight: FontWeight.w600, color: color),
                    ),
                  const Spacer(),
                  Text(
                    label,
                    style: mono(12, color: color).copyWith(fontFeatures: kTabular),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              MeterBar(fill: fill, color: color, busy: busy, height: 6),
            ],
          ),
        };

        return Semantics(
          button: true,
          label: semantics,
          child: Tooltip(
            richMessage: WidgetSpan(
              child: BreakdownTable(b: b, compressing: busy),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showContextDetails(context, manager, conversation, onCompact: onCompact),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: switch (style) {
                      ContextMeterStyle.panel => 0,
                      ContextMeterStyle.compact => dense ? kTouchTarget : 28,
                      _ => kTouchTarget,
                    },
                  ),
                  child: Center(widthFactor: 1, child: gauge),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Flat progress bar; a light sweep runs across it only while compacting.
class MeterBar extends StatefulWidget {
  const MeterBar({super.key, required this.fill, required this.color, this.busy = false, this.height = 5});
  final double fill;
  final Color color;
  final bool busy;
  final double height;

  @override
  State<MeterBar> createState() => _MeterBarState();
}

/// [fill] rounded to 1/80: a few tokens more (typing in the pinned note,
/// a short turn) must not start a 700 ms tween (~40 full-window frames on
/// software GL) for a sub-pixel change.
double meterStep(double fill) => (fill.clamp(0.0, 1.0) * 80).round() / 80;

class _MeterBarState extends State<MeterBar> {
  // 12 fps sweep (timer-driven, own repaint boundary): compaction can run for
  // a while and a 60 fps sweep is a full raster per frame on software GL.
  final _sweep = LowFpsLoop(period: const Duration(milliseconds: 1100));

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: WoiColors.glassStrong),
            TweenAnimationBuilder<double>(
              tween: Tween(end: meterStep(widget.fill)),
              duration: const Duration(milliseconds: 700),
              curve: WoiMotion.emphasized,
              builder: (context, v, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: v,
                child: ColoredBox(color: c),
              ),
            ),
            if (widget.busy)
              RepaintBoundary(
                child: ValueListenableBuilder<double>(
                  valueListenable: _sweep,
                  builder: (context, sweep, _) => FractionallySizedBox(
                    alignment: Alignment(-1.6 + 3.2 * sweep, 0),
                    widthFactor: 0.35,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: 0.7),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatefulWidget {
  const _Ring({required this.fill, required this.color, required this.busy});
  final double fill;
  final Color color;
  final bool busy;

  @override
  State<_Ring> createState() => _RingState();
}

class _RingState extends State<_Ring> {
  final _spin = LowFpsLoop(period: const Duration(milliseconds: 1200));
  static final _still = ValueNotifier<double>(0);

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 34,
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: meterStep(widget.fill)),
      duration: const Duration(milliseconds: 700),
      curve: WoiMotion.emphasized,
      builder: (context, v, _) => ValueListenableBuilder<double>(
        // Only listened to (so only ticking) while busy.
        valueListenable: widget.busy ? _spin : _still,
        builder: (context, spin, _) => CustomPaint(
          painter: _RingPainter(v, widget.color, widget.busy ? spin : null),
          child: Center(
            child: Text(
              '${(widget.fill * 100).round()}',
              style: mono(10, color: widget.color).copyWith(fontFeatures: kTabular),
            ),
          ),
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fill, this.color, this.spin);
  final double fill;
  final Color color;
  final double? spin;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = WoiColors.glassStrong;
    canvas.drawArc(rect, 0, 2 * pi, false, bg);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    if (spin != null) {
      canvas.drawArc(rect, spin! * 2 * pi, pi * 0.6, false, fg);
    } else {
      canvas.drawArc(rect, -pi / 2, 2 * pi * fill, false, fg);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fill != fill || old.color != color || old.spin != spin;
}

/// Token breakdown rows, used in the tooltip and the details sheet.
class BreakdownTable extends StatelessWidget {
  const BreakdownTable({super.key, required this.b, this.compressing = false, this.large = false});
  final ContextBreakdown b;
  final bool compressing;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fs = large ? 13.5 : 12.0;
    Widget row(String k, String v, Color dot, {String? sub}) => Padding(
      padding: EdgeInsets.symmetric(vertical: large ? 5 : 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: large ? 170 : 130,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: k, style: body(fs)),
                  if (sub != null)
                    TextSpan(
                      text: '  $sub',
                      style: body(fs - 1, color: WoiColors.textFaint),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              formatTokens(int.tryParse(v) ?? 0),
              textAlign: TextAlign.right,
              style: mono(fs, color: WoiColors.text).copyWith(fontFeatures: kTabular),
            ),
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!large) ...[Text('Context window', style: body(13, weight: FontWeight.w700)), const SizedBox(height: 6)],
        if (b.overhead > 0) row('Instructions & tools', '${b.overhead}', WoiColors.textFaint),
        row('Pinned note', '${b.note}', WoiColors.mint, sub: 'every turn'),
        row('Memory summary', '${b.summary}', WoiColors.violet),
        row('Speech & text', '${b.text}', WoiColors.cyan),
        row('Screenshots', '${b.images}', WoiColors.blue, sub: b.textOnly ? 'latest, delegation' : '×${b.imageCount}'),
        if (b.imagesReduced + b.imagesDescribed > 0)
          Text(
            '${b.imagesReduced} sent at ⅕, ${b.imagesDescribed} described'
            '${b.imagesSaved > 0 ? ' · saved ${formatTokens(b.imagesSaved)}' : ''}',
            style: body(fs - 0.5, color: WoiColors.textDim),
          ),
        if (!b.textOnly) row('Audio', '${b.audio}', WoiColors.magenta),
        row('Tool calls', '${b.tools}', WoiColors.amber, sub: '×${b.toolCount}'),
        const SizedBox(height: 6),
        Container(height: 1, width: large ? 250 : 210, color: WoiColors.stroke),
        const SizedBox(height: 6),
        Text(
          '${b.measured ? 'Measured (last response)' : 'Estimated'} total  ${formatTokens(b.total)}',
          style: body(fs, weight: FontWeight.w600),
        ),
        Text(
          'Compacts at ${formatTokens(b.threshold)} (${(b.fill * 100).round()}% used)',
          style: body(fs - 0.5, color: WoiColors.textDim),
        ),
        if (b.compactedMessages > 0)
          Text('${b.compactedMessages} older messages summarised', style: body(fs - 0.5, color: WoiColors.textDim)),
        if (b.status != null && !compressing)
          SizedBox(
            width: large ? 250 : 210,
            child: Text(b.status!, style: body(fs - 0.5, weight: FontWeight.w600, color: WoiColors.amber)),
          ),
        if (compressing)
          Text(
            'Compacting now…',
            style: body(fs - 0.5, weight: FontWeight.w600, color: WoiColors.violet),
          ),
      ],
    );
  }
}

/// Bottom sheet (phone) / dialog (desktop) with the full breakdown.
Future<void> showContextDetails(
  BuildContext context,
  ContextManager manager,
  Conversation? conversation, {
  VoidCallback? onCompact,
}) {
  Widget content(BuildContext ctx) => ListenableBuilder(
    listenable: manager,
    builder: (ctx, _) {
      final b = ContextBreakdown.of(manager, conversation);
      final color = manager.compressing ? WoiColors.violet : meterColor(b.fill);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.memory_rounded, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Context window', style: display(19), overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatTokens(b.total)} / ${formatTokens(b.threshold)}',
                style: mono(14, color: color).copyWith(fontFeatures: kTabular),
              ),
            ],
          ),
          const SizedBox(height: 14),
          MeterBar(fill: b.fill.clamp(0, 1), color: color, busy: manager.compressing, height: 8),
          const SizedBox(height: 18),
          BreakdownTable(b: b, compressing: manager.compressing, large: true),
          const SizedBox(height: 12),
          Text(
            'When the context passes the threshold, older turns are summarised in the background '
            'and the live session continues with the summary.',
            style: body(12.5, color: WoiColors.textDim, height: 1.45),
          ),
          if (onCompact != null) ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: manager.compressing
                  ? null
                  : () {
                      onCompact();
                    },
              icon: const Icon(Icons.compress_rounded),
              label: Text(manager.compressing ? 'Compacting…' : 'Compact now'),
            ),
          ],
        ],
      );
    },
  );

  final phone = MediaQuery.sizeOf(context).width < 600;
  if (phone) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: WoiColors.bg1,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(WoiRadii.xl))),
      builder: (ctx) => SafeArea(
        child: Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: content(ctx)),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(padding: const EdgeInsets.all(24), child: content(ctx)),
      ),
    ),
  );
}
