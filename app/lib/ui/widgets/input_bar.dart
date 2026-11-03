import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';
import 'context_meter.dart';
import 'controls.dart';
import 'status_chip.dart';
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, pipeline]),
      builder: (context, _) {
        final status = pipeline.status;
        if (status == SessionStatus.connected) _wasConnected = true;
        final connected = status == SessionStatus.connected;
        final ph = pipeline.phase;
        final canStop = ph == AssistantPhase.speaking || ph == AssistantPhase.thinking || ph == AssistantPhase.toolRunning;
        final s = c.settings;
        final phone = widget.phone;
        final mode = voiceModeFor(ph, status: status, compacting: c.contextManager.compressing);

        final composer = Composer(
          focusNode: widget.focusNode,
          enabled: connected,
          showStop: canStop,
          onStop: pipeline.interrupt,
          onSend: pipeline.sendText,
          framed: false,
          hint: phone ? 'Message Woi' : 'Message Woi…  (Ctrl+K)',
          trailing: MicButton(
            mode: s.micMode,
            held: pipeline.pttHeld,
            onModeChanged: c.actions.setMicMode,
            onPttDown: pipeline.pttDown,
            onPttUp: pipeline.pttUp,
            enabled: connected,
          ),
        );

        final status_ = Row(
          children: [
            ListenableBuilder(
              listenable: pipeline.levelSourcesChanged,
              builder: (context, _) => VoiceStatusIndicator(
                mode: mode,
                micLevel: pipeline.micLevel,
                outputLevel: pipeline.outputLevel,
              ),
            ),
            _dot(),
            Flexible(
              child: ConnectionStatusChip(
                state: linkStateFor(status, wasConnected: _wasConnected),
                model: c.activeVoiceModel,
                backend: c.activeBackendMode,
                voice: s.activeVoice,
                detail: pipeline.statusDetail,
                onRetry: pipeline.connect,
                compact: phone,
              ),
            ),
            const Spacer(),
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
