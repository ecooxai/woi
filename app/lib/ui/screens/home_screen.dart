import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_actions.dart';
import '../../core/app_controller.dart';
import '../../core/context/context_manager.dart';
import '../../core/clipboard/clipboard_history.dart';
import '../../core/models/message.dart';
import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../../platform/media_viewer.dart';
import '../notes/note_editor.dart';
import '../clipboard/clipboard_panel.dart';
import '../notes/note_tabs.dart';
import '../terminal/terminal_panel.dart';
import '../theme.dart';
import '../widgets/banner.dart';
import '../widgets/chat_transcript.dart';
import '../widgets/chat_draft.dart';
import '../widgets/clipboard_selection_area.dart';
import '../widgets/context_meter.dart';
import '../widgets/edit_review_card.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/message_tile.dart';
import '../widgets/input_bar.dart';
import '../widgets/contextual_find.dart';
import '../widgets/tab_strip.dart';
import '../widgets/throttled_builder.dart';
import 'history_drawer.dart';
import 'settings_screen.dart';

export '../../core/app_actions.dart' show HomeView;

/// From this width the chat (history and input) is always docked on the
/// right and the left pane shows the selected tab (Note, Terminal,
/// Settings).
const kWideBreakpoint = 1000.0;

/// The docked chat pane never gets narrower than this.
const kChatPaneMinWidth = 360.0;

/// A docked chat pane narrower than this gets the compact input bar.
const kCompactComposerWidth = 560.0;

/// Below this width the phone layout is used (48dp targets, compact bars).
const kPhoneBreakpoint = 640.0;

/// Note panel height below which the note tabs are left out.
const kNoteTabsMinHeight = 220.0;

/// Screens used by tool markers. Pointer captures may be appended after their
/// tool row, so an explicit call ID takes precedence over chronological fallback.
List<ImageAttachment?> toolScreenshotsForMessages(List<Message> messages) {
  bool isScreen(Message message) {
    if (message.image == null || message.image!.generated) return false;
    const contextKinds = {'camera', 'media', 'generated', 'image_generation'};
    return !contextKinds.contains(message.meta['type']) && !contextKinds.contains(message.meta['imageKind']);
  }

  final byCall = <String, ImageAttachment?>{};
  for (final message in messages) {
    final callId = message.meta['pointerCallId'];
    if (callId is String && callId.isNotEmpty) {
      // A linked capture still being saved must not show an unrelated old screen.
      byCall[callId] = isScreen(message) ? message.image : null;
    }
  }
  final screenshots = List<ImageAttachment?>.filled(messages.length, null);
  ImageAttachment? previousScreen;
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final tool = message.tool;
    if (tool != null) {
      screenshots[i] = byCall.containsKey(tool.callId)
          ? byCall[tool.callId]
          : tool.name == 'control_pointer'
          ? null
          : previousScreen;
    }
    // Unmarked legacy screenshots remain usable; generated artwork and
    // camera/viewer context images can never become click-coordinate sources.
    if (isScreen(message)) previousScreen = message.image;
  }
  return screenshots;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _tabsKey = GlobalKey<WoiTabsState>();

  @visibleForTesting
  HomeView get view => _tabsKey.currentState!.view;

  @visibleForTesting
  bool get wide => _tabsKey.currentState!.wide;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      resizeToAvoidBottomInset: true,
      endDrawer: HistoryDrawer(controller: widget.controller),
      body: SafeArea(
        child: WoiTabs(key: _tabsKey, controller: widget.controller),
      ),
    );
  }
}

/// The main UI: the tab strip (Note, Chat, Terminal, Settings), the
/// selected tab and the composer; from [kWideBreakpoint] the chat is docked
/// on the right. Hosted by [HomeScreen] and, [embedded], by the Android
/// assist panel (always the narrow layout there). The history button opens
/// the end drawer of the enclosing [Scaffold].
class WoiTabs extends StatefulWidget {
  const WoiTabs({
    super.key,
    required this.controller,
    this.embedded = false,
    this.initialView,
    this.onViewChanged,
    this.headerTrailing = const [],
    this.menuItems = const [],
    this.wrapHeader,
  });

  final AppController controller;

  /// Hosted in the assist panel: narrow layout only, its own selected tab
  /// (starting at [initialView]; voice still switches it), no screen-share
  /// button, and the app-wide split state is left alone.
  final bool embedded;

  /// Embedded: the tab shown first (default Chat).
  final HomeView? initialView;

  /// Embedded: the selected tab changed (to remember it).
  final ValueChanged<HomeView>? onViewChanged;

  /// Extra actions at the right end of the tab strip row (narrow layout).
  final List<Widget> headerTrailing;

  /// Narrow layout: when non-empty, the history button becomes a "more"
  /// menu holding All conversations followed by these entries.
  final List<WoiMenuItem> menuItems;

  /// Wraps the tab strip row (the assist panel makes it a drag handle).
  final Widget Function(Widget header)? wrapHeader;

  @override
  State<WoiTabs> createState() => WoiTabsState();
}

class WoiTabsState extends State<WoiTabs> {
  final _composerFocus = FocusNode(debugLabel: 'composer');
  final _narrowScroll = ScrollController();
  ({Size size, double scale, bool scrolling, HomeView view})? _composerViewport;
  bool _composerRevealQueued = false;
  final _chatDraft = ChatDraftController();
  HomeView _pasteTarget = HomeView.note;
  final _banners = BannerController();
  final _find = {for (final view in HomeView.values) view: ContextualFindController()};
  final _findButtonKey = GlobalKey<ContextualFindButtonState>();
  late HomeView _findView;

  ContextualFindController get _activeFind => _find[_findView]!;
  String get _findLabel => switch (_findView) {
    HomeView.note => 'note',
    HomeView.chat => 'messages',
    HomeView.terminal => 'terminal',
    HomeView.settings => 'settings',
    HomeView.clipboard => 'clipboard history',
  };
  StreamSubscription<ContextCompacted>? _compactSub;

  SessionStatus? _lastStatus;

  /// The selected tab: owned by [AppActions] (voice can switch it); the
  /// embedded panel keeps its own and follows voice changes.
  late final ValueNotifier<HomeView> _viewN = widget.embedded
      ? ValueNotifier(widget.initialView ?? HomeView.chat)
      : c.actions.view;
  HomeView get _view => _viewN.value;
  set _view(HomeView v) => _viewN.value = v;

  double _width = 0;

  /// Kept across the wide / narrow layouts (reparented, not rebuilt):
  /// editor text and selection, transcript scroll, composer text.
  final _noteKey = GlobalKey(debugLabel: 'note-panel');
  final _chatKey = GlobalKey(debugLabel: 'chat-panel');
  final _composerKey = GlobalKey(debugLabel: 'composer');
  final _settingsKey = GlobalKey(debugLabel: 'settings-view');
  final _terminalKey = GlobalKey(debugLabel: 'terminal-view');
  final _clipboardKey = GlobalKey(debugLabel: 'clipboard-view');
  final _selectedTabKey = GlobalKey(debugLabel: 'selected-home-tab');
  ({double width, double labelSize, bool compact, bool wide})? _tabViewport;
  bool _tabRevealQueued = false;

  /// The last non-chat tab: what the left pane shows in the wide layout.
  HomeView _leftView = HomeView.note;

  /// Chat pane share while the divider is dragged (persisted on release).
  double? _dragFraction;
  String? _convId;

  /// Unseen activity in the hidden view (tab badges).
  int _seenAiSeq = -1;
  bool _noteBadge = false;
  int _seenMessages = 0;

  @visibleForTesting
  HomeView get view => _view;

  /// Wide window: chat docked on the right, always visible.
  bool get _wide => !widget.embedded && _width >= kWideBreakpoint;
  bool get _chatVisible => _wide || _view == HomeView.chat;
  bool get _noteVisible => (_wide ? _leftView : _view) == HomeView.note;

  @visibleForTesting
  bool get wide => _wide;

  AppController get c => widget.controller;
  TurnPipeline get pipeline => c.pipeline;

  @override
  void initState() {
    super.initState();
    if (widget.embedded) {
      c.actions.view.addListener(_followActions);
    } else {
      // A new (empty) conversation opens on its note.
      _view = pipeline.conversation.messages.isEmpty ? HomeView.note : HomeView.chat;
    }
    _findView = _view;
    _pasteTarget = _view == HomeView.chat ? HomeView.chat : HomeView.note;
    _viewN.addListener(_onViewChanged);
    _compactSub = pipeline.compactionEvents.listen(_onCompacted);
    pipeline.addListener(_onPipeline);
    _onPipeline();
    _convId = pipeline.conversation.id;
    _seenMessages = pipeline.conversation.messages.length;
    _seenAiSeq = c.notes.lastAiEdit?.seq ?? -1;
    c.notes.addListener(_onNotes);
    HardwareKeyboard.instance.addHandler(_onKey);
    _composerFocus.addListener(_onComposerFocus);
  }

  @override
  void dispose() {
    _viewN.removeListener(_onViewChanged);
    if (widget.embedded) {
      c.actions.view.removeListener(_followActions);
      _viewN.dispose();
    }
    HardwareKeyboard.instance.removeHandler(_onKey);
    c.notes.removeListener(_onNotes);
    pipeline.removeListener(_onPipeline);
    _compactSub?.cancel();
    _composerFocus.removeListener(_onComposerFocus);
    _composerFocus.dispose();
    _narrowScroll.dispose();
    _chatDraft.dispose();
    _banners.dispose();
    for (final find in _find.values) {
      find.dispose();
    }
    super.dispose();
  }

  /// Selects a top-level tab (Ctrl+1..4). In the wide layout the chat is
  /// always shown, so "Chat" just focuses the composer.
  void setView(HomeView v) {
    if (v == HomeView.note || v == HomeView.chat || v == HomeView.terminal) _pasteTarget = v;
    _setFindView(v);
    widget.embedded ? _view = v : c.actions.showView(v);
  }

  void _setFindView(HomeView view) {
    if (!mounted || _findView == view) return;
    _findButtonKey.currentState?.close();
    setState(() => _findView = view);
  }

  /// In a split window, the pane last used is the contextual find target.
  /// The shared narrow composer leaves the selected tab as the target.
  Widget _findPane(HomeView view, Widget child) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused && (view == HomeView.note || view == HomeView.chat || view == HomeView.terminal)) _pasteTarget = view;
      if (_wide && focused) _setFindView(view);
    },
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (view == HomeView.note || view == HomeView.chat || view == HomeView.terminal) _pasteTarget = view;
        if (_wide) _setFindView(view);
      },
      child: child,
    ),
  );

  /// Embedded: voice (or the app) switched the tab.
  void _followActions() => _view = c.actions.view.value;

  /// The view changed (buttons, shortcuts or voice): clear the badges of
  /// whatever is visible now.
  void _onViewChanged() {
    if (!mounted) return;
    _setFindView(_view);
    widget.onViewChanged?.call(_view);
    setState(() {
      if (_view != HomeView.chat) {
        _leftView = _view;
      } else if (_leftView == HomeView.settings) {
        // Leaving Settings for the chat (Esc, voice): the note comes back.
        _leftView = HomeView.note;
      }
      if (_noteVisible) _noteBadge = false;
      if (_chatVisible) _seenMessages = pipeline.conversation.messages.length;
    });
    if (_wide && _view == HomeView.chat) _focusComposer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _narrowScroll.hasClients) _narrowScroll.jumpTo(0);
      if (_view == HomeView.chat) _revealFocusedComposer();
    });
    _queueSelectedTabReveal();
  }

  /// Resize and accessibility text changes can clip a tab without changing the
  /// selection. Track the actual tab viewport, including space taken by header
  /// actions; unrelated rebuilds must preserve deliberate horizontal scrolling.
  void _trackTabViewport(BuildContext context, double width) {
    final next = (width: width, labelSize: MediaQuery.textScalerOf(context).scale(13.5), compact: _phone, wide: _wide);
    if (_tabViewport == next) return;
    _tabViewport = next;
    _queueSelectedTabReveal();
  }

  void _queueSelectedTabReveal() {
    if (_tabRevealQueued) return;
    _tabRevealQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tabRevealQueued = false;
      if (!mounted) return;
      final tab = _selectedTabKey.currentContext;
      if (tab != null) unawaited(Scrollable.ensureVisible(tab, alignment: .5));
    });
  }

  void _onNotes() {
    final seq = c.notes.lastAiEdit?.seq;
    if (seq != null && seq != _seenAiSeq) {
      _seenAiSeq = seq;
      if (!_noteVisible && mounted) setState(() => _noteBadge = true);
    }
  }

  /// Unread messages while the note is shown.
  int get _chatBadge {
    if (_chatVisible) return 0;
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
      _chatDraft.retirePendingPastes();
      for (final find in _find.values) {
        find.clear();
      }
      _seenMessages = conv.messages.length;
      _noteBadge = false;
      if (conv.messages.isEmpty && _view != HomeView.note && !widget.embedded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _view = HomeView.note);
        });
      }
    }
    if (_chatVisible) _seenMessages = conv.messages.length;
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
          details: pipeline.statusDetail ?? 'The realtime connection could not be established.',
          actionLabel: 'Retry',
          onAction: pipeline.reconnect,
          autoDismiss: null,
        ),
      );
    }
  }

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
        terminalHasFocus();
  }

  /// Global shortcuts. Space = push-to-talk (when not typing), Esc =
  /// interrupt (or leave Settings), Ctrl+K = type, Ctrl+N = new note,
  /// Ctrl+1..4 = Note / Chat / Terminal / Settings tab (Ctrl+, = Settings).
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
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      _findButtonKey.currentState?.open();
      return true;
    }
    if (_findButtonKey.currentState?.isOpen ?? false) {
      if (key == LogicalKeyboardKey.escape) {
        _findButtonKey.currentState?.close();
        return true;
      }
      if (key == LogicalKeyboardKey.f3 || (anyCtrl && !kb.isAltPressed && key == LogicalKeyboardKey.keyG)) {
        _activeFind.move(kb.isShiftPressed ? -1 : 1);
        return true;
      }
    }
    final inTerminal = terminalHasFocus();
    if (ctrl && key == LogicalKeyboardKey.keyK && !inTerminal) {
      if (_view == HomeView.terminal && !_wide) setView(HomeView.chat);
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
    if (ctrl && key == LogicalKeyboardKey.comma) {
      setView(HomeView.settings);
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyN && !inTerminal) {
      // The new note is shown: Ctrl+N from Settings leaves it.
      if (_view == HomeView.settings) setView(HomeView.note);
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
      widget.embedded ? setView(HomeView.chat) : c.actions.closeSettings();
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
    LogicalKeyboardKey.digit5: HomeView.clipboard,
    LogicalKeyboardKey.numpad5: HomeView.clipboard,
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

  void _focusComposer() {
    _composerFocus.requestFocus();
    // Ctrl+K also reveals a field which is already focused but was deliberately
    // scrolled away while reading the pane.
    _queueComposerReveal();
  }

  void _onComposerFocus() {
    if (_composerFocus.hasFocus) _queueComposerReveal();
  }

  void _trackComposerViewport(BoxConstraints box, double scale, bool scrolling) {
    final next = (size: Size(box.maxWidth, box.maxHeight), scale: scale, scrolling: scrolling, view: _view);
    if (_composerViewport == next) return;
    final previousView = _composerViewport?.view;
    _composerViewport = next;
    // A non-chat tab intentionally reveals its pane, including when that tab
    // itself introduces the short-layout scroll view after final file removal.
    if (previousView != _view && _view != HomeView.chat) return;
    _queueComposerReveal();
  }

  void _queueComposerReveal() {
    if (_composerRevealQueued) return;
    _composerRevealQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerRevealQueued = false;
      _revealFocusedComposer();
    });
    // An explicit shortcut can target an already-focused field without any
    // widget state change to request the frame for this callback.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Reveal only after focus or viewport transitions. Listening to scrolling,
  /// text changes or pipeline rebuilds would pull the user away from a pane
  /// they deliberately scrolled to while keeping their draft focused.
  void _revealFocusedComposer() {
    if (!mounted || !_composerFocus.hasFocus || !_narrowScroll.hasClients) return;
    final focusContext = _composerFocus.context;
    if (focusContext == null) return;
    RenderBox? field;
    focusContext.visitAncestorElements((element) {
      if (element.widget is! TextField) return true;
      final render = element.findRenderObject();
      if (render is RenderBox) field = render;
      return false;
    });
    final position = _narrowScroll.position;
    final viewport = position.context.storageContext.findRenderObject();
    if (field == null || !field!.attached || viewport is! RenderBox || !viewport.attached) return;
    Rect relativeRect(RenderBox box) => box.localToGlobal(Offset.zero, ancestor: viewport) & box.size;
    var target = relativeRect(field!);
    if (target.top >= 0 && target.bottom <= viewport.size.height) return;
    final composer = _composerKey.currentContext?.findRenderObject();
    if (composer is RenderBox && composer.size.height <= viewport.size.height) {
      // Keep the attachment controls and Send/Stop in view too when they fit.
      target = relativeRect(composer);
    } else if (target.height > viewport.size.height) {
      final editable = focusContext.findAncestorStateOfType<EditableTextState>();
      final selection = _chatDraft.text.selection;
      if (editable != null && selection.isValid) {
        final render = editable.renderEditable;
        target = render
            .getLocalRectForCaret(selection.extent)
            .shift(render.localToGlobal(Offset.zero, ancestor: viewport));
      }
    }
    final delta = target.top < 0
        ? target.top
        : target.bottom > viewport.size.height
        ? target.bottom - viewport.size.height
        : 0.0;
    if (delta.abs() > 0.5) {
      position.jumpTo((position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent));
    }
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

  void _openHistory() => Scaffold.maybeOf(context)?.openEndDrawer();

  bool get _phone => _width < kPhoneBreakpoint;

  /// The chat pane's share of the width (wide layout).
  double _chatFraction(double width) {
    final f = (_dragFraction ?? c.settings.chatPaneFraction).clamp(kChatPaneMinFraction, kChatPaneMaxFraction);
    // Never so narrow that the input bar's status row gets cramped.
    return width <= 0 ? f : f.clamp(math.min(kChatPaneMinWidth / width, kChatPaneMaxFraction), kChatPaneMaxFraction);
  }

  void _dragDivider(double dx) {
    if (_width <= 0) return;
    setState(() {
      _dragFraction = (_chatFraction(_width) - dx / _width).clamp(kChatPaneMinFraction, kChatPaneMaxFraction);
    });
  }

  void _endDrag() {
    final f = _dragFraction;
    if (f == null) return;
    unawaited(
      c.updateSettings(c.settings.copyWith(chatPaneFraction: f)).whenComplete(() {
        if (mounted) setState(() => _dragFraction = null);
      }),
    );
  }

  void _resetDivider() {
    setState(() => _dragFraction = kDefaultChatPaneFraction);
    _endDrag();
  }

  @override
  Widget build(BuildContext context) {
    // Only app-level changes (settings, conversation switch) rebuild the
    // screen; the transcript, header and input bar listen to the pipeline
    // themselves, the note editor to the note.
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          _width = box.maxWidth;
          // The chat is always beside the left pane: "split" is implied.
          if (!widget.embedded) c.actions.splitAvailable = _wide;
          return ColoredBox(color: WoiColors.bg1, child: _wide ? _wideLayout(box) : _narrowLayout(box));
        },
      ),
    );
  }

  // ---------------------------------------------------------------- layouts

  /// Tabs on top, the selected tab below, the composer at the bottom.
  Widget _narrowLayout(BoxConstraints box) {
    final phone = _phone;
    final pad = phone ? 8.0 : 12.0;
    final textScale = math.max(1.0, MediaQuery.textScalerOf(context).scale(14) / 14);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Only the unread badge follows the pipeline.
        SelectorBuilder<int>(
          listenable: pipeline,
          selector: () => _chatBadge,
          builder: (context, _) => widget.wrapHeader?.call(_header()) ?? _header(),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([_chatDraft, _activeFind]),
            builder: (context, _) {
              final pane = ListenableBuilder(
                listenable: _activeFind,
                child: switch (_view) {
                  HomeView.note => _notePanel(),
                  HomeView.chat => _chatPanel(maxBubble: phone ? box.maxWidth * 0.86 : 720),
                  HomeView.settings => _settingsPanel(),
                  HomeView.terminal => _terminalPanel(),
                  HomeView.clipboard => _clipboardPanel(),
                },
                builder: (context, child) => Padding(
                  // Keep the reveal viewport below the floating search input.
                  padding: EdgeInsets.only(top: _activeFind.query.trim().isEmpty ? 0 : 112 * textScale),
                  child: child,
                ),
              );
              final composer = Padding(
                padding: EdgeInsets.fromLTRB(pad, phone ? 4 : 8, pad, pad),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: _composer(phone: phone),
                  ),
                ),
              );
              // A keyboard in a small assistant/freeform window can leave less
              // room than a populated composer alone needs. Keep tabs fixed and
              // let the complete pane and composer scroll, retaining their
              // GlobalKeys, full touch targets, previews and editing state.
              final shortDraft = _chatDraft.hasAttachments && box.maxHeight < 560 * textScale;
              final shortClipboard = _view == HomeView.clipboard && box.maxHeight < 420 * textScale;
              _trackComposerViewport(box, textScale, shortDraft || shortClipboard);
              if (shortDraft || shortClipboard) {
                return Scrollbar(
                  key: const ValueKey('narrow-content-scrollbar'),
                  controller: _narrowScroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 6,
                  child: SingleChildScrollView(
                    key: const PageStorageKey('narrow-content-scroll'),
                    controller: _narrowScroll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: (220 + (_activeFind.query.trim().isEmpty ? 0 : 112)) * textScale, child: pane),
                        composer,
                      ],
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: pane),
                  composer,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Left: the selected tab (Note, Terminal, Settings). Right: the chat
  /// history and the composer, whatever tab is selected. A draggable
  /// divider between them (double-click resets it).
  Widget _wideLayout(BoxConstraints box) {
    _composerViewport = null;
    final chatW = (box.maxWidth * _chatFraction(box.maxWidth)).roundToDouble();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const Divider(height: 1),
              Expanded(
                child: switch (_leftView) {
                  HomeView.settings => _settingsPanel(),
                  HomeView.terminal => _terminalPanel(),
                  HomeView.clipboard => _clipboardPanel(),
                  _ => _notePanel(),
                },
              ),
            ],
          ),
        ),
        PaneDivider(
          key: const ValueKey('pane-divider'),
          onDrag: _dragDivider,
          onDragEnd: _endDrag,
          onReset: _resetDivider,
        ),
        SizedBox(
          key: const ValueKey('chat-pane'),
          width: chatW,
          child: ColoredBox(
            color: WoiColors.bg1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _chatHeader(),
                const Divider(height: 1),
                Expanded(child: _chatPanel(maxBubble: math.min(560, chatW - 48))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: _composer(phone: chatW < kCompactComposerWidth),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Edit preview and input bar; one instance moved between the layouts.
  Widget _composer({required bool phone}) => KeyedSubtree(
    key: _composerKey,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EditReviewCard(review: c.review, maxDiffHeight: phone ? 160 : 220),
        _findPane(
          HomeView.chat,
          InputBar(
            controller: c,
            draft: _chatDraft,
            focusNode: _composerFocus,
            phone: phone,
            allowScreenShare: !widget.embedded,
          ),
        ),
      ],
    ),
  );

  Widget _clipboardPanel() {
    // Focus may return to the composer as the previous pane or popup closes.
    // The callback must keep the destination advertised by this panel.
    final pasteTarget = _pasteTarget;
    return KeyedSubtree(
      key: _clipboardKey,
      child: _findPane(
        HomeView.clipboard,
        ClipboardPanel(
          key: const ValueKey('clipboard-view'),
          history: c.clipboardHistory,
          find: _find[HomeView.clipboard],
          pasteLabel: switch (pasteTarget) {
            HomeView.chat => 'Paste into chat',
            HomeView.terminal => 'Paste into terminal',
            _ => 'Paste into note',
          },
          onPaste: (entry) => _pasteClipboardEntry(entry, pasteTarget),
          onSendToAi: _stageClipboardForAi,
        ),
      ),
    );
  }

  Future<void> _pasteClipboardEntry(ClipboardHistoryEntry entry, HomeView pasteTarget) async {
    switch (pasteTarget) {
      case HomeView.chat:
        _chatDraft.stageClipboard(entry.content);
        setView(HomeView.chat);
        _focusComposer();
      case HomeView.terminal:
        if (entry.content.image != null) {
          throw StateError('Images cannot be pasted into the terminal. Use Copy or Send to AI.');
        }
        c.terminals.ensureTab();
        c.terminals.active?.terminal.paste(entry.content.text ?? '');
        setView(HomeView.terminal);
      default:
        await c.pasteClipboardContentToNote(entry.content);
        if (mounted) setView(HomeView.note);
    }
  }

  Future<void> _stageClipboardForAi(ClipboardHistoryEntry entry) async {
    _chatDraft.stageClipboard(entry.content, append: true);
    setView(HomeView.chat);
    _focusComposer();
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text('Added to your message. Review it and press Send when ready.')));
  }

  Widget _settingsPanel() => KeyedSubtree(
    key: _settingsKey,
    child: _findPane(
      HomeView.settings,
      SettingsView(key: const ValueKey('settings-view'), controller: c, find: _find[HomeView.settings]),
    ),
  );

  Widget _terminalPanel() => KeyedSubtree(
    key: _terminalKey,
    child: KeyedSubtree(
      key: const ValueKey('terminal-view'),
      child: _findPane(
        HomeView.terminal,
        TerminalPanel(
          hub: c.terminals,
          actions: c.actions,
          fontSize: _phone ? 12 : 13.5,
          find: _find[HomeView.terminal],
        ),
      ),
    ),
  );

  Widget _chatPanel({required double maxBubble}) => KeyedSubtree(
    key: _chatKey,
    child: KeyedSubtree(
      key: const ValueKey('chat-panel'),
      // Hard-edge clip: an anti-aliased rounded clip over the scrolling
      // list is redrawn with coverage every frame (expensive on software GL).
      child: _findPane(
        HomeView.chat,
        ClipRect(
          child: _transcriptArea(maxBubble: maxBubble, wide: !_phone),
        ),
      ),
    ),
  );

  Widget _notePanel() {
    final phone = _phone;
    return KeyedSubtree(
      key: _noteKey,
      child: KeyedSubtree(
        key: const ValueKey('note-panel'),
        // A short panel (a 70%-height freeform window with the keyboard up)
        // leaves the tabs out so the text keeps the room.
        child: _findPane(
          HomeView.note,
          LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (box.maxHeight >= kNoteTabsMinHeight) ...[
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: phone ? 4 : 8),
                    child: NoteTabsBar(controller: c, compact: phone),
                  ),
                  const Divider(height: 1),
                ],
                Expanded(
                  child: NoteEditor(
                    key: const ValueKey('note-editor'),
                    notes: c.notes,
                    clipboard: c.platform.clipboard,
                    onPasteImage: c.saveClipboardImageForNote,
                    find: _find[HomeView.note],
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
        ),
      ),
    );
  }

  /// Editor "Run": the line or selection becomes a user turn (it shows up
  /// in the chat history like a typed message).
  void _run(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (pipeline.status != SessionStatus.connected && !pipeline.standby) {
      messenger?.showSnackBar(const SnackBar(content: Text('Not connected: Run needs a live session.')));
      return;
    }
    pipeline.sendText(text);
    if (_chatVisible) return;
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
  Future<void> _openLink(String target) async {
    try {
      if (target.startsWith('/') || target.startsWith('~') || target.startsWith('file://')) {
        var path = target.startsWith('file://') ? Uri.parse(target).toFilePath() : target;
        if (path.startsWith('~')) path = path.replaceFirst('~', c.platform.paths.homeDir);
        await c.platform.viewer.show(MediaItem(kind: MediaItem.kindForPath(path), path: path));
        return;
      }
      await c.platform.clipboard.writeText(target);
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Link copied: $target')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Could not open or copy link: $error')));
      }
    }
  }

  // ------------------------------------------------------------------ parts

  /// The top-level tab strip, starting at the left edge, plus the few
  /// window-level actions on the right (status lives in the input bar).
  /// Wide: no Chat tab (the chat is always on the right) and the history
  /// button moves to the chat pane's header.
  Widget _header() {
    final phone = _phone;
    final wide = _wide;
    final t = phone ? kTouchTarget : 36.0;
    final h = phone ? kTouchTarget : 44.0;
    return SizedBox(
      height: h,
      child: Row(
        children: [
          SizedBox(width: phone ? 0 : 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                _trackTabViewport(context, box.maxWidth);
                return Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: HomeTabs(
                      view: wide ? _leftView : _view,
                      onChanged: setView,
                      hideChat: wide,
                      noteBadge: _noteBadge,
                      chatBadge: _chatBadge,
                      compact: phone,
                      height: h,
                      selectedTabKey: _selectedTabKey,
                    ),
                  ),
                );
              },
            ),
          ),
          ContextualFindButton(key: _findButtonKey, find: _activeFind, label: _findLabel, size: t),
          if (!wide) widget.menuItems.isEmpty ? _historyButton(t) : _moreMenu(t),
          if (!wide) ...widget.headerTrailing,
          SizedBox(width: phone ? 0 : 4),
        ],
      ),
    );
  }

  /// History plus the host's [WoiTabs.menuItems], in one dropdown.
  Widget _moreMenu(double size) => WoiMenuButton(
    key: const ValueKey('more-menu'),
    size: size,
    items: [
      WoiMenuItem(
        key: const ValueKey('open-history'),
        icon: Icons.history,
        label: 'All conversations',
        onTap: _openHistory,
      ),
      ...widget.menuItems,
    ],
  );

  Widget _historyButton(double size) => GlassIconButton(
    key: const ValueKey('open-history'),
    icon: Icons.history,
    tooltip: 'All conversations',
    onPressed: _openHistory,
    size: size,
  );

  /// Wide: the chat pane's title row (same height as the tab strip, so
  /// both hairlines line up).
  Widget _chatHeader() => SizedBox(
    height: 44,
    child: Row(
      children: [
        const SizedBox(width: 16),
        Icon(kHomeTabs[HomeView.chat]!.$1, size: 17, color: WoiColors.textDim),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Chat',
            key: const ValueKey('chat-pane-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: body(13.5, weight: FontWeight.w600, color: WoiColors.text),
          ),
        ),
        _historyButton(36),
        const SizedBox(width: 4),
      ],
    ),
  );

  Widget _transcriptArea({required double maxBubble, required bool wide}) {
    return Stack(
      children: [
        Positioned.fill(
          // The list follows the conversation's shape (messages added or
          // removed, screenshots for click markers); each tile follows its
          // own message, so a streaming reply rebuilds only its bubble.
          child: SelectorBuilder<Object>(
            listenable: pipeline,
            selector: _transcriptShape,
            builder: (context, _) => _transcript(maxBubble: maxBubble, wide: wide),
          ),
        ),
        Positioned(top: 10, bottom: 10, left: 10, right: 10, child: BannerStack(controller: _banners)),
      ],
    );
  }

  Object _transcriptShape() {
    final msgs = pipeline.conversation.messages;
    if (msgs.isEmpty) return (pipeline.conversation.id, pipeline.status == SessionStatus.connected);
    // By identity: a message object replaced under the same id rebuilds too.
    return (
      identityHashCode(pipeline.conversation),
      msgs.length,
      Object.hashAll([for (final m in msgs) Object.hash(identityHashCode(m), identityHashCode(m.image))]),
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
    final shots = toolScreenshotsForMessages(msgs);
    // One SelectionArea for the transcript: message text is plain Text.
    // Only the newest messages are rendered (older ones load on scrolling
    // up, then live in History); the conversation itself is untouched.
    return ClipboardSelectionArea(
      clipboard: c.platform.clipboard,
      child: ChatTranscript(
        find: _find[HomeView.chat],
        textChanges: pipeline,
        conversationId: pipeline.conversation.id,
        messages: msgs,
        padding: EdgeInsets.fromLTRB(wide ? 22 : 10, 16, wide ? 22 : 10, 8),
        onOpenHistory: _openHistory,
        tileBuilder: (context, m, idx) => LiveMessageTile(
          listenable: pipeline,
          message: m,
          audio: c.platform.audio,
          viewer: c.platform.viewer,
          urlOpener: c.platform.urlOpener,
          maxBubbleWidth: maxBubble,
          screenshot: m.kind == MessageKind.tool ? shots[idx] : null,
        ),
      ),
    );
  }
}

/// One entry of a [WoiMenuButton] dropdown.
class WoiMenuItem {
  const WoiMenuItem({required this.icon, required this.label, required this.onTap, this.key});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Key? key;
}

/// A "more" (⋮) button that opens a dropdown of [items] below it.
class WoiMenuButton extends StatelessWidget {
  const WoiMenuButton({super.key, required this.items, this.size = 36});

  final List<WoiMenuItem> items;
  final double size;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 4),
    style: MenuStyle(
      backgroundColor: WidgetStatePropertyAll(WoiColors.bg1),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(6),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: WoiColors.stroke),
        ),
      ),
    ),
    menuChildren: [
      for (final it in items)
        MenuItemButton(
          key: it.key,
          leadingIcon: Icon(it.icon, size: 20, color: WoiColors.textDim),
          onPressed: it.onTap,
          style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(200, kTouchTarget))),
          child: Text(it.label, style: body(14, color: WoiColors.text)),
        ),
    ],
    builder: (context, ctl, _) => GlassIconButton(
      icon: Icons.more_vert_rounded,
      tooltip: 'More',
      onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
      size: size,
    ),
  );
}
