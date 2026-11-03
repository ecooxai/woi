import 'package:flutter/material.dart';

import '../theme.dart';

/// A suggested prompt shown on the empty transcript.
class HintChipData {
  const HintChipData(this.icon, this.label, this.prompt);
  final IconData icon;
  final String label;

  /// Sent as a text turn when tapped.
  final String prompt;
}

const kDefaultHints = [
  HintChipData(Icons.ads_click_rounded, 'Click the browser', 'Click the browser'),
  HintChipData(Icons.terminal_rounded, 'Run ls', 'Run ls in my home folder'),
  HintChipData(Icons.description_outlined, 'Show me a file', 'Show me a file from my home folder'),
  HintChipData(Icons.screenshot_monitor_rounded, "What's on my screen?", "What's on my screen?"),
];

/// Welcome screen for a new conversation: headline, how-to line,
/// tappable hint chips and (desktop) keyboard shortcuts.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.subtitle,
    required this.onHint,
    this.hints = kDefaultHints,
    this.showShortcuts = true,
    this.enabled = true,
  });

  final String subtitle;
  final ValueChanged<String> onHint;
  final List<HintChipData> hints;
  final bool showShortcuts;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: WoiMotion.slow,
      curve: WoiMotion.emphasized,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 16 * (1 - v)), child: child),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (r) => const LinearGradient(
              colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta],
            ).createShader(r),
            child: Text(
              'How can I help?',
              textAlign: TextAlign.center,
              style: display(30, weight: FontWeight.w600, spacing: 0.2),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: body(14.5, color: WoiColors.textDim, height: 1.4),
          ),
          const SizedBox(height: 26),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < hints.length; i++)
                _HintChip(data: hints[i], index: i, onTap: enabled ? () => onHint(hints[i].prompt) : null),
            ],
          ),
          if (showShortcuts) ...[
            const SizedBox(height: 30),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 8,
              children: const [
                KeyHint(keys: ['Space'], label: 'hold to talk'),
                KeyHint(keys: ['Ctrl', 'K'], label: 'type'),
                KeyHint(keys: ['Esc'], label: 'interrupt'),
                KeyHint(keys: ['Ctrl', ','], label: 'settings'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HintChip extends StatefulWidget {
  const _HintChip({required this.data, required this.index, required this.onTap});
  final HintChipData data;
  final int index;
  final VoidCallback? onTap;

  @override
  State<_HintChip> createState() => _HintChipState();
}

class _HintChipState extends State<_HintChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = [WoiColors.cyan, WoiColors.amber, WoiColors.violet, WoiColors.mint][widget.index % 4];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + 70 * widget.index),
      curve: WoiMotion.emphasized,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 10 * (1 - v)), child: child),
      ),
      child: Semantics(
        button: true,
        label: 'Suggestion: ${widget.data.label}',
        excludeSemantics: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: WoiMotion.fast,
                constraints: const BoxConstraints(minHeight: kTouchTarget),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: accent.withValues(alpha: _hover ? 0.16 : 0.07),
                  border: Border.all(color: accent.withValues(alpha: _hover ? 0.6 : 0.28)),
                  boxShadow: _hover ? [BoxShadow(color: accent.withValues(alpha: 0.25), blurRadius: 18)] : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.data.icon, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Text('"${widget.data.label}"', style: body(14, weight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Keycap-style shortcut hint: [Ctrl] [K] type.
class KeyHint extends StatelessWidget {
  const KeyHint({super.key, required this.keys, required this.label});
  final List<String> keys;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final k in keys) ...[KeyCap(k), const SizedBox(width: 3)],
      const SizedBox(width: 4),
      Text(label, style: body(12, color: WoiColors.textFaint)),
    ],
  );
}

class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: WoiColors.glass,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: WoiColors.strokeStrong),
      boxShadow: const [BoxShadow(color: Color(0x66000000), offset: Offset(0, 1.5))],
    ),
    child: Text(label, style: mono(11, color: WoiColors.textDim)),
  );
}
