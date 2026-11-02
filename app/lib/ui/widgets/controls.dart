import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';

/// Hands-free / push-to-talk / mute selector.
class MicModeSelector extends StatelessWidget {
  const MicModeSelector({super.key, required this.mode, required this.onChanged, this.compact = false});
  final MicMode mode;
  final ValueChanged<MicMode> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    IconData icon(MicMode m) => switch (m) {
      MicMode.handsFree => Icons.graphic_eq,
      MicMode.pushToTalk => Icons.touch_app_outlined,
      MicMode.muted => Icons.mic_off_outlined,
    };
    return SegmentedButton<MicMode>(
      showSelectedIcon: false,
      expandedInsets: compact ? null : EdgeInsets.zero,
      style: ButtonStyle(
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        padding: WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: compact ? 8 : 4, vertical: compact ? 10 : 6)),
      ),
      segments: [
        for (final m in MicMode.values)
          compact
              ? ButtonSegment(value: m, icon: Icon(icon(m), size: 18), tooltip: m.label)
              : ButtonSegment(
                  value: m,
                  tooltip: m.label,
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon(m), size: 20),
                        const SizedBox(height: 4),
                        Text(
                          m.label,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: body(12, weight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
      ],
      selected: {mode},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// Large hold-to-talk button.
class PushToTalkButton extends StatelessWidget {
  const PushToTalkButton({super.key, required this.pipeline});
  final TurnPipeline pipeline;

  @override
  Widget build(BuildContext context) {
    final held = pipeline.pttHeld;
    return Listener(
      onPointerDown: (_) => pipeline.pttDown(),
      onPointerUp: (_) => pipeline.pttUp(),
      onPointerCancel: (_) => pipeline.pttUp(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: held
                ? [WoiColors.cyan, WoiColors.blue]
                : [WoiColors.cyan.withValues(alpha: 0.14), WoiColors.blue.withValues(alpha: 0.10)],
          ),
          border: Border.all(color: WoiColors.cyan.withValues(alpha: held ? 0.9 : 0.35)),
          boxShadow: held ? [BoxShadow(color: WoiColors.cyan.withValues(alpha: 0.45), blurRadius: 24)] : null,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(held ? Icons.mic : Icons.mic_none, color: held ? WoiColors.bg0 : WoiColors.cyan),
            const SizedBox(width: 10),
            Text(
              held ? 'Listening… release to send' : 'Hold to talk  ·  Space',
              style: body(14, weight: FontWeight.w600, color: held ? WoiColors.bg0 : WoiColors.cyan),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text fallback input. Enter sends, Shift+Enter inserts a newline.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, this.onStop, this.enabled = true, this.showStop = false});
  final ValueChanged<String> onSend;
  final VoidCallback? onStop;
  final bool enabled;
  final bool showStop;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  // Plain Enter is left to the engine, which turns it into the `send` text
  // input action *after* committing pending IME text (handling the key event
  // here would race the last typed characters on Linux).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter && HardwareKeyboard.instance.isShiftPressed) {
      final v = _ctrl.value;
      final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
      _ctrl.value = v.replaced(TextRange(start: sel.start, end: sel.end), '\n');
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      node.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty || !widget.enabled) return;
    widget.onSend(t);
    _ctrl.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            focusNode: _focus,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 6,
            style: body(15),
            textInputAction: TextInputAction.send,
          keyboardType: TextInputType.multiline,
          onSubmitted: (_) => _send(),
          onEditingComplete: () {}, // keep focus after sending
          onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: widget.enabled ? 'Type a message…' : 'Connecting…',
              prefixIcon: const Icon(Icons.keyboard_outlined, size: 20),
            ),
          ),
        ),
        const SizedBox(width: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
          child: widget.showStop && _ctrl.text.trim().isEmpty
              ? IconButton.filled(
                  key: const ValueKey('stop'),
                  tooltip: 'Stop speaking (Esc)',
                  style: IconButton.styleFrom(
                    backgroundColor: WoiColors.magenta.withValues(alpha: 0.2),
                    foregroundColor: WoiColors.magenta,
                    minimumSize: const Size(52, 52),
                  ),
                  onPressed: widget.onStop,
                  icon: const Icon(Icons.stop_rounded),
                )
              : IconButton.filled(
                  key: const ValueKey('send'),
                  tooltip: 'Send (Enter)',
                  style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                  onPressed: _ctrl.text.trim().isEmpty || !widget.enabled ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
        ),
      ],
    );
  }
}
