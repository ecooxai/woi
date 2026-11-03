import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Frosted glass panel: backdrop blur, a faint vertical sheen, a gradient
/// hairline border and a top specular edge for depth.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = WoiRadii.xl,
    this.blur = 22,
    this.tint,
    this.borderGradient,
    this.margin,
    this.glow,
    this.elevated = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final Color? tint;
  final Gradient? borderGradient;

  /// Optional coloured ambient glow behind the panel (focus / state).
  final Color? glow;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final t = tint ?? Colors.white;
    return AnimatedContainer(
      duration: WoiMotion.slow,
      curve: WoiMotion.curve,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          if (elevated) const BoxShadow(color: Color(0x73000000), blurRadius: 40, offset: Offset(0, 18)),
          if (glow != null) BoxShadow(color: glow!.withValues(alpha: 0.16), blurRadius: 60, spreadRadius: -8),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            foregroundPainter: _GlassEdgePainter(
              radius: radius,
              gradient:
                  borderGradient ??
                  LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.20),
                      Colors.white.withValues(alpha: 0.05),
                      (glow ?? WoiColors.cyan).withValues(alpha: 0.14),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: WoiColors.bg1.withValues(alpha: 0.42),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [t.withValues(alpha: 0.075), t.withValues(alpha: 0.02)],
                ),
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({required this.radius, required this.gradient});
  final double radius;
  final Gradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = gradient.createShader(rect),
    );
    // Specular top edge: a thin bright line that fades out at the corners.
    final top = Rect.fromLTWH(radius, 0.5, max(0, size.width - radius * 2), 1);
    canvas.drawRect(
      top,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0)],
        ).createShader(top),
    );
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) => old.radius != radius || old.gradient != gradient;
}

/// Deep-space backdrop: nebula glows, a star field, a horizon glow and a
/// faint perspective grid. Static on purpose: glass panels re-blur whatever
/// is behind them, so a still backdrop keeps an always-on assistant cheap.
class WoiBackdrop extends StatelessWidget {
  const WoiBackdrop({super.key, required this.child, this.accent = WoiColors.blue});
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: CustomPaint(painter: _BackdropPainter(accent))),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.accent);
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF070C1A), WoiColors.bg0, Color(0xFF05040E)],
          stops: [0, 0.6, 1],
        ).createShader(rect),
    );
    void glow(Offset c, double r, Color color) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final m = max(size.shortestSide, 1.0);
    glow(Offset(size.width * 0.12, size.height * 0.18), m * 0.85, accent.withValues(alpha: 0.14));
    glow(Offset(size.width * 0.92, size.height * 0.88), m * 0.85, WoiColors.magenta.withValues(alpha: 0.075));
    glow(Offset(size.width * 0.55, size.height * 0.45), m * 0.55, WoiColors.violet.withValues(alpha: 0.05));

    // Star field (deterministic).
    final rnd = Random(7);
    final star = Paint();
    final count = (size.width * size.height / 9000).clamp(40, 320).toInt();
    for (var i = 0; i < count; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final big = rnd.nextDouble() > 0.93;
      star.color = Colors.white.withValues(alpha: big ? 0.35 : 0.06 + rnd.nextDouble() * 0.14);
      canvas.drawCircle(p, big ? 1.1 : 0.6, star);
    }

    // Perspective floor grid that fades in toward the bottom.
    final horizon = size.height * 0.62;
    final floor = Rect.fromLTWH(0, horizon, size.width, size.height - horizon);
    canvas.saveLayer(floor, Paint());
    final grid = Paint()
      ..color = WoiColors.cyan.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    final vp = Offset(size.width / 2, horizon - size.height * 0.25);
    for (var i = -24; i <= 24; i++) {
      final x = size.width / 2 + i * size.width / 16;
      final t = (horizon - vp.dy) / (size.height - vp.dy);
      canvas.drawLine(Offset(vp.dx + (x - vp.dx) * t, horizon), Offset(x, size.height), grid);
    }
    for (var k = 1; k < 14; k++) {
      final y = horizon + (size.height - horizon) * pow(k / 14, 1.8);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawRect(
      floor,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(floor),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.accent != accent;
}

/// Small rounded status chip.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.color = WoiColors.cyan, this.icon, this.dense = false});
  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: dense ? 12 : 14, color: color), const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: body(dense ? 11 : 12, weight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round glassy icon button with a tooltip (also its semantics label).
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.size = 40,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = color ?? (active ? WoiColors.cyan : WoiColors.textDim);
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: AnimatedContainer(
            duration: WoiMotion.fast,
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? c.withValues(alpha: 0.14) : WoiColors.glass,
              border: Border.all(color: active ? c.withValues(alpha: 0.5) : WoiColors.stroke),
            ),
            child: Icon(icon, size: size * 0.48, color: onPressed == null ? WoiColors.textFaint : c),
          ),
        ),
      ),
    );
  }
}
