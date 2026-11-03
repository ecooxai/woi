import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';

IconData micModeIcon(MicMode m) => switch (m) {
  MicMode.handsFree => Icons.graphic_eq_rounded,
  MicMode.pushToTalk => Icons.touch_app_outlined,
  MicMode.muted => Icons.mic_off_outlined,
};

String micModeHint(MicMode m) => switch (m) {
  MicMode.handsFree => 'Just talk. Interrupt any time.',
  MicMode.pushToTalk => 'Hold the mic button or Space to talk.',
  MicMode.muted => 'Microphone is off. Type below.',
};

/// Hands-free / push-to-talk / mute selector (segmented, glassy).
class MicModeSelector extends StatelessWidget {
  const MicModeSelector({super.key, required this.mode, required this.onChanged, this.compact = false});
  final MicMode mode;
  final ValueChanged<MicMode> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(WoiRadii.lg),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final m in MicMode.values)
            compact
                ? _Segment(mode: m, selected: m == mode, onTap: () => onChanged(m), compact: true)
                : Expanded(
                    child: _Segment(mode: m, selected: m == mode, onTap: () => onChanged(m), compact: false),
                  ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.mode, required this.selected, required this.onTap, required this.compact});
  final MicMode mode;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = selected ? (mode == MicMode.muted ? WoiColors.red : WoiColors.cyan) : WoiColors.textDim;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      label: mode.label,
      excludeSemantics: true,
      child: Tooltip(
        message: mode.label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(WoiRadii.md),
            onTap: onTap,
            child: AnimatedContainer(
              duration: WoiMotion.medium,
              curve: WoiMotion.curve,
              constraints: const BoxConstraints(minHeight: kTouchTarget, minWidth: kTouchTarget),
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 6, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(WoiRadii.md),
                gradient: selected
                    ? LinearGradient(colors: [c.withValues(alpha: 0.22), c.withValues(alpha: 0.08)])
                    : null,
                border: Border.all(color: selected ? c.withValues(alpha: 0.5) : Colors.transparent),
                boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.18), blurRadius: 14)] : null,
              ),
              child: compact
                  ? Icon(micModeIcon(mode), size: 20, color: c)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(micModeIcon(mode), size: 20, color: c),
                        const SizedBox(height: 3),
                        Text(
                          mode.label,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: body(12, weight: FontWeight.w600, color: selected ? WoiColors.text : WoiColors.textDim),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large round mic button. Hands-free/muted: tap toggles the mic.
/// Push-to-talk: press and hold. A level ring reacts to the mic.
class MicButton extends StatefulWidget {
  const MicButton({
    super.key,
    required this.mode,
    required this.held,
    required this.onModeChanged,
    required this.onPttDown,
    required this.onPttUp,
    this.level,
    this.size = 72,
    this.enabled = true,
  });

  final MicMode mode;
  final bool held;
  final ValueChanged<MicMode> onModeChanged;
  final VoidCallback onPttDown;
  final VoidCallback onPttUp;
  final ValueListenable<double>? level;
  final double size;
  final bool enabled;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(seconds: 3))
    ..repeat();

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  bool get _live => widget.mode == MicMode.handsFree || (widget.mode == MicMode.pushToTalk && widget.held);

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;
    final ptt = mode == MicMode.pushToTalk;
    final color = mode == MicMode.muted ? WoiColors.red : WoiColors.cyan;
    final label = switch (mode) {
      MicMode.handsFree => 'Microphone on. Tap to mute',
      MicMode.muted => 'Microphone muted. Tap to unmute',
      MicMode.pushToTalk => widget.held ? 'Listening. Release to send' : 'Hold to talk',
    };
    final s = widget.size;

    final face = AnimatedBuilder(
      animation: Listenable.merge([_breath, ?widget.level]),
      builder: (context, _) {
        final lv = _live ? pow(((widget.level?.value ?? 0) - 0.35).clamp(0.0, 0.65) / 0.65, 1.2).toDouble() : 0.0;
        final breath = 0.5 + 0.5 * sin(_breath.value * 2 * pi);
        return SizedBox.square(
          dimension: s * 1.35,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Level halo.
              Container(
                width: s * (1.0 + 0.35 * lv + (_live ? 0.06 * breath : 0)),
                height: s * (1.0 + 0.35 * lv + (_live ? 0.06 * breath : 0)),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: _live ? 0.10 + 0.25 * lv : 0),
                ),
              ),
              AnimatedContainer(
                duration: WoiMotion.fast,
                width: s * (widget.held ? 0.94 : 1),
                height: s * (widget.held ? 0.94 : 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: _live
                      ? const RadialGradient(
                          center: Alignment(-0.3, -0.4),
                          colors: [Color(0xFFB8FBFF), WoiColors.cyan, WoiColors.blue],
                          stops: [0, 0.45, 1],
                        )
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [color.withValues(alpha: 0.20), color.withValues(alpha: 0.08)],
                        ),
                  border: Border.all(color: color.withValues(alpha: _live ? 0.9 : 0.45), width: 1.4),
                  boxShadow: [
                    BoxShadow(color: color.withValues(alpha: _live ? 0.5 : 0.15), blurRadius: _live ? 28 : 12),
                  ],
                ),
                child: Icon(
                  mode == MicMode.muted
                      ? Icons.mic_off_rounded
                      : (_live ? Icons.mic_rounded : Icons.mic_none_rounded),
                  size: s * 0.42,
                  color: _live ? WoiColors.bg0 : color,
                ),
              ),
            ],
          ),
        );
      },
    );

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      excludeSemantics: true,
      onTap: ptt ? null : () => widget.onModeChanged(mode == MicMode.muted ? MicMode.handsFree : MicMode.muted),
      child: Tooltip(
        message: ptt ? 'Hold to talk (Space)' : label,
        child: ptt
            ? Listener(
                onPointerDown: widget.enabled ? (_) => widget.onPttDown() : null,
                onPointerUp: widget.enabled ? (_) => widget.onPttUp() : null,
                onPointerCancel: widget.enabled ? (_) => widget.onPttUp() : null,
                child: face,
              )
            : GestureDetector(
                onTap: widget.enabled
                    ? () => widget.onModeChanged(mode == MicMode.muted ? MicMode.handsFree : MicMode.muted)
                    : null,
                child: face,
              ),
      ),
    );
  }
}

/// Wide hold-to-talk button (desktop side panel).
class PushToTalkButton extends StatelessWidget {
  const PushToTalkButton({super.key, required this.pipeline});
  final TurnPipeline pipeline;

  @override
  Widget build(BuildContext context) {
    final held = pipeline.pttHeld;
    return Semantics(
      button: true,
      label: held ? 'Listening. Release to send' : 'Hold to talk',
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => pipeline.pttDown(),
        onPointerUp: (_) => pipeline.pttUp(),
        onPointerCancel: (_) => pipeline.pttUp(),
        child: AnimatedContainer(
          duration: WoiMotion.fast,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WoiRadii.lg),
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
              Icon(held ? Icons.mic_rounded : Icons.mic_none_rounded, color: held ? WoiColors.bg0 : WoiColors.cyan),
              const SizedBox(width: 10),
              Text(
                held ? 'Listening… release to send' : 'Hold to talk  ·  Space',
                style: body(14, weight: FontWeight.w600, color: held ? WoiColors.bg0 : WoiColors.cyan),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Text fallback input. Enter sends, Shift+Enter inserts a newline,
/// Esc leaves the field (so Space is push-to-talk again).
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.onSend,
    this.onStop,
    this.enabled = true,
    this.showStop = false,
    this.focusNode,
    this.hint,
  });
  final ValueChanged<String> onSend;
  final VoidCallback? onStop;
  final bool enabled;
  final bool showStop;
  final FocusNode? focusNode;
  final String? hint;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocus);
      _focus.onKeyEvent = _onKey;
      _focus.addListener(_onFocus);
    }
  }

  void _onFocus() {
    if (mounted && _focused != _focus.hasFocus) setState(() => _focused = _focus.hasFocus);
  }

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
    _focus.removeListener(_onFocus);
    _ctrl.dispose();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final empty = _ctrl.text.trim().isEmpty;
    return AnimatedContainer(
      duration: WoiMotion.medium,
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(WoiRadii.xl),
        border: Border.all(color: _focused ? WoiColors.cyan.withValues(alpha: 0.6) : WoiColors.stroke),
        boxShadow: _focused ? [BoxShadow(color: WoiColors.cyan.withValues(alpha: 0.14), blurRadius: 22)] : null,
      ),
      child: Row(
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
                hintText: widget.enabled ? (widget.hint ?? 'Type a message…') : 'Connecting…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                prefixIcon: const Icon(Icons.keyboard_outlined, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: AnimatedSwitcher(
              duration: WoiMotion.fast,
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: c),
              ),
              child: widget.showStop && empty
                  ? IconButton.filled(
                      key: const ValueKey('stop'),
                      tooltip: 'Stop (Esc)',
                      style: IconButton.styleFrom(
                        backgroundColor: WoiColors.magenta.withValues(alpha: 0.2),
                        foregroundColor: WoiColors.magenta,
                        minimumSize: const Size(kTouchTarget, kTouchTarget),
                      ),
                      onPressed: widget.onStop,
                      icon: const Icon(Icons.stop_rounded),
                    )
                  : IconButton.filled(
                      key: const ValueKey('send'),
                      tooltip: 'Send (Enter)',
                      style: IconButton.styleFrom(
                        minimumSize: const Size(kTouchTarget, kTouchTarget),
                        disabledBackgroundColor: WoiColors.glassStrong,
                      ),
                      onPressed: empty || !widget.enabled ? null : _send,
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
