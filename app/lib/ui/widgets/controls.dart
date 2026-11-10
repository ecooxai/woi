import 'dart:async';

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
    this.includesSystemAudio = false,
    this.level,
    this.size = kTouchTarget,
    this.visualSize,
    this.enabled = true,
  });

  final MicMode mode;
  final bool held;
  final ValueChanged<MicMode> onModeChanged;
  final VoidCallback onPttDown;
  final VoidCallback onPttUp;
  final VoidCallback? onPttCancel;
  final bool includesSystemAudio;
  final ValueListenable<double>? level;
  final double size;
  final double? visualSize;
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
    final sources = widget.includesSystemAudio ? 'microphone and system audio' : 'microphone';
    final label = held
        ? 'Recording $sources. Release to send'
        : listening
        ? 'Microphone on. Click to turn off'
        : 'Microphone off. Click to turn on';
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: label,
      hint: 'Hold to record $sources, release to send',
      excludeSemantics: true,
      onTap: widget.enabled ? _toggle : null,
      child: Tooltip(
        message: '$label\nHold to record $sources; release to send.',
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
              child: SizedBox.square(
                key: const ValueKey('mic-button'),
                dimension: widget.size,
                child: Center(
                  child: AnimatedContainer(
                    duration: WoiMotion.fast,
                    width: (widget.visualSize ?? widget.size),
                    height: (widget.visualSize ?? widget.size),
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
                          ? Icons.mic_none_rounded
                          : Icons.mic_off_outlined,
                      size: (widget.visualSize ?? widget.size) * 0.46,
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
    this.actionSize = kTouchTarget,
    this.controller,
    this.hasAttachments = false,
    this.onPaste,
    this.clearOnSend = true,
  });
  final FutureOr<void> Function(String) onSend;

  /// Shared drafts can own their accepted-send lifecycle and clear atomically.
  final bool clearOnSend;
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

  /// Smaller desktop controls retain the full phone touch size by default.
  final double actionSize;
  final TextEditingController? controller;
  final bool hasAttachments;
  final VoidCallback? onPaste;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  TextEditingController? _ownController;
  TextEditingController get _ctrl => widget.controller ?? (_ownController ??= TextEditingController());
  bool _sending = false;
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = _onKey;
    _focus.addListener(_onFocus);
    _ctrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _ownController)?.removeListener(_onTextChanged);
      _ctrl.addListener(_onTextChanged);
    }
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
    final keyboard = HardwareKeyboard.instance;
    if (e is KeyDownEvent &&
        widget.onPaste != null &&
        (((keyboard.isControlPressed || keyboard.isMetaPressed) &&
                !keyboard.isAltPressed &&
                e.logicalKey == LogicalKeyboardKey.keyV) ||
            (keyboard.isShiftPressed && e.logicalKey == LogicalKeyboardKey.insert))) {
      if (widget.enabled && !_sending) widget.onPaste!();
      return KeyEventResult.handled;
    }
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

  Future<void> _send() async {
    final controller = _ctrl;
    final original = controller.text;
    final t = original.trim();
    if ((t.isEmpty && !widget.hasAttachments) || !widget.enabled || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(t);
      if (mounted && widget.clearOnSend && identical(_ctrl, controller) && controller.text == original) {
        controller.clear();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ctrl.removeListener(_onTextChanged);
    _ownController?.dispose();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final empty = _ctrl.text.trim().isEmpty && !widget.hasAttachments;
    final field = TextField(
      key: const ValueKey('composer-field'),
      controller: _ctrl,
      focusNode: _focus,
      enabled: widget.enabled && !_sending,
      minLines: 1,
      maxLines: 6,
      style: body(15),
      textInputAction: TextInputAction.send,
      keyboardType: TextInputType.multiline,
      onSubmitted: (_) => unawaited(_send()),
      onEditingComplete: () {}, // keep focus after sending
      onChanged: (_) => setState(() {}),
      contextMenuBuilder: (context, editable) => AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editable.contextMenuAnchors,
        buttonItems: [
          for (final item in editable.contextMenuButtonItems)
            if (widget.onPaste == null || item.type != ContextMenuButtonType.paste) item,
          if (widget.onPaste != null)
            ContextMenuButtonItem(
              type: ContextMenuButtonType.paste,
              onPressed: () {
                editable.hideToolbar();
                if (widget.enabled && !_sending) widget.onPaste!();
              },
            ),
        ],
      ),
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
    final send = widget.showStop && (empty || _sending)
        ? IconButton.filled(
            key: const ValueKey('stop'),
            tooltip: 'Stop (Esc)',
            style: IconButton.styleFrom(
              backgroundColor: WoiColors.red.withValues(alpha: 0.12),
              foregroundColor: WoiColors.red,
              minimumSize: Size.square(widget.actionSize),
              fixedSize: Size.square(widget.actionSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            onPressed: widget.onStop,
            icon: Icon(Icons.stop_rounded, size: widget.actionSize * 0.5),
          )
        : IconButton.filled(
            key: const ValueKey('send'),
            tooltip: 'Send (Enter)',
            style: IconButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              minimumSize: Size.square(widget.actionSize),
              fixedSize: Size.square(widget.actionSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.padded,
              disabledBackgroundColor: WoiColors.glassStrong,
              disabledForegroundColor: WoiColors.textFaint,
            ),
            onPressed: empty || !widget.enabled || _sending ? null : () => unawaited(_send()),
            icon: _sending
                ? SizedBox(
                    width: widget.actionSize * .45,
                    height: widget.actionSize * .45,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.arrow_upward_rounded, size: widget.actionSize * 0.5),
          );
    final row = widget.actionsBelow
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              OverflowBar(
                key: const ValueKey('composer-controls'),
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  if (widget.actionsLeading != null) widget.actionsLeading!,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.trailing != null) ...[widget.trailing!, const SizedBox(width: 6)],
                      send,
                    ],
                  ),
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
