import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Frosted glass panel with a soft gradient hairline border.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = 18,
    this.tint,
    this.borderGradient,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final Color? tint;
  final Gradient? borderGradient;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 12))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            foregroundPainter: _GradientBorderPainter(
              radius: radius,
              gradient:
                  borderGradient ??
                  LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.18),
                      Colors.white.withValues(alpha: 0.04),
                      WoiColors.cyan.withValues(alpha: 0.10),
                    ],
                  ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    (tint ?? Colors.white).withValues(alpha: 0.075),
                    (tint ?? Colors.white).withValues(alpha: 0.025),
                  ],
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

class _GradientBorderPainter extends CustomPainter {
  _GradientBorderPainter({required this.radius, required this.gradient});
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
  }

  @override
  bool shouldRepaint(_GradientBorderPainter old) => old.radius != radius || old.gradient != gradient;
}

/// Deep-space backdrop: nebula glows plus a faint grid. Static on purpose:
/// glass panels re-blur whatever is behind them, so a still backdrop keeps
/// an always-on assistant cheap on the GPU.
class WoiBackdrop extends StatelessWidget {
  const WoiBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const RepaintBoundary(child: CustomPaint(painter: _BackdropPainter(0.1))),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [WoiColors.bg1, WoiColors.bg0],
        ).createShader(rect),
    );
    final a = t * 2 * pi;
    void glow(Offset c, double r, Color color) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final m = size.shortestSide;
    glow(
      Offset(size.width * (0.18 + 0.05 * sin(a)), size.height * (0.22 + 0.04 * cos(a))),
      m * 0.75,
      WoiColors.blue.withValues(alpha: 0.13),
    );
    glow(
      Offset(size.width * (0.85 + 0.04 * cos(a * 1.3)), size.height * (0.82 + 0.05 * sin(a))),
      m * 0.8,
      WoiColors.magenta.withValues(alpha: 0.08),
    );
    glow(
      Offset(size.width * 0.55, size.height * (0.5 + 0.03 * sin(a * 2))),
      m * 0.5,
      WoiColors.violet.withValues(alpha: 0.06),
    );

    // Faint perspective grid near the bottom for depth.
    final grid = Paint()
      ..color = WoiColors.cyan.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = (t * step) % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.t != t;
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
          Text(
            label,
            style: body(dense ? 11 : 12, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}
