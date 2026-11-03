import 'package:flutter/material.dart';

import '../theme.dart';

/// Flat card surface: solid fill, hairline border and a soft shadow. (The
/// name is historical; there is no blur: a BackdropFilter re-renders
/// everything behind it each frame, which is costly on software GL.)
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = WoiRadii.lg,
    this.tint,
    this.margin,
    this.glow,
    this.elevated = false,
    // Kept for source compatibility; ignored.
    double blur = 0,
    Gradient? borderGradient,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  /// Optional fill colour (defaults to the card colour).
  final Color? tint;

  /// Optional accent: tints the border (focus / state).
  final Color? glow;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final d = surfaceDecoration(radius: radius, color: tint, elevated: elevated);
    return Container(
      margin: margin,
      decoration: glow == null
          ? d
          : d.copyWith(border: Border.all(color: glow!.withValues(alpha: 0.45))),
      padding: padding,
      child: child,
    );
  }
}

/// Plain window background (formerly a decorative backdrop).
class WoiBackdrop extends StatelessWidget {
  const WoiBackdrop({super.key, required this.child, this.accent});
  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) => ColoredBox(color: WoiColors.bg0, child: child);
}

/// Small rounded status chip.
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.color, this.icon, this.dense = false});
  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = color ?? WoiColors.cyan;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: dense ? 12 : 14, color: c), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: body(dense ? 11 : 12, weight: FontWeight.w600, color: c),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round icon button with a tooltip (also its semantics label). [size] is
/// the visual size; the hit area is at least [size].
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
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoiRadii.md)),
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(WoiRadii.md),
              color: active ? c.withValues(alpha: 0.10) : null,
            ),
            child: Icon(icon, size: size * 0.5, color: onPressed == null ? WoiColors.textFaint : c),
          ),
        ),
      ),
    );
  }
}
