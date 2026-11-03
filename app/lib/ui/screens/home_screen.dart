import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../core/context/context_manager.dart';
import '../../core/models/message.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';
import '../widgets/banner.dart';
import '../widgets/context_meter.dart';
import '../widgets/controls.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/message_tile.dart';
import '../widgets/status_chip.dart';
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
  final _composerFocus = FocusNode(debugLabel: 'composer');
  final _banners = BannerController();
  StreamSubscription<ContextCompacted>? _compactSub;

  bool _wasConnected = false;
  SessionStatus? _lastStatus;

  /// Phone: bottom bar shows the text composer instead of the mic.
  bool _phoneTyping = false;

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  @override
  void initState() {
    super.initState();
    _compactSub = pipeline.compactionEvents.listen(_onCompacted);
    pipeline.addListener(_onPipeline);
    _onPipeline();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    pipeline.removeListener(_onPipeline);
    _compactSub?.cancel();
    _composerFocus.dispose();
    _banners.dispose();
    super.dispose();
  }

  void _onPipeline() {
    final s = pipeline.status;
    if (s == _lastStatus) return;
    final prev = _lastStatus;
    _lastStatus = s;
    if (s == SessionStatus.connected) {
      _wasConnected = true;
      _banners.dismiss('link');
    } else if (s == SessionStatus.error && prev != SessionStatus.error) {
      _banners.show(
        BannerData(
          id: 'link',
          icon: Icons.wifi_off_rounded,
          color: WoiColors.red,
          title: 'Voice session failed',
          message: pipeline.statusDetail ?? 'The realtime connection could not be established.',
          actionLabel: 'Retry',
          onAction: pipeline.connect,
          autoDismiss: null,
        ),
      );
    }
  }

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Global shortcuts. Space = push-to-talk (when not typing), Esc =
  /// interrupt, Ctrl+K = type, Ctrl+, = settings, Ctrl+N = new chat.
  bool _onKey(KeyEvent e) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final key = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (key == LogicalKeyboardKey.space && !_typing && !ctrl && c.settings.micMode == MicMode.pushToTalk) {
      if (e is KeyDownEvent) pipeline.pttDown();
      if (e is KeyUpEvent) pipeline.pttUp();
      return true;
    }
    if (e is! KeyDownEvent) return false;
    if (ctrl && key == LogicalKeyboardKey.keyK) {
      _focusComposer();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.comma) {
      _openSettings();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyN) {
      c.newConversation();
      return true;
    }
    if (key == LogicalKeyboardKey.escape && !_typing) {
      final ph = pipeline.phase;
      if (ph == AssistantPhase.speaking || ph == AssistantPhase.thinking || ph == AssistantPhase.toolRunning) {
        pipeline.interrupt();
        return true;
      }
    }
    return false;
  }

  void _focusComposer() {
    setState(() => _phoneTyping = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _composerFocus.requestFocus());
  }

  void _onCompacted(ContextCompacted e) {
    if (!mounted) return;
    _banners.show(
      BannerData(
        id: 'compaction',
        icon: Icons.compress_rounded,
        color: WoiColors.violet,
        title: compactionBannerText(formatTokens(e.tokensBefore), formatTokens(e.tokensAfter)),
        message: '${e.compactedMessages} earlier messages were summarized.',
      ),
    );
  }

  void _openSettings() => Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: WoiMotion.slow,
      reverseTransitionDuration: WoiMotion.medium,
      pageBuilder: (_, _, _) => SettingsScreen(controller: c),
      transitionsBuilder: (context, a, _, child) {
        final curved = CurvedAnimation(parent: a, curve: WoiMotion.emphasized);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );

  void _openHistory() => _scaffoldKey.currentState?.openDrawer();

  OrbMode get _orbMode =>
      orbModeFor(pipeline.phase, status: pipeline.status, compacting: c.contextManager.compressing);

  bool get _connected => pipeline.status == SessionStatus.connected;
  bool get _canStop {
    final ph = pipeline.phase;
    return ph == AssistantPhase.speaking || ph == AssistantPhase.thinking || ph == AssistantPhase.toolRunning;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, outer) {
        final wide = outer.maxWidth >= kWideBreakpoint;
        return Scaffold(
          key: _scaffoldKey,
          resizeToAvoidBottomInset: true,
          drawer: HistoryDrawer(controller: c),
          drawerEdgeDragWidth: wide ? null : 32,
          body: ListenableBuilder(
            listenable: Listenable.merge([c, pipeline, c.contextManager]),
            builder: (context, _) => WoiBackdrop(
              accent: orbModeColor(_orbMode),
              child: SafeArea(
                child: LayoutBuilder(builder: (context, box) => wide ? _wide(box) : _narrow(box)),
              ),
            ),
          ),
        );
      },
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
              SizedBox(width: box.maxWidth >= 1300 ? 380 : 340, child: _sidePanel()),
              const SizedBox(width: 20),
              Expanded(
                child: GlassPanel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Expanded(child: _transcriptArea(maxBubble: 700, wide: true)),
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
    final empty = pipeline.conversation.messages.isEmpty;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final orbSize = empty && !keyboardUp ? (box.maxHeight * 0.3).clamp(150.0, 240.0) : 76.0;
    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 4, 6, 0), child: _header(wide: false)),
        AnimatedSize(
          duration: WoiMotion.slow,
          curve: WoiMotion.emphasized,
          child: empty && !keyboardUp ? _phoneHero(orbSize) : _phoneStrip(orbSize),
        ),
        Expanded(child: _transcriptArea(maxBubble: box.maxWidth * 0.86, wide: false)),
        _phoneBottomBar(),
      ],
    );
  }

  // ------------------------------------------------------------------ parts

  Widget _logo(double size) => Semantics(
    header: true,
    label: 'Woi',
    child: ExcludeSemantics(
      child: ShaderMask(
        shaderCallback: (r) =>
            const LinearGradient(colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta]).createShader(r),
        child: Text('WOI', style: display(size, weight: FontWeight.w700, color: Colors.white, spacing: 6)),
      ),
    ),
  );

  Widget _statusChip({required bool compact}) => ConnectionStatusChip(
    state: linkStateFor(pipeline.status, wasConnected: _wasConnected),
    model: c.activeVoiceModel,
    backend: c.activeBackendMode,
    voice: c.settings.activeVoice,
    detail: pipeline.statusDetail,
    onRetry: pipeline.connect,
    compact: compact,
  );

  Widget _header({required bool wide}) {
    if (!wide) {
      return Row(
        children: [
          GlassIconButton(icon: Icons.menu_rounded, tooltip: 'History', onPressed: _openHistory, size: kTouchTarget),
          const SizedBox(width: 4),
          _logo(20),
          const SizedBox(width: 10),
          Flexible(child: _statusChip(compact: true)),
          const Spacer(),
          ContextMeter(
            manager: c.contextManager,
            conversation: pipeline.conversation,
            style: ContextMeterStyle.ring,
            onCompact: c.compactNow,
          ),
          GlassIconButton(
            icon: Icons.tune_rounded,
            tooltip: 'Settings',
            onPressed: _openSettings,
            size: kTouchTarget,
          ),
        ],
      );
    }
    return Row(
      children: [
        GlassIconButton(icon: Icons.menu_rounded, tooltip: 'History', onPressed: _openHistory),
        const SizedBox(width: 12),
        _logo(26),
        const SizedBox(width: 18),
        Flexible(child: _statusChip(compact: false)),
        const Spacer(),
        ContextMeter(
          manager: c.contextManager,
          conversation: pipeline.conversation,
          style: ContextMeterStyle.bar,
          onCompact: c.compactNow,
        ),
        const SizedBox(width: 18),
        GlassIconButton(icon: Icons.add_comment_outlined, tooltip: 'New conversation (Ctrl+N)', onPressed: c.newConversation),
        const SizedBox(width: 6),
        GlassIconButton(icon: Icons.tune_rounded, tooltip: 'Settings (Ctrl+,)', onPressed: _openSettings),
      ],
    );
  }

  Widget _modeLabel({double size = 20}) {
    final m = _orbMode;
    return AnimatedSwitcher(
      duration: WoiMotion.medium,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a),
          child: c,
        ),
      ),
      child: Text(
        orbModeLabel(m),
        key: ValueKey(m),
        style: display(size, color: orbModeColor(m), spacing: 0.6),
      ),
    );
  }

  Widget _orb(double size) => RepaintBoundary(
    child: VoiceOrb(mode: _orbMode, micLevel: pipeline.micLevel, outputLevel: pipeline.outputLevel, size: size),
  );

  Widget _sidePanel() {
    final s = c.settings;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
      glow: orbModeColor(_orbMode),
      child: LayoutBuilder(
        builder: (context, box) {
          final orb = (box.maxHeight * 0.5).clamp(160.0, box.maxWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('VOICE', style: eyebrow()),
                  const Spacer(),
                  Text(
                    s.activeVoice.toUpperCase(),
                    style: eyebrow(color: WoiColors.violet.withValues(alpha: 0.9)),
                  ),
                ],
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(dimension: orb, child: _orb(orb)),
                    const SizedBox(height: 4),
                    _modeLabel(),
                    const SizedBox(height: 6),
                    Text(
                      micModeHint(s.micMode),
                      textAlign: TextAlign.center,
                      style: body(13, color: WoiColors.textDim),
                    ),
                  ],
                ),
              ),
              Center(child: MicModeSelector(mode: s.micMode, onChanged: c.setMicMode)),
              AnimatedSize(
                duration: WoiMotion.medium,
                curve: WoiMotion.curve,
                child: s.micMode == MicMode.pushToTalk
                    ? Padding(padding: const EdgeInsets.only(top: 12), child: PushToTalkButton(pipeline: pipeline))
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 18),
              ContextMeter(
                manager: c.contextManager,
                conversation: pipeline.conversation,
                onCompact: c.compactNow,
              ),
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
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _phoneHero(double size) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Column(
      children: [
        SizedBox.square(dimension: size, child: _orb(size)),
        _modeLabel(size: 18),
      ],
    ),
  );

  Widget _phoneStrip(double size) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 16, 2),
    child: Row(
      children: [
        SizedBox.square(dimension: size, child: _orb(size)),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeLabel(size: 16),
              const SizedBox(height: 2),
              Text(
                micModeHint(c.settings.micMode),
                style: body(12, color: WoiColors.textDim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _phoneBottomBar() {
    final s = c.settings;
    final stop = _canStop
        ? Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _StopPill(onTap: pipeline.interrupt),
          )
        : const SizedBox.shrink();
    final bar = _phoneTyping
        ? Row(
            key: const ValueKey('typing'),
            children: [
              Expanded(child: _composer(phone: true)),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: Icons.mic_none_rounded,
                tooltip: 'Back to voice',
                size: kTouchTarget + 4,
                onPressed: () {
                  _composerFocus.unfocus();
                  setState(() => _phoneTyping = false);
                },
              ),
            ],
          )
        : SizedBox(
            key: const ValueKey('voice'),
            height: 84,
            child: Row(
              children: [
                GlassIconButton(
                  icon: Icons.keyboard_alt_outlined,
                  tooltip: 'Type a message',
                  size: kTouchTarget + 4,
                  onPressed: _focusComposer,
                ),
                Expanded(
                  child: Center(
                    child: MicButton(
                      mode: s.micMode,
                      held: pipeline.pttHeld,
                      onModeChanged: c.setMicMode,
                      onPttDown: pipeline.pttDown,
                      onPttUp: pipeline.pttUp,
                      level: pipeline.micLevel,
                      enabled: _connected,
                    ),
                  ),
                ),
                _MicModeMenu(mode: s.micMode, onChanged: c.setMicMode),
              ],
            ),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(duration: WoiMotion.medium, child: _canStop ? stop : const SizedBox.shrink()),
          GlassPanel(
            radius: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: AnimatedSwitcher(
              duration: WoiMotion.medium,
              switchInCurve: WoiMotion.emphasized,
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: c),
              ),
              child: bar,
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcriptArea({required double maxBubble, required bool wide}) {
    return Stack(
      children: [
        Positioned.fill(child: _transcript(maxBubble: maxBubble, wide: wide)),
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Center(child: BannerStack(controller: _banners)),
        ),
      ],
    );
  }

  Widget _transcript({required double maxBubble, required bool wide}) {
    final msgs = pipeline.conversation.messages;
    if (msgs.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: EmptyState(
            subtitle: switch (c.settings.micMode) {
              MicMode.handsFree => 'Just start talking — or try one of these.',
              MicMode.pushToTalk => wide ? 'Hold Space to talk — or try one of these.' : 'Hold the mic to talk — or try one of these.',
              MicMode.muted => 'Microphone is off. Type below or tap a suggestion.',
            },
            onHint: pipeline.sendText,
            showShortcuts: wide,
            enabled: _connected,
          ),
        ),
      );
    }
    // Latest screenshot at or before each message (for click markers).
    final shots = List<ImageAttachment?>.filled(msgs.length, null);
    ImageAttachment? last;
    for (var i = 0; i < msgs.length; i++) {
      shots[i] = last;
      final img = msgs[i].image;
      if (img != null) last = img;
    }
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.fromLTRB(wide ? 22 : 12, 16, wide ? 22 : 12, 8),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final idx = msgs.length - 1 - i;
        final m = msgs[idx];
        return MessageTile(
          key: ValueKey(m.id),
          message: m,
          audio: c.platform.audio,
          viewer: c.platform.viewer,
          maxBubbleWidth: maxBubble,
          screenshot: m.kind == MessageKind.tool ? shots[idx] : null,
        );
      },
    );
  }

  Widget _composer({bool phone = false}) {
    return Composer(
      focusNode: _composerFocus,
      enabled: _connected,
      showStop: !phone && _canStop,
      onStop: pipeline.interrupt,
      onSend: pipeline.sendText,
      hint: phone ? 'Message Woi' : 'Message Woi…  (Ctrl+K)',
    );
  }
}

class _StopPill extends StatelessWidget {
  const _StopPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Stop Woi',
    excludeSemantics: true,
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: WoiColors.red.withValues(alpha: 0.14),
            border: Border.all(color: WoiColors.red.withValues(alpha: 0.5)),
            boxShadow: [BoxShadow(color: WoiColors.red.withValues(alpha: 0.25), blurRadius: 18)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.stop_rounded, color: WoiColors.red),
              const SizedBox(width: 6),
              Text('Stop', style: body(14, weight: FontWeight.w600, color: WoiColors.red)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MicModeMenu extends StatelessWidget {
  const _MicModeMenu({required this.mode, required this.onChanged});
  final MicMode mode;
  final ValueChanged<MicMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<MicMode>(
    tooltip: 'Microphone mode',
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
              Text(switch (m) {
                MicMode.handsFree => 'Hands-free',
                MicMode.pushToTalk => 'Push to talk',
                MicMode.muted => 'Muted',
              }, style: body(14, weight: m == mode ? FontWeight.w600 : FontWeight.w400)),
            ],
          ),
        ),
    ],
    child: Container(
      width: kTouchTarget + 4,
      height: kTouchTarget + 4,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: WoiColors.glass,
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Icon(micModeIcon(mode), size: 22, color: WoiColors.textDim),
    ),
  );
}
