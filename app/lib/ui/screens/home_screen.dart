import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../core/context/context_manager.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';
import '../widgets/context_meter.dart';
import '../widgets/controls.dart';
import '../widgets/glass.dart';
import '../widgets/message_tile.dart';
import '../widgets/voice_orb.dart';
import 'history_drawer.dart';
import 'settings_screen.dart';

const kWideBreakpoint = 1000.0;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  StreamSubscription<ContextCompacted>? _compactSub;

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  @override
  void initState() {
    super.initState();
    _compactSub = pipeline.compactionEvents.listen(_onCompacted);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _compactSub?.cancel();
    super.dispose();
  }

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Space = push-to-talk (when not typing), Esc = interrupt the assistant.
  bool _onKey(KeyEvent e) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (e.logicalKey == LogicalKeyboardKey.space && !_typing && c.settings.micMode == MicMode.pushToTalk) {
      if (e is KeyDownEvent) pipeline.pttDown();
      if (e is KeyUpEvent) pipeline.pttUp();
      return true;
    }
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && !_typing) {
      final ph = pipeline.phase;
      if (ph == AssistantPhase.speaking || ph == AssistantPhase.thinking) {
        pipeline.interrupt();
        return true;
      }
    }
    return false;
  }

  void _onCompacted(ContextCompacted e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 460,
        duration: const Duration(seconds: 4),
        content: Row(
          children: [
            const Icon(Icons.compress, color: WoiColors.violet, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Context compacted  ${formatTokens(e.tokensBefore)} → ${formatTokens(e.tokensAfter)}  '
                '(${e.compactedMessages} messages)',
                style: body(13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(controller: c)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: HistoryDrawer(controller: c),
      body: WoiBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= kWideBreakpoint;
              return ListenableBuilder(
                listenable: Listenable.merge([c, pipeline]),
                builder: (context, _) => wide ? _wide(box) : _narrow(box),
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- layouts

  Widget _wide(BoxConstraints box) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    child: Column(
      children: [
        _header(wide: true),
        const SizedBox(height: 14),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: box.maxWidth >= 1300 ? 380 : 330, child: _sidePanel()),
              const SizedBox(width: 20),
              Expanded(
                child: GlassPanel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Expanded(child: _transcript(maxBubble: 680)),
                      Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 18), child: _composer()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _narrow(BoxConstraints box) {
    final orbSize = (box.maxHeight * 0.2).clamp(110.0, 170.0);
    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 0), child: _header(wide: false)),
        SizedBox(
          height: orbSize + 8,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RepaintBoundary(
                child: VoiceOrb(
                  phase: pipeline.phase,
                  micLevel: pipeline.micLevel,
                  outputLevel: pipeline.outputLevel,
                  size: orbSize,
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _phaseText(),
                  const SizedBox(height: 10),
                  MicModeSelector(mode: c.settings.micMode, onChanged: c.setMicMode, compact: true),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _transcript(maxBubble: box.maxWidth * 0.84)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            children: [
              if (c.settings.micMode == MicMode.pushToTalk) ...[
                PushToTalkButton(pipeline: pipeline),
                const SizedBox(height: 10),
              ],
              _composer(),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ parts

  Widget _header({required bool wide}) {
    final (statusColor, statusLabel) = switch (pipeline.status) {
      SessionStatus.connected => (WoiColors.mint, 'live'),
      SessionStatus.connecting => (WoiColors.amber, 'connecting'),
      SessionStatus.disconnected => (WoiColors.textDim, 'offline'),
      SessionStatus.error => (WoiColors.red, 'error'),
    };
    final backendName = pipeline.backend?.runtimeType.toString().replaceAll('VoiceBackend', '') ?? '';
    return Row(
      children: [
        ShaderMask(
          shaderCallback: (r) =>
              const LinearGradient(colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta]).createShader(r),
          child: Text(
            'WOI',
            style: display(wide ? 26 : 22, weight: FontWeight.w700, color: Colors.white, spacing: 6),
          ),
        ),
        const SizedBox(width: 14),
        Tooltip(
          message: [
            if (backendName.isNotEmpty) 'Backend: $backendName',
            '${c.activeVoiceModel} · ${c.settings.voice}',
            ?pipeline.statusDetail,
          ].join('\n'),
          child: Pill(
            label: wide && backendName.isNotEmpty ? '$statusLabel · $backendName' : statusLabel,
            color: statusColor,
            icon: Icons.circle,
            dense: !wide,
          ),
        ),
        const Spacer(),
        if (wide)
          Text(
            pipeline.conversation.title,
            style: body(13, color: WoiColors.textDim),
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(width: 16),
        ContextMeter(manager: c.contextManager, compact: true),
        const SizedBox(width: 8),
        if (pipeline.status == SessionStatus.error || pipeline.status == SessionStatus.disconnected)
          IconButton(tooltip: 'Reconnect', onPressed: pipeline.connect, icon: const Icon(Icons.refresh)),
        IconButton(
          tooltip: 'New conversation',
          onPressed: c.newConversation,
          icon: const Icon(Icons.add_comment_outlined),
        ),
        IconButton(
          tooltip: 'History',
          onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          icon: const Icon(Icons.history),
        ),
        IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.tune)),
      ],
    );
  }

  Widget _phaseText() {
    final ph = pipeline.phase;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Text(
        phaseLabel(ph),
        key: ValueKey(ph),
        style: display(18, color: phaseColor(ph)),
      ),
    );
  }

  Widget _sidePanel() {
    final s = c.settings;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: LayoutBuilder(
        builder: (context, box) {
          final orb = (box.maxHeight * 0.45).clamp(160.0, box.maxWidth - 20);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RepaintBoundary(
                      child: VoiceOrb(
                        phase: pipeline.phase,
                        micLevel: pipeline.micLevel,
                        outputLevel: pipeline.outputLevel,
                        size: orb,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _phaseText(),
                    const SizedBox(height: 4),
                    Text(switch (s.micMode) {
                      MicMode.handsFree => 'Just talk. Interrupt any time.',
                      MicMode.pushToTalk => 'Hold the button or Space to talk.',
                      MicMode.muted => 'Microphone is off. Type below.',
                    }, style: body(13, color: WoiColors.textDim)),
                  ],
                ),
              ),
              Center(
                child: MicModeSelector(mode: s.micMode, onChanged: c.setMicMode),
              ),
              if (s.micMode == MicMode.pushToTalk) ...[
                const SizedBox(height: 12),
                PushToTalkButton(pipeline: pipeline),
              ],
              const SizedBox(height: 22),
              ContextMeter(manager: c.contextManager, onCompact: c.compactNow),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Pill(
                    label: s.autoScreenshot
                        ? 'screenshot +${(s.screenshotDelayMs / 1000).toStringAsFixed(1)}s'
                        : 'screenshots off',
                    icon: Icons.screenshot_monitor,
                    color: s.autoScreenshot ? WoiColors.cyan : WoiColors.textDim,
                    dense: true,
                  ),
                  Pill(
                    label: s.confirmBeforeBash ? 'bash needs approval' : 'bash auto-runs',
                    icon: Icons.terminal,
                    color: s.confirmBeforeBash ? WoiColors.mint : WoiColors.amber,
                    dense: true,
                  ),
                  Pill(
                    label: c.activeVoiceModel,
                    icon: Icons.record_voice_over_outlined,
                    color: WoiColors.violet,
                    dense: true,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _transcript({required double maxBubble}) {
    final msgs = pipeline.conversation.messages;
    if (msgs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Say something.', style: display(22)),
              const SizedBox(height: 8),
              Text(
                'Try "take a screenshot", "run uname -a", "list my home folder" or "what is on my screen?"',
                textAlign: TextAlign.center,
                style: body(14, color: WoiColors.textDim),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final m = msgs[msgs.length - 1 - i];
        return MessageTile(
          key: ValueKey(m.id),
          message: m,
          audio: c.platform.audio,
          viewer: c.platform.viewer,
          maxBubbleWidth: maxBubble,
        );
      },
    );
  }

  Widget _composer() {
    final ph = pipeline.phase;
    return Composer(
      enabled: pipeline.status == SessionStatus.connected,
      showStop: ph == AssistantPhase.speaking || ph == AssistantPhase.thinking,
      onStop: pipeline.interrupt,
      onSend: pipeline.sendText,
    );
  }
}
