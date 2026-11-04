import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_actions.dart';
import '../../core/app_controller.dart';
import '../../core/context/context_manager.dart';
import '../../core/models/message.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../../platform/media_viewer.dart';
import '../notes/note_editor.dart';
import '../notes/note_tabs.dart';
import '../terminal/terminal_panel.dart';
import '../theme.dart';
import '../widgets/banner.dart';
import '../widgets/context_meter.dart';
import '../widgets/edit_review_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/message_tile.dart';
import '../widgets/input_bar.dart';
import '../widgets/screen_share_button.dart';
import '../widgets/tab_strip.dart';
import 'history_drawer.dart';
import 'settings_screen.dart';

export '../../core/app_actions.dart' show HomeView;

const kWideBreakpoint = 1000.0;

/// Below this width the phone layout is used (48dp targets, compact bars).
const kPhoneBreakpoint = 640.0;

/// Width from which the note and the chat can be shown side by side.
const kSplitBreakpoint = 1280.0;

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

  SessionStatus? _lastStatus;

  /// The selected tab: owned by [AppActions] (voice can switch it).
  HomeView get _view => c.actions.view.value;
  set _view(HomeView v) => c.actions.view.value = v;

  /// Wide desktop: note and chat side by side.
  bool get _split => c.actions.split.value;
  double _width = 0;
  String? _convId;

  /// Unseen activity in the hidden view (tab badges).
  int _seenAiSeq = -1;
  bool _noteBadge = false;
  int _seenMessages = 0;

  @visibleForTesting
  HomeView get view => _view;
  bool get _splitActive => _split && _width >= kSplitBreakpoint && AppActions.isNoteOrChat(_view);

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  @override
  void initState() {
    super.initState();
    // A new (empty) conversation opens on its note.
    _view = pipeline.conversation.messages.isEmpty ? HomeView.note : HomeView.chat;
    c.actions.view.addListener(_onViewChanged);
    c.actions.split.addListener(_onViewChanged);
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
    c.actions.view.removeListener(_onViewChanged);
    c.actions.split.removeListener(_onViewChanged);
    HardwareKeyboard.instance.removeHandler(_onKey);
    c.notes.removeListener(_onNotes);
    pipeline.removeListener(_onPipeline);
    _compactSub?.cancel();
    _composerFocus.dispose();
    _banners.dispose();
    super.dispose();
  }

  /// Selects a top-level tab (Ctrl+1..4). In the side-by-side layout Note
  /// and Chat stay side by side.
  void setView(HomeView v) => c.actions.showView(v);

  void toggleSplit() {
    if (_width < kSplitBreakpoint) return;
    c.actions.toggleSplit();
  }

  /// The view changed (buttons, shortcuts or voice): clear the badges of
  /// whatever is visible now.
  void _onViewChanged() {
    if (!mounted) return;
    setState(() {
      if (_view == HomeView.note || _splitActive) _noteBadge = false;
      if (_view == HomeView.chat || _splitActive) _seenMessages = pipeline.conversation.messages.length;
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
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
        terminalHasFocus();
  }

  /// Global shortcuts. Space = push-to-talk (when not typing), Esc =
  /// interrupt (or leave Settings), Ctrl+K = type, Ctrl+N = new note,
  /// Ctrl+1..4 = Note / Chat / Terminal / Settings tab (Ctrl+, = Settings),
  /// Ctrl+\ = side by side.
  bool _onKey(KeyEvent e) {
    if (!mounted) return false;
    // A dialog or popup is on top: it handles its own keys.
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    // Ctrl alone: Ctrl+Shift / Ctrl+Alt combinations belong to the focused
    // widget (the editor's Format shortcuts, e.g. Ctrl+Alt+1 = Heading 1).
    final anyCtrl = kb.isControlPressed || kb.isMetaPressed;
    final ctrl = anyCtrl && !kb.isShiftPressed && !kb.isAltPressed;
    if (key == LogicalKeyboardKey.space && !_typing && !anyCtrl && c.settings.micMode == MicMode.pushToTalk) {
      if (e is KeyDownEvent) pipeline.pttDown();
      if (e is KeyUpEvent) pipeline.pttUp();
      return true;
    }
    if (e is! KeyDownEvent) return false;
    final inTerminal = terminalHasFocus();
    if (ctrl && key == LogicalKeyboardKey.keyK && !inTerminal) {
      if (_view == HomeView.terminal) setView(HomeView.chat);
      _focusComposer();
      return true;
    }
    if (ctrl) {
      final tab = _digitTabs[key];
      if (tab != null) {
        setView(tab);
        return true;
      }
    }
    if (ctrl && key == LogicalKeyboardKey.backslash && !inTerminal) {
      toggleSplit();
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.comma) {
      setView(HomeView.settings);
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyN && !inTerminal) {
      c.actions.newNote();
      return true;
    }
    // A pending edit preview: Enter applies (unless typing something), Esc rejects.
    if (c.review.hasPending && !anyCtrl) {
      if (key == LogicalKeyboardKey.escape && !inTerminal) return c.review.reject();
      if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && _enterApplies()) {
        return c.review.apply();
      }
    }
    if (key == LogicalKeyboardKey.escape && !_typing && _view == HomeView.settings) {
      c.actions.closeSettings();
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

  static final _digitTabs = <LogicalKeyboardKey, HomeView>{
    LogicalKeyboardKey.digit1: HomeView.note,
    LogicalKeyboardKey.numpad1: HomeView.note,
    LogicalKeyboardKey.digit2: HomeView.chat,
    LogicalKeyboardKey.numpad2: HomeView.chat,
    LogicalKeyboardKey.digit3: HomeView.terminal,
    LogicalKeyboardKey.numpad3: HomeView.terminal,
    LogicalKeyboardKey.digit4: HomeView.settings,
    LogicalKeyboardKey.numpad4: HomeView.settings,
  };

  /// Enter decides an edit preview unless it would type into something:
  /// only when no text field has focus, or the composer is empty.
  bool _enterApplies() {
    if (!_typing) return true;
    if (!_composerFocus.hasFocus) return false;
    final ctx = FocusManager.instance.primaryFocus?.context;
    final w = ctx?.widget;
    final field = w is EditableText ? w : ctx?.findAncestorWidgetOfExactType<EditableText>();
    return field != null && field.controller.text.trim().isEmpty;
  }

  void _focusComposer() => _composerFocus.requestFocus();

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

  void _openHistory() => _scaffoldKey.currentState?.openEndDrawer();

  bool get _phone => _width < kPhoneBreakpoint;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      resizeToAvoidBottomInset: true,
      endDrawer: HistoryDrawer(controller: c),
      // Only app-level changes (settings, conversation switch) rebuild the
      // screen; the transcript, header and input bar listen to the pipeline
      // themselves, the note editor to the note.
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              _width = box.maxWidth;
              c.actions.splitAvailable = _width >= kSplitBreakpoint;
              final phone = _phone;
              final pad = phone ? 8.0 : 16.0;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(phone ? 0 : pad - 8, phone ? 0 : 4, phone ? 0 : pad - 8, phone ? 0 : 6),
                    child: ListenableBuilder(listenable: pipeline, builder: (context, _) => _header()),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: pad),
                      child: _main(box),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: _splitActive ? double.infinity : 980),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            EditReviewCard(review: c.review, maxDiffHeight: phone ? 160 : 220),
                            InputBar(controller: c, focusNode: _composerFocus, phone: phone),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- layouts

  Widget _main(BoxConstraints box) {
    if (_splitActive) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 11, child: _notePanel()),
          const SizedBox(width: 16),
          Expanded(flex: 9, child: _chatPanel(maxBubble: 560)),
        ],
      );
    }
    return switch (_view) {
      HomeView.note => _notePanel(),
      HomeView.chat => _chatPanel(maxBubble: _phone ? box.maxWidth * 0.86 : 720),
      HomeView.settings => SettingsView(key: const ValueKey('settings-view'), controller: c),
      HomeView.terminal => GlassPanel(
        key: const ValueKey('terminal-view'),
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(WoiRadii.lg),
          child: TerminalPanel(hub: c.terminals, actions: c.actions, fontSize: _phone ? 12 : 13.5),
        ),
      ),
    };
  }

  Widget _chatPanel({required double maxBubble}) => GlassPanel(
    key: const ValueKey('chat-panel'),
    padding: EdgeInsets.zero,
    // Hard-edge clip: an anti-aliased rounded clip over the scrolling list
    // is redrawn with coverage every frame (expensive on software GL).
    child: ClipRRect(
      borderRadius: BorderRadius.circular(WoiRadii.lg),
      clipBehavior: Clip.hardEdge,
      child: _transcriptArea(maxBubble: maxBubble, wide: !_phone),
    ),
  );

  Widget _notePanel() {
    final phone = _phone;
    return GlassPanel(
      key: const ValueKey('note-panel'),
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WoiRadii.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(phone ? 4 : 8, phone ? 0 : 4, phone ? 4 : 8, 0),
              child: NoteTabsBar(controller: c, compact: phone),
            ),
            Divider(height: 1, color: WoiColors.stroke),
            Expanded(
              child: NoteEditor(
                key: const ValueKey('note-editor'),
                notes: c.notes,
                compact: phone,
                onOpenLink: _openLink,
                onRun: _run,
                onCopy: c.actions.copyNote,
                copied: c.actions.copied,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Editor "Run": the line or selection becomes a user turn (it shows up
  /// in the chat history like a typed message).
  void _run(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (pipeline.status != SessionStatus.connected) {
      messenger?.showSnackBar(const SnackBar(content: Text('Not connected: Run needs a live session.')));
      return;
    }
    pipeline.sendText(text);
    if (_splitActive) return;
    final short = text.length > 60 ? '${text.substring(0, 59)}…' : text;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Sent to Woi: $short', maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(label: 'Open chat', onPressed: () => setView(HomeView.chat)),
      ),
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

  // ------------------------------------------------------------------ parts

  /// The top-level tab strip, starting at the left edge, plus the few
  /// window-level actions on the right (status lives in the input bar).
  Widget _header() {
    final phone = _phone;
    final t = phone ? kTouchTarget : 36.0;
    return SizedBox(
      height: phone ? kTouchTarget : 44,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: HomeTabs(
                  view: _view,
                  onChanged: setView,
                  split: _splitActive,
                  noteBadge: _noteBadge,
                  chatBadge: _chatBadge,
                  compact: phone,
                  height: phone ? kTouchTarget : 44,
                ),
              ),
            ),
          ),
          if (_width >= kSplitBreakpoint)
            GlassIconButton(
              key: const ValueKey('split-toggle'),
              icon: Icons.vertical_split_outlined,
              tooltip: _splitActive ? 'Single view (Ctrl+\\)' : 'Note and chat side by side (Ctrl+\\)',
              onPressed: toggleSplit,
              active: _split && AppActions.isNoteOrChat(_view),
              size: t,
            ),
          if (Platform.isAndroid) ScreenShareButton(size: t),
          GlassIconButton(
            key: const ValueKey('open-history'),
            icon: Icons.history,
            tooltip: 'All conversations',
            onPressed: _openHistory,
            size: t,
          ),
        ],
      ),
    );
  }

  Widget _transcriptArea({required double maxBubble, required bool wide}) {
    return Stack(
      children: [
        Positioned.fill(
          child: ListenableBuilder(
            listenable: pipeline,
            builder: (context, _) => _transcript(maxBubble: maxBubble, wide: wide),
          ),
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
    final connected = pipeline.status == SessionStatus.connected;
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
            enabled: connected,
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
    // One SelectionArea for the transcript: message text is plain Text.
    return SelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.fromLTRB(wide ? 22 : 10, 16, wide ? 22 : 10, 8),
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
      ),
    );
  }
}
