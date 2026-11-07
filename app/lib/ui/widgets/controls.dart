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

/// Hands-free / push-to-talk / mute selector: a flat segmented row.
/// [compact] shows icons only; [itemSize] is the square size of each
/// segment (48 on phones for touch).
class MicModeSelector extends StatelessWidget {
  const MicModeSelector({
    super.key,
    required this.mode,
    required this.onChanged,
    this.compact = false,
    this.itemSize = kTouchTarget,
  });
  final MicMode mode;
  final ValueChanged<MicMode> onChanged;
  final bool compact;
  final double itemSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: WoiColors.glass,
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final m in MicMode.values)
            compact
                ? _Segment(mode: m, selected: m == mode, onTap: () => onChanged(m), compact: true, size: itemSize)
                : Expanded(
                    child: _Segment(
                      mode: m,
                      selected: m == mode,
                      onTap: () => onChanged(m),
                      compact: false,
                      size: itemSize,
                    ),
                  ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.mode,
    required this.selected,
    required this.onTap,
    required this.compact,
    required this.size,
  });
  final MicMode mode;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final double size;

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
        message: '${mode.label}: ${micModeHint(mode)}',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('mic-mode-${mode.name}'),
            borderRadius: BorderRadius.circular(WoiRadii.sm + 2),
            onTap: onTap,
            child: Container(
              constraints: BoxConstraints(minHeight: size, minWidth: size),
              padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(WoiRadii.sm + 2),
                color: selected ? WoiColors.bg1 : null,
                border: selected ? Border.all(color: WoiColors.stroke) : null,
              ),
              child: compact
                  ? Icon(micModeIcon(mode), size: size < 40 ? 16 : 20, color: c)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(micModeIcon(mode), size: 18, color: c),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            mode.label,
                            softWrap: false,
                            overflow: TextOverflow.fade,
                            style: body(
                              13,
                              weight: FontWeight.w500,
                              color: selected ? WoiColors.text : WoiColors.textDim,
                            ),
                          ),
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

/// One microphone control: tap toggles listening, hold records a message.
/// A cancelled gesture never sends, including route disposal and pointer loss.
class MicButton extends StatefulWidget {
  const MicButton({
    super.key,
    required this.mode,
    required this.held,
    required this.onModeChanged,
    required this.onPttDown,
    required this.onPttUp,
    this.onPttCancel,
    this.level,
    this.size = kTouchTarget,
    this.enabled = true,
  });

  final MicMode mode;
  final bool held;
  final ValueChanged<MicMode> onModeChanged;
  final VoidCallback onPttDown;
  final VoidCallback onPttUp;
  final VoidCallback? onPttCancel;
  final ValueListenable<double>? level;
  final double size;
  final bool enabled;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  bool _holding = false;

  void _cancel() {
    if (!_holding) return;
    _holding = false;
    widget.onPttCancel?.call();
  }

  @override
  void didUpdateWidget(MicButton old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) _cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _toggle() {
    if (!widget.enabled) return;
    widget.onModeChanged(widget.mode == MicMode.handsFree ? MicMode.muted : MicMode.handsFree);
  }

  @override
  Widget build(BuildContext context) {
    final held = widget.held || _holding;
    final listening = widget.mode == MicMode.handsFree;
    final live = listening || held;
    final label = held
        ? 'Recording microphone and system audio. Release to send'
        : listening
        ? 'Microphone on. Click to turn off'
        : 'Microphone off. Click to turn on';
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      hint: 'Hold to record microphone and system audio, release to send',
      excludeSemantics: true,
      onTap: widget.enabled ? _toggle : null,
      child: Tooltip(
        message: '$label\nHold to record microphone and system audio; release to send.',
        child: MouseRegion(
          cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: Listener(
            onPointerCancel: (_) {
              _cancel();
              if (mounted) setState(() {});
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? _toggle : null,
              onLongPressStart: !widget.enabled
                  ? null
                  : (_) {
                      setState(() => _holding = true);
                      widget.onPttDown();
                    },
              onLongPressEnd: !widget.enabled
                  ? null
                  : (_) {
                      if (!_holding) return;
                      setState(() => _holding = false);
                      widget.onPttUp();
                    },
              onLongPressCancel: () {
                _cancel();
                if (mounted) setState(() {});
              },
              child: AnimatedContainer(
                key: const ValueKey('mic-button'),
                duration: WoiMotion.fast,
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: held
                      ? WoiColors.red
                      : live
                      ? WoiColors.cyan
                      : WoiColors.glass,
                  border: Border.all(color: live ? WoiColors.cyan : WoiColors.strokeStrong),
                ),
                child: Icon(
                  held
                      ? Icons.graphic_eq_rounded
                      : listening
                      ? Icons.mic_rounded
                      : Icons.mic_off_rounded,
                  size: widget.size * 0.46,
                  color: !widget.enabled
                      ? WoiColors.textFaint
                      : live
                      ? WoiColors.onAccent
                      : WoiColors.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wide hold-to-talk button.
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
        child: Container(
          height: kTouchTarget,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WoiRadii.md),
            color: held ? WoiColors.cyan : WoiColors.cyan.withValues(alpha: 0.08),
            border: Border.all(color: WoiColors.cyan.withValues(alpha: held ? 1 : 0.35)),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                held ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: held ? WoiColors.onAccent : WoiColors.cyan,
              ),
              const SizedBox(width: 10),
              Text(
                held ? 'Listening… release to send' : 'Hold to talk  ·  Space',
                style: body(14, weight: FontWeight.w600, color: held ? WoiColors.onAccent : WoiColors.cyan),
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
    this.disabledHint = 'Connecting…',
    this.trailing,
    this.framed = true,
    this.actionsBelow = false,
    this.actionsLeading,
  });
  final ValueChanged<String> onSend;
  final VoidCallback? onStop;
  final bool enabled;
  final bool showStop;
  final FocusNode? focusNode;
  final String? hint;

  /// Shown while [enabled] is false (connecting, or offline after an error).
  final String disabledHint;

  /// Extra control after the send/stop button (the mic in the input bar).
  final Widget? trailing;

  /// Draws its own bordered field; false inside a surface that already has one.
  final bool framed;

  /// A single controls row below the text field, with send at the far right.
  final bool actionsBelow;
  final Widget? actionsLeading;

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
    final field = TextField(
      key: const ValueKey('composer-field'),
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
        hintText: widget.enabled ? (widget.hint ?? 'Type a message…') : widget.disabledHint,
        filled: false,
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(10, 14, 6, 14),
      ),
    );
    final send = widget.showStop && empty
        ? IconButton.filled(
            key: const ValueKey('stop'),
            tooltip: 'Stop (Esc)',
            style: IconButton.styleFrom(
              backgroundColor: WoiColors.red.withValues(alpha: 0.12),
              foregroundColor: WoiColors.red,
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
              disabledForegroundColor: WoiColors.textFaint,
            ),
            onPressed: empty || !widget.enabled ? null : _send,
            icon: const Icon(Icons.arrow_upward_rounded),
          );
    final row = widget.actionsBelow
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              Row(
                key: const ValueKey('composer-controls'),
                children: [
                  if (widget.actionsLeading != null) widget.actionsLeading!,
                  const Spacer(),
                  if (widget.trailing != null) ...[widget.trailing!, const SizedBox(width: 6)],
                  send,
                ],
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: field),
              const SizedBox(width: 4),
              send,
              if (widget.trailing != null) ...[const SizedBox(width: 6), widget.trailing!],
            ],
          );
    if (!widget.framed) return row;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: WoiColors.bg1,
        borderRadius: BorderRadius.circular(WoiRadii.lg),
        border: Border.all(color: _focused ? WoiColors.cyan : WoiColors.strokeStrong),
      ),
      child: row,
    );
  }
}
