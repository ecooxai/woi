import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../core/context/context_manager.dart';
import '../../core/models/message.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../../platform/media_viewer.dart';
import '../notes/note_editor.dart';
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

/// Width from which the note and the chat can be shown side by side.
const kSplitBreakpoint = 1280.0;

/// The two main views of a conversation.
enum HomeView { note, chat }

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

  /// Note or chat; a new (empty) conversation opens on its note.
  late HomeView _view = pipeline.conversation.messages.isEmpty ? HomeView.note : HomeView.chat;

  /// Wide desktop: note and chat side by side.
  bool _split = false;
  double _width = 0;
  String? _convId;

  /// Unseen activity in the hidden view (tab badges).
  int _seenAiSeq = -1;
  bool _noteBadge = false;
  int _seenMessages = 0;

  @visibleForTesting
  HomeView get view => _view;
  bool get _splitActive => _split && _width >= kSplitBreakpoint;

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  @override
  void initState() {
    super.initState();
    _compactSub = pipeline.compactionEvents.listen(_onCompacted);
    pipeline.addListener(_onPipeline);
    _onPipeline();
    _convId = pipeline.conversation.id;
    _seenMessages = pipeline.conversation.messages.length;
    _seenAiSeq = c.notes.lastAiEdit?.seq ?? -1;
    c.notes.addListener(_onNotes);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    c.notes.removeListener(_onNotes);
    pipeline.removeListener(_onPipeline);
    _compactSub?.cancel();
    _composerFocus.dispose();
    _banners.dispose();
    super.dispose();
  }

  /// Switches between the note and the chat (Ctrl+1 / Ctrl+2).
  void setView(HomeView v) {
    if (_splitActive) {
      // Both visible: just focus the requested side.
      if (v == HomeView.note) _noteBadge = false;
      setState(() {});
      return;
    }
    setState(() {
      _view = v;
      if (v == HomeView.note) _noteBadge = false;
      if (v == HomeView.chat) _seenMessages = pipeline.conversation.messages.length;
    });
  }

  void toggleSplit() {
    if (_width < kSplitBreakpoint) return;
    setState(() {
      _split = !_split;
      _noteBadge = false;
      _seenMessages = pipeline.conversation.messages.length;
    });
  }

  void _onNotes() {
    final seq = c.notes.lastAiEdit?.seq;
    if (seq != null && seq != _seenAiSeq) {
      _seenAiSeq = seq;
      if (_view != HomeView.note && !_splitActive && mounted) setState(() => _noteBadge = true);
    }
  }

  /// Unread messages while the note is shown.
  int get _chatBadge {
    if (_view == HomeView.chat || _splitActive) return 0;
    final msgs = pipeline.conversation.messages;
    var n = 0;
    for (var i = _seenMessages; i < msgs.length; i++) {
      if (msgs[i].kind == MessageKind.assistant) n++;
    }
    return n;
  }

  void _onPipeline() {
    final conv = pipeline.conversation;
    if (conv.id != _convId) {
      _convId = conv.id;
      _seenMessages = conv.messages.length;
      _noteBadge = false;
      if (conv.messages.isEmpty && _view != HomeView.note) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _view = HomeView.note);
        });
      }
    }
    if (_view == HomeView.chat || _splitActive) _seenMessages = conv.messages.length;
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
  /// interrupt, Ctrl+K = type, Ctrl+, = settings, Ctrl+N = new chat,
  /// Ctrl+1 / Ctrl+2 = note / chat, Ctrl+\ = side by side.
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
      if (_view == HomeView.note && !_splitActive && _width >= kWideBreakpoint) setView(HomeView.chat);
      _focusComposer();
      return true;
    }
    if (ctrl && (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1)) {
      setView(HomeView.note);
      return true;
    }
    if (ctrl && (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2)) {
      setView(HomeView.chat);
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.backslash) {
      toggleSplit();
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

  OrbMode get _orbMode => orbModeFor(pipeline.phase, status: pipeline.status, compacting: c.contextManager.compressing);

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
            listenable: Listenable.merge([c, pipeline, c.contextManager, c.notes]),
            builder: (context, _) => WoiBackdrop(
              accent: orbModeColor(_orbMode),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) {
                    _width = box.maxWidth;
                    return wide ? _wide(box) : _narrow(box);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- layouts

  Widget _wide(BoxConstraints box) {
    final split = _splitActive;
    final side = split ? 300.0 : (box.maxWidth >= 1300 ? 380.0 : 340.0);
    Widget chatPanel({double maxBubble = 700}) => GlassPanel(
      key: const ValueKey('chat-panel'),
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Expanded(child: _transcriptArea(maxBubble: maxBubble, wide: true)),
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 18), child: _composer()),
        ],
      ),
    );
    final Widget main = split
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 11, child: _notePanel()),
              const SizedBox(width: 16),
              Expanded(flex: 9, child: chatPanel(maxBubble: 520)),
            ],
          )
        : AnimatedSwitcher(
            duration: WoiMotion.medium,
            switchInCurve: WoiMotion.emphasized,
            transitionBuilder: _viewTransition,
            child: _view == HomeView.note ? _notePanel() : chatPanel(),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          _header(wide: true),
          const SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedContainer(
                  duration: WoiMotion.slow,
                  curve: WoiMotion.emphasized,
                  width: side,
                  child: _sidePanel(),
                ),
                const SizedBox(width: 20),
                Expanded(child: main),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewTransition(Widget child, Animation<double> a) => FadeTransition(
    opacity: a,
    child: SlideTransition(
      position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a),
      child: child,
    ),
  );

  Widget _notePanel({bool phone = false}) {
    final editor = NoteEditor(
      key: const ValueKey('note-editor'),
      notes: c.notes,
      compact: phone,
      onOpenLink: _openLink,
    );
    if (phone) return editor;
    return GlassPanel(
      key: const ValueKey('note-panel'),
      padding: EdgeInsets.zero,
      glow: c.notes.lastAiEdit != null ? WoiColors.violet : null,
      child: editor,
    );
  }

  /// Links in the note preview: files open in Woi's viewer, web links are
  /// copied (Woi never launches other apps on its own).
  void _openLink(String target) {
    if (target.startsWith('/') || target.startsWith('~') || target.startsWith('file://')) {
      var path = target.replaceFirst('file://', '');
      if (path.startsWith('~')) path = path.replaceFirst('~', c.platform.paths.homeDir);
      c.platform.viewer.show(MediaItem(kind: MediaItem.kindForPath(path), path: path));
      return;
    }
    Clipboard.setData(ClipboardData(text: target));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Link copied: $target')));
  }

  Widget _narrow(BoxConstraints box) {
    final empty = pipeline.conversation.messages.isEmpty;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final note = _view == HomeView.note;
    final hero = empty && !keyboardUp && !note;
    final orbSize = hero ? (box.maxHeight * 0.3).clamp(150.0, 240.0) : (note ? 60.0 : 76.0);
    return Column(
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 4, 6, 0), child: _header(wide: false)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: ViewSwitch(
            view: _view,
            onChanged: setView,
            noteBadge: _noteBadge,
            chatBadge: _chatBadge,
            expand: true,
          ),
        ),
        AnimatedSize(
          duration: WoiMotion.slow,
          curve: WoiMotion.emphasized,
          child: note && keyboardUp
              ? const SizedBox(width: double.infinity)
              : (hero ? _phoneHero(orbSize) : _phoneStrip(orbSize)),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: WoiMotion.medium,
            transitionBuilder: _viewTransition,
            child: note
                ? Padding(
                    key: const ValueKey('phone-note'),
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: GlassPanel(padding: EdgeInsets.zero, radius: WoiRadii.lg, child: _notePanel(phone: true)),
                  )
                : KeyedSubtree(
                    key: const ValueKey('phone-chat'),
                    child: _transcriptArea(maxBubble: box.maxWidth * 0.86, wide: false),
                  ),
          ),
        ),
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
        child: Text(
          'WOI',
          style: display(size, weight: FontWeight.w700, color: Colors.white, spacing: 6),
        ),
      ),
    ),
  );

  Widget _statusChip({required bool compact}) => ConnectionStatusChip(
    state: linkStateFor(pipeline.status, wasConnected: _wasConnected),
    model: c.activeVoiceModel,
    backend: c.activeBackendMode,
    voice: c.settings.voice,
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
          GlassIconButton(icon: Icons.tune_rounded, tooltip: 'Settings', onPressed: _openSettings, size: kTouchTarget),
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
        const SizedBox(width: 18),
        ViewSwitch(view: _view, onChanged: setView, noteBadge: _noteBadge, chatBadge: _chatBadge, dimmed: _splitActive),
        if (_width >= kSplitBreakpoint) ...[
          const SizedBox(width: 8),
          GlassIconButton(
            key: const ValueKey('split-toggle'),
            icon: Icons.vertical_split_rounded,
            tooltip: _splitActive ? 'Single view (Ctrl+\\)' : 'Note and chat side by side (Ctrl+\\)',
            onPressed: toggleSplit,
            active: _splitActive,
          ),
        ],
        const Spacer(),
        ContextMeter(
          manager: c.contextManager,
          conversation: pipeline.conversation,
          style: ContextMeterStyle.bar,
          onCompact: c.compactNow,
        ),
        const SizedBox(width: 18),
        GlassIconButton(
          icon: Icons.add_comment_outlined,
          tooltip: 'New conversation (Ctrl+N)',
          onPressed: c.newConversation,
        ),
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
                  Text(s.voice.toUpperCase(), style: eyebrow(color: WoiColors.violet.withValues(alpha: 0.9))),
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
                    if (_view == HomeView.note && !_splitActive) _liveCaption(),
                  ],
                ),
              ),
              Center(
                child: MicModeSelector(mode: s.micMode, onChanged: c.setMicMode),
              ),
              AnimatedSize(
                duration: WoiMotion.medium,
                curve: WoiMotion.curve,
                child: s.micMode == MicMode.pushToTalk
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: PushToTalkButton(pipeline: pipeline),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 18),
              ContextMeter(manager: c.contextManager, conversation: pipeline.conversation, onCompact: c.compactNow),
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

  /// Latest exchange, so the conversation stays audible-and-visible while
  /// the note fills the main area.
  Widget _liveCaption() {
    final msgs = pipeline.conversation.messages;
    Message? last;
    for (var i = msgs.length - 1; i >= 0 && i >= msgs.length - 6; i--) {
      final m = msgs[i];
      if ((m.kind == MessageKind.assistant || m.kind == MessageKind.user) && m.text.trim().isNotEmpty) {
        last = m;
        break;
      }
    }
    if (last == null) return const SizedBox.shrink();
    final mine = last.kind == MessageKind.user;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: InkWell(
        key: const ValueKey('live-caption'),
        borderRadius: BorderRadius.circular(WoiRadii.md),
        onTap: () => setView(HomeView.chat),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          decoration: BoxDecoration(
            color: WoiColors.glass,
            borderRadius: BorderRadius.circular(WoiRadii.md),
            border: Border.all(color: (mine ? WoiColors.cyan : WoiColors.violet).withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mine ? 'YOU' : 'WOI', style: eyebrow(size: 10, color: mine ? WoiColors.cyan : WoiColors.violet)),
              const SizedBox(height: 3),
              Text(
                last.text.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: body(13, color: WoiColors.text, height: 1.4),
              ),
            ],
          ),
        ),
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
        Positioned.fill(
          child: _transcript(maxBubble: maxBubble, wide: wide),
        ),
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
              MicMode.pushToTalk =>
                wide ? 'Hold Space to talk — or try one of these.' : 'Hold the mic to talk — or try one of these.',
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
              Text(
                'Stop',
                style: body(14, weight: FontWeight.w600, color: WoiColors.red),
              ),
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

/// Note | Chat segmented control with activity badges.
class ViewSwitch extends StatelessWidget {
  const ViewSwitch({
    super.key,
    required this.view,
    required this.onChanged,
    this.noteBadge = false,
    this.chatBadge = 0,
    this.expand = false,
    this.dimmed = false,
  });
  final HomeView view;
  final ValueChanged<HomeView> onChanged;
  final bool noteBadge;
  final int chatBadge;
  final bool expand;

  /// Both views are visible (split): no selection highlight.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    Widget seg(HomeView v, IconData icon, String label, String keys, {Widget? badge}) {
      final on = !dimmed && v == view;
      final color = v == HomeView.note ? WoiColors.mint : WoiColors.cyan;
      final child = Tooltip(
        message: '$label ($keys)',
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          child: InkWell(
            key: ValueKey('view-${v.name}'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => onChanged(v),
            child: AnimatedContainer(
              duration: WoiMotion.medium,
              curve: WoiMotion.emphasized,
              height: expand ? 40 : 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: on
                    ? LinearGradient(colors: [color.withValues(alpha: 0.24), WoiColors.violet.withValues(alpha: 0.16)])
                    : null,
                border: Border.all(color: on ? color.withValues(alpha: 0.55) : Colors.transparent),
                boxShadow: on
                    ? [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 16, spreadRadius: -4)]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: on ? color : WoiColors.textDim),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: body(13, weight: FontWeight.w600, color: on ? WoiColors.text : WoiColors.textDim),
                  ),
                  ?badge,
                ],
              ),
            ),
          ),
        ),
      );
      return expand ? Expanded(child: child) : child;
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: WoiColors.bg0.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          seg(
            HomeView.note,
            Icons.sticky_note_2_outlined,
            'Note',
            'Ctrl+1',
            badge: noteBadge
                ? Container(
                    key: const ValueKey('note-badge'),
                    margin: const EdgeInsets.only(left: 7),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: WoiColors.violet,
                      boxShadow: [BoxShadow(color: WoiColors.violet.withValues(alpha: 0.8), blurRadius: 8)],
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 2),
          seg(
            HomeView.chat,
            Icons.forum_outlined,
            'Chat',
            'Ctrl+2',
            badge: chatBadge > 0
                ? Container(
                    key: const ValueKey('chat-badge'),
                    margin: const EdgeInsets.only(left: 7),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: WoiColors.cyan, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      '$chatBadge',
                      style: body(10.5, weight: FontWeight.w700, color: WoiColors.bg0),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
