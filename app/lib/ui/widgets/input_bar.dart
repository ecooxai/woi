import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../../platform/audio_io.dart';
import '../../platform/clipboard_access.dart';
import '../theme.dart';
import 'camera_preview.dart';
import 'chat_draft.dart';
import 'context_meter.dart';
import 'screen_share_button.dart';
import 'controls.dart';
import 'throttled_builder.dart';
import 'voice_status.dart';

/// The bottom input bar: text field, send/stop and mic button, and a status
/// row with the voice state, the connection (with Retry), the mic mode and
/// the context meter. It listens to the pipeline itself, so nothing above
/// it rebuilds on phase changes.
class InputBar extends StatefulWidget {
  const InputBar({
    super.key,
    required this.controller,
    this.focusNode,
    this.phone = false,
    this.allowScreenShare = true,
    this.draft,
  });
  final AppController controller;
  final FocusNode? focusNode;
  final ChatDraftController? draft;

  /// The Android assist panel already owns screen sharing.
  final bool allowScreenShare;

  /// Phone layout: 48dp targets, short labels, mic-mode menu.
  final bool phone;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  ChatDraftController? _ownDraft;
  ChatDraftController get _draft => widget.draft ?? (_ownDraft ??= ChatDraftController());
  bool _picking = false;
  bool _pasting = false;

  void _notice(String message) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFiles() async {
    if (_picking || _draft.sending) return;
    final at = _draft.capturePasteTarget();
    setState(() => _picking = true);
    try {
      final files = await c.platform.filePicker.pickFiles();
      if (!mounted || files.isEmpty) return;
      _draft.addFiles(files, at: at);
      widget.focusNode?.requestFocus();
    } catch (error) {
      _notice(error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), ''));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _paste() async {
    if (_pasting || _draft.sending) return;
    _pasting = true;
    final draft = _draft;
    final at = draft.capturePasteTarget();
    try {
      final content = await c.platform.clipboard.readContent();
      if (!mounted || draft != _draft) return;
      if (content == null || content.isEmpty) {
        _notice('No text or image is available on the clipboard.');
        return;
      }
      draft.stageClipboard(content, at: at);
      try {
        await c.clipboardHistory.remember(content);
      } catch (error) {
        _notice('Pasted into your message, but history could not save the item: $error');
      }
    } catch (error) {
      _notice(error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), ''));
    } finally {
      _pasting = false;
    }
  }

  Future<void> _send(String text) async {
    final draft = _draft;
    if (draft.sending) return;
    draft.setSending(true);
    final submitted = draft.captureSubmission();
    try {
      if (submitted.attachments.isNotEmpty) {
        await c.sendAttachments(text, submitted.attachments);
      } else if (!await pipeline.sendText(text)) {
        throw StateError('Message was not sent. Your draft is kept so you can try again.');
      }
      draft.clearSubmitted(submitted);
    } finally {
      draft.setSending(false);
    }
  }

  void _startHold() => c.heldAudio.start();
  void _finishHold({bool cancelled = false}) {
    unawaited(cancelled ? c.heldAudio.cancel() : c.heldAudio.release());
  }

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  // What the bar shows of the pipeline: it rebuilds when one of these
  // changes, not on every pipeline notification (a streaming reply notifies
  // up to 15 times a second).
  late SelectedListenable<Object> _shown = _select();

  SelectedListenable<Object> _select() {
    final p = pipeline;
    return SelectedListenable<Object>(
      p,
      () => (
        p.status,
        p.phase,
        p.reconnecting,
        p.reconnectWaiting,
        p.pttHeld,
        p.statusDetail,
        p.conversation,
        p.capturingWhileConnecting,
      ),
    );
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (old.controller.pipeline != pipeline) {
      // The builder below still listens to the old one until it rebuilds.
      final stale = _shown;
      WidgetsBinding.instance.addPostFrameCallback((_) => stale.dispose());
      _shown = _select();
    }
  }

  @override
  void dispose() {
    if (c.heldAudio.recording) _finishHold(cancelled: true);
    _shown.dispose();
    _ownDraft?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The context manager too: "Compacting memory…" (an animation) must
      // end when the compaction does, not at the next pipeline change.
      listenable: Listenable.merge([c, _shown, c.camera.active, c.contextManager, c.heldAudio, _draft]),
      builder: (context, _) {
        final status = pipeline.status;
        final connected = status == SessionStatus.connected;
        final standby = pipeline.standby;
        final ph = pipeline.phase;
        final canStop =
            _draft.sending ||
            ph == AssistantPhase.speaking ||
            ph == AssistantPhase.thinking ||
            ph == AssistantPhase.toolRunning;
        final s = c.settings;
        final phone = widget.phone;
        final compactControls = defaultTargetPlatform == TargetPlatform.linux;
        final includesSystemAudio = switch (c.platform.audio) {
          final HeldAudioCapture capture => capture.includesSystemAudio,
          _ => false,
        };
        final recordingSources = includesSystemAudio ? 'microphone and system audio' : 'microphone';
        // A saved legacy PTT mode forwards nothing until Space is held. Treat
        // it as mic-off in the tap/hold UI, while keeping old settings readable.
        final idlePtt = s.micMode == MicMode.pushToTalk && !pipeline.pttHeld && ph == AssistantPhase.listening;
        final mode = c.heldAudio.recording
            ? VoiceMode.hearing
            : c.heldAudio.processing
            ? VoiceMode.thinking
            : voiceModeFor(
                idlePtt ? AssistantPhase.idle : ph,
                status: status,
                compacting: c.contextManager.compressing,
                reconnecting: pipeline.reconnecting,
                standby: standby,
              );

        final micPaused = switch (c.platform.audio) {
          final AudioRouted r => r.micPaused,
          _ => null,
        };
        final voiceState = ListenableBuilder(
          listenable: Listenable.merge([pipeline.levelSourcesChanged, ?micPaused]),
          builder: (context, _) => VoiceStatusButton(
            mode: mode,
            detail: [
              if (c.heldAudio.recording)
                c.heldAudio.limitReached
                    ? 'Recording limit reached. Release to send, or cancel to discard.'
                    : 'Recording $recordingSources. Release to send.',
              if (c.heldAudio.processing) 'Preparing the recorded audio for your message.',
              if (micPaused?.value != null) micPaused!.value!,
              if (pipeline.capturingWhileConnecting) 'Microphone is recording while the session connects.',
              if (pipeline.voiceInputNeedsReconnect)
                pipeline.canSendTypedInput
                    ? 'Voice input is paused. Choose Reconnect before speaking, or send a typed message.'
                    : 'Voice input is paused. Choose Reconnect before trying again.',
              if (pipeline.statusDetail?.isNotEmpty ?? false) pipeline.statusDetail!,
              if (c.platform.audio is EchoCancellable)
                'Echo cancellation: ${(c.platform.audio as EchoCancellable).echoCancellationStatus}',
            ].join('\n'),
            onRetry:
                pipeline.voiceInputNeedsReconnect ||
                    status == SessionStatus.error ||
                    status == SessionStatus.disconnected
                ? () => unawaited(pipeline.reconnect())
                : null,
          ),
        );
        final composer = Composer(
          focusNode: widget.focusNode,
          controller: _draft.text,
          hasAttachments: _draft.hasAttachments,
          onPaste: () => unawaited(_paste()),
          enabled: c.ready,
          showStop: canStop,
          onStop: pipeline.interrupt,
          onSend: _send,
          clearOnSend: false,
          framed: false,
          actionsBelow: true,
          actionSize: compactControls ? 40 : kTouchTarget,
          hint: phone ? 'Message Woi' : 'Message Woi…  (Ctrl+K)',
          disabledHint: composerDisabledHint(status),
          actionsLeading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              voiceState,
              ContextMeter(
                manager: c.contextManager,
                conversation: pipeline.conversation,
                style: ContextMeterStyle.indicator,
                onCompact: c.compactNow,
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (defaultTargetPlatform == TargetPlatform.android && widget.allowScreenShare)
                const ScreenShareButton(size: kTouchTarget),
              IconButton(
                key: const ValueKey('attach-files'),
                tooltip: 'Add files',
                onPressed: _picking || _draft.sending ? null : () => unawaited(_pickFiles()),
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(kTouchTarget),
                  fixedSize: const Size.square(kTouchTarget),
                  padding: EdgeInsets.zero,
                  foregroundColor: WoiColors.textDim,
                ),
                icon: _picking
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_rounded, size: 25),
              ),
              CameraToggle(
                on: c.cameraOn,
                busy: c.cameraBusy,
                pending: c.camera.captureState.pending,
                onPressed: c.toggleCamera,
                size: kTouchTarget,
                visualSize: compactControls ? 44 : kTouchTarget,
              ),
              SizedBox(width: phone ? 0 : 6),
              MicButton(
                visualSize: compactControls ? 40 : kTouchTarget,
                mode: s.micMode,
                held: c.heldAudio.recording,
                includesSystemAudio: includesSystemAudio,
                onModeChanged: c.actions.setMicMode,
                onPttDown: _startHold,
                onPttUp: _finishHold,
                onPttCancel: () => _finishHold(cancelled: true),
                enabled: !c.heldAudio.processing && (connected || standby || status == SessionStatus.connecting),
              ),
            ],
          ),
        );

        return Container(
          key: const ValueKey('input-bar'),
          decoration: surfaceDecoration(radius: WoiRadii.lg),
          padding: EdgeInsets.fromLTRB(phone ? 4 : 6, 6, phone ? 4 : 6, phone ? 0 : 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.cameraOn)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 2, 4, 6),
                    child: CameraPreviewTile(camera: c.camera, onClose: c.toggleCamera),
                  ),
                ),
              ChatAttachmentTray(draft: _draft),
              composer,
            ],
          ),
        );
      },
    );
  }
}

/// The compact voice state: details on hover or click, without a model badge.
class VoiceStatusButton extends StatelessWidget {
  const VoiceStatusButton({super.key, required this.mode, this.detail = '', this.onRetry});
  final VoiceMode mode;
  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final label = voiceModeLabel(mode);
    final description = '$label${detail.isEmpty ? '' : '\n$detail'}';
    final icon = switch (mode) {
      VoiceMode.offline => Icons.cloud_off_outlined,
      VoiceMode.standby => Icons.bedtime_outlined,
      VoiceMode.connecting || VoiceMode.reconnecting => Icons.sync_rounded,
      VoiceMode.idle => Icons.mic_off_outlined,
      VoiceMode.listening => Icons.hearing_rounded,
      VoiceMode.hearing => Icons.graphic_eq_rounded,
      VoiceMode.thinking => Icons.more_horiz_rounded,
      VoiceMode.speaking => Icons.volume_up_outlined,
      VoiceMode.tool => Icons.build_outlined,
      VoiceMode.compacting => Icons.compress_rounded,
    };
    return Semantics(
      button: true,
      label: 'Voice status: $label. Show details',
      child: PopupMenuButton<String>(
        key: const ValueKey('voice-status-button'),
        tooltip: description,
        onSelected: (action) {
          if (action == 'retry') onRetry?.call();
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            enabled: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(description, style: body(13)),
            ),
          ),
          if (onRetry != null) const PopupMenuItem(value: 'retry', child: Text('Reconnect')),
        ],
        child: SizedBox.square(
          dimension: kTouchTarget,
          child: Icon(icon, size: 20, color: voiceModeColor(mode)),
        ),
      ),
    );
  }
}

/// Phone mic-mode button: the current mode's icon, a menu with all three.
class MicModeMenu extends StatelessWidget {
  const MicModeMenu({super.key, required this.mode, required this.onChanged});
  final MicMode mode;
  final ValueChanged<MicMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<MicMode>(
    key: const ValueKey('mic-mode-menu'),
    tooltip: 'Microphone mode: ${mode.label}',
    initialValue: mode,
    onSelected: onChanged,
    position: PopupMenuPosition.over,
    itemBuilder: (context) => [
      for (final m in MicMode.values)
        PopupMenuItem(
          value: m,
          height: kTouchTarget,
          child: Row(
            children: [
              Icon(micModeIcon(m), size: 20, color: m == mode ? WoiColors.cyan : WoiColors.textDim),
              const SizedBox(width: 12),
              Text(m.label, style: body(14, weight: m == mode ? FontWeight.w600 : FontWeight.w400)),
            ],
          ),
        ),
    ],
    child: SizedBox.square(
      dimension: kTouchTarget,
      child: Icon(micModeIcon(mode), size: 20, color: mode == MicMode.muted ? WoiColors.red : WoiColors.textDim),
    ),
  );
}

/// Composer placeholder while it cannot send: "Connecting…" only while a
/// connection is actually being made; after a failure it says so (the banner
/// above has the reason and Retry).
String composerDisabledHint(SessionStatus status) => switch (status) {
  SessionStatus.error => 'Offline — voice session failed (Retry)',
  _ => 'Connecting…',
};
