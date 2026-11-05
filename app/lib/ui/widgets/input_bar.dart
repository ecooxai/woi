import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../../platform/audio_io.dart';
import '../theme.dart';
import 'camera_preview.dart';
import 'context_meter.dart';
import 'controls.dart';
import 'status_chip.dart';
import 'throttled_builder.dart';
import 'voice_status.dart';

/// The bottom input bar: text field, send/stop and mic button, and a status
/// row with the voice state, the connection (with Retry), the mic mode and
/// the context meter. It listens to the pipeline itself, so nothing above
/// it rebuilds on phase changes.
class InputBar extends StatefulWidget {
  const InputBar({super.key, required this.controller, this.focusNode, this.phone = false});
  final AppController controller;
  final FocusNode? focusNode;

  /// Phone layout: 48dp targets, short labels, mic-mode menu.
  final bool phone;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  bool _wasConnected = false;

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
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The context manager too: "Compacting memory…" (an animation) must
      // end when the compaction does, not at the next pipeline change.
      listenable: Listenable.merge([c, _shown, c.camera.active, c.contextManager]),
      builder: (context, _) {
        final status = pipeline.status;
        if (status == SessionStatus.connected) _wasConnected = true;
        final connected = status == SessionStatus.connected;
        final ph = pipeline.phase;
        final canStop =
            ph == AssistantPhase.speaking || ph == AssistantPhase.thinking || ph == AssistantPhase.toolRunning;
        final s = c.settings;
        final phone = widget.phone;
        final mode = voiceModeFor(
          ph,
          status: status,
          compacting: c.contextManager.compressing,
          reconnecting: pipeline.reconnecting,
        );

        final composer = Composer(
          focusNode: widget.focusNode,
          enabled: connected,
          showStop: canStop,
          onStop: pipeline.interrupt,
          onSend: pipeline.sendText,
          framed: false,
          hint: phone ? 'Message Woi' : 'Message Woi…  (Ctrl+K)',
          disabledHint: composerDisabledHint(status),
          trailing: MicButton(
            mode: s.micMode,
            held: pipeline.pttHeld,
            onModeChanged: c.actions.setMicMode,
            onPttDown: pipeline.pttDown,
            onPttUp: pipeline.pttUp,
            // While connecting too: a press (or hands-free speech) is
            // recorded and sent once the session is ready.
            enabled: connected || status == SessionStatus.connecting,
          ),
        );

        final micPaused = switch (c.platform.audio) {
          final AudioRouted r => r.micPaused,
          _ => null,
        };
        final voiceState = ListenableBuilder(
          listenable: Listenable.merge([pipeline.levelSourcesChanged, ?micPaused]),
          builder: (context, _) => switch (micPaused?.value) {
            // Android: another app is recording; Woi's mic waits.
            final String why => Text(
                  why,
                  key: const ValueKey('mic-paused'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            _ => VoiceStatusIndicator(
              mode: mode,
              micLevel: pipeline.micLevel,
              outputLevel: pipeline.outputLevel,
              // Between reconnect attempts: still (the label says it).
              animate: mode == VoiceMode.reconnecting ? !pipeline.reconnectWaiting : null,
              compact: phone,
              capturing: pipeline.capturingWhileConnecting,
            ),
          },
        );
        final link = ConnectionStatusChip(
          state: linkStateFor(status, wasConnected: _wasConnected, reconnecting: pipeline.reconnecting),
          model: c.activeVoiceModel,
          backend: c.activeBackendMode,
          voice: s.activeVoice,
          detail: pipeline.statusDetail,
          onRetry: pipeline.connect,
          compact: phone,
        );
        final status_ = Row(
          children: [
            // The voice state and the connection get all the room the
            // buttons on the right leave (a Spacer here took a third of it:
            // at 360 px the labels were cut to "Mi…" and "real…"). Phones
            // show short labels and a dot-only connection chip (details in
            // its tooltip), so every voice state fits; elsewhere the labels
            // ellipsize rather than overflow.
            Expanded(
              child: Row(
                children: phone
                    ? [Flexible(child: voiceState), const SizedBox(width: 2), link]
                    : [Flexible(child: voiceState), _dot(), Flexible(child: link)],
              ),
            ),
            CameraToggle(
              on: c.cameraOn,
              busy: c.cameraBusy,
              onPressed: c.toggleCamera,
              size: phone ? kTouchTarget : 28,
            ),
            SizedBox(width: phone ? 0 : 8),
            phone
                ? MicModeMenu(mode: s.micMode, onChanged: c.actions.setMicMode)
                : MicModeSelector(mode: s.micMode, onChanged: c.actions.setMicMode, compact: true, itemSize: 28),
            SizedBox(width: phone ? 0 : 12),
            ContextMeter(
              manager: c.contextManager,
              conversation: pipeline.conversation,
              style: ContextMeterStyle.compact,
              dense: phone,
              onCompact: c.compactNow,
            ),
          ],
        );

        return Container(
          key: const ValueKey('input-bar'),
          decoration: surfaceDecoration(radius: WoiRadii.lg),
          padding: EdgeInsets.fromLTRB(6, 6, 6, phone ? 0 : 6),
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
              composer,
              Padding(
                padding: EdgeInsets.fromLTRB(phone ? 6 : 8, phone ? 0 : 4, 2, 0),
                child: Semantics(container: true, label: 'Status', child: status_),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _dot() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: body(12, color: WoiColors.textFaint)),
  );
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
