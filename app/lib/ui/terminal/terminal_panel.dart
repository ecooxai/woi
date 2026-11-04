import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/app_actions.dart';
import '../../core/terminal/terminal_hub.dart';

/// True while keyboard focus is inside a terminal view (the home screen then
/// leaves Space, Esc, Ctrl+K etc. to the shell).
bool terminalHasFocus() =>
    FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TerminalView>() != null;

/// Colours for the terminal: follows the app theme (light / dark) and keeps
/// ANSI colours readable on either background.
TerminalTheme terminalThemeFor(ThemeData theme) {
  final cs = theme.colorScheme;
  if (theme.brightness == Brightness.light) {
    return TerminalTheme(
      cursor: cs.onSurface.withValues(alpha: 0.75),
      selection: cs.primary.withValues(alpha: 0.22),
      foreground: const Color(0xFF24292F),
      background: cs.surface,
      black: const Color(0xFF24292F),
      red: const Color(0xFFCF222E),
      green: const Color(0xFF116329),
      yellow: const Color(0xFF8A6100),
      blue: const Color(0xFF0550AE),
      magenta: const Color(0xFF8250DF),
      cyan: const Color(0xFF1B7C83),
      white: const Color(0xFF6E7781),
      brightBlack: const Color(0xFF57606A),
      brightRed: const Color(0xFFA40E26),
      brightGreen: const Color(0xFF1A7F37),
      brightYellow: const Color(0xFF633C01),
      brightBlue: const Color(0xFF218BFF),
      brightMagenta: const Color(0xFFA475F9),
      brightCyan: const Color(0xFF3192AA),
      brightWhite: const Color(0xFF8C959F),
      searchHitBackground: const Color(0xFFFFE58F),
      searchHitBackgroundCurrent: const Color(0xFFFFC53D),
      searchHitForeground: const Color(0xFF24292F),
    );
  }
  return TerminalTheme(
    cursor: cs.onSurface.withValues(alpha: 0.8),
    selection: cs.primary.withValues(alpha: 0.3),
    foreground: const Color(0xFFE6EDF3),
    background: cs.surface,
    black: const Color(0xFF484F58),
    red: const Color(0xFFFF7B72),
    green: const Color(0xFF3FB950),
    yellow: const Color(0xFFD29922),
    blue: const Color(0xFF58A6FF),
    magenta: const Color(0xFFBC8CFF),
    cyan: const Color(0xFF39C5CF),
    white: const Color(0xFFB1BAC4),
    brightBlack: const Color(0xFF6E7681),
    brightRed: const Color(0xFFFFA198),
    brightGreen: const Color(0xFF56D364),
    brightYellow: const Color(0xFFE3B341),
    brightBlue: const Color(0xFF79C0FF),
    brightMagenta: const Color(0xFFD2A8FF),
    brightCyan: const Color(0xFF56D4DD),
    brightWhite: const Color(0xFFF0F6FC),
    searchHitBackground: const Color(0xFF6E5A00),
    searchHitBackgroundCurrent: const Color(0xFF9E7C00),
    searchHitForeground: const Color(0xFFF0F6FC),
  );
}

class _NewTabIntent extends Intent {
  const _NewTabIntent();
}

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _CycleTabIntent extends Intent {
  const _CycleTabIntent(this.delta);
  final int delta;
}

/// Terminal shortcuts. Plain Ctrl+C/V/A go to the shell (interrupt, literal,
/// readline); copy/paste use the Shift variants like other Linux terminals.
final Map<ShortcutActivator, Intent> _shortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): CopySelectionTextIntent.copy,
  const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): const PasteTextIntent(
    SelectionChangedCause.keyboard,
  ),
  const SingleActivator(LogicalKeyboardKey.insert, shift: true): const PasteTextIntent(SelectionChangedCause.keyboard),
  const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true): const SelectAllTextIntent(
    SelectionChangedCause.keyboard,
  ),
  const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): const _NewTabIntent(),
  const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true): const _CloseTabIntent(),
  const SingleActivator(LogicalKeyboardKey.pageDown, control: true): const _CycleTabIntent(1),
  const SingleActivator(LogicalKeyboardKey.pageUp, control: true): const _CycleTabIntent(-1),
};

/// The terminal view: a tab strip plus the active tab's terminal.
bool get _desktop => switch (defaultTargetPlatform) {
  TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
  _ => false,
};

class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key, required this.hub, this.actions, this.fontSize = 13.5, this.hardwareKeyboardOnly});
  final TerminalHub hub;

  /// The tab strip's buttons, shortcuts and menu go through these (the same
  /// paths voice uses); without them they act on [hub] directly (tests).
  final AppActions? actions;
  final double fontSize;

  /// Read typed characters straight from key events instead of the platform
  /// text-input (IME) connection. Defaults to true on desktop: xterm's IME
  /// path diffs against an editing state it resets asynchronously, so fast
  /// typing on Linux doubled or replayed characters. The cost is no IME
  /// composition (CJK) in the desktop terminal; Android keeps the IME path
  /// for its soft keyboard.
  final bool? hardwareKeyboardOnly;

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  final _focus = <int, FocusNode>{};

  TerminalHub get hub => widget.hub;

  @override
  void initState() {
    super.initState();
    // Opening the view starts the first shell (after this frame: the hub
    // notifies listeners that may be mid-build).
    if (hub.sessions.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) hub.ensureTab();
      });
    }
  }

  @override
  void dispose() {
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  FocusNode _nodeFor(TerminalSession s) => _focus.putIfAbsent(s.id, () => FocusNode(debugLabel: 'terminal-${s.id}'));

  void _prune() {
    final ids = hub.sessions.map((s) => s.id).toSet();
    _focus.removeWhere((id, f) {
      if (ids.contains(id)) return false;
      f.dispose();
      return true;
    });
  }

  /// Focuses a tab's terminal after the next frame, unless a dialog or menu
  /// opened in the meantime (it would steal the dialog's keyboard focus).
  void _focusLater(int id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _focus[id]?.requestFocus();
    });
  }

  AppActions? get _actions => widget.actions;

  void _newTab() => _focusLater((_actions?.newTerminalTab() ?? hub.newShell()).id);

  void _close(TerminalSession s) {
    final a = _actions;
    a == null ? hub.close(s) : a.closeTerminalTab(s);
  }

  void _select(int i) {
    final a = _actions;
    a == null ? hub.select(i) : a.selectTerminalTab(i);
    final s = hub.active;
    if (s != null) _focusLater(s.id);
  }

  Future<void> _rename(TerminalSession s) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initial: s.title),
    );
    if (!mounted) return;
    if (name != null) {
      final a = _actions;
      a == null ? s.rename(name) : a.renameTerminalTab(s, name);
    }
    _focus[s.id]?.requestFocus();
  }

  Future<void> _contextMenu(TerminalSession s, Offset global) async {
    final hasSel = s.controller.selection != null;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'copy', enabled: hasSel, child: const _MenuRow('Copy', 'Ctrl+Shift+C')),
        const PopupMenuItem(value: 'paste', child: _MenuRow('Paste', 'Ctrl+Shift+V')),
        const PopupMenuItem(value: 'all', child: _MenuRow('Select all', 'Ctrl+Shift+A')),
        const PopupMenuItem(value: 'clear', child: _MenuRow('Clear', '')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'new', child: _MenuRow('New tab', 'Ctrl+Shift+T')),
        const PopupMenuItem(value: 'rename', child: _MenuRow('Rename tab…', '')),
        const PopupMenuItem(value: 'close', child: _MenuRow('Close tab', 'Ctrl+Shift+W')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'copy':
        final sel = s.controller.selection;
        if (sel != null) await Clipboard.setData(ClipboardData(text: s.terminal.buffer.getText(sel)));
        s.controller.clearSelection();
      case 'paste':
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (text != null) s.terminal.paste(text);
      case 'all':
        final t = s.terminal;
        s.controller.setSelection(
          t.buffer.createAnchor(0, 0),
          t.buffer.createAnchor(t.viewWidth, t.buffer.height - 1),
        );
      case 'clear':
        s.controller.clearSelection();
        s.terminal.eraseScrollbackOnly();
        if (s.kind == TerminalKind.shell && s.running) {
          s.terminal.onOutput?.call('\x0c'); // the shell redraws its prompt
        } else {
          s.terminal.eraseDisplay();
          s.terminal.setCursor(0, 0);
        }
      case 'new':
        _newTab();
      case 'rename':
        await _rename(s);
      case 'close':
        _close(s);
    }
    if (choice != 'rename' && choice != 'close') _focus[s.id]?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final termTheme = terminalThemeFor(theme);
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        _prune();
        final sessions = hub.sessions;
        final active = hub.active;
        return Container(
          key: const ValueKey('terminal-panel'),
          decoration: BoxDecoration(
            color: termTheme.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _TabStrip(
                sessions: sessions,
                activeIndex: hub.activeIndex,
                onSelect: _select,
                onClose: _close,
                onRename: _rename,
                onNew: _newTab,
              ),
              Divider(height: 1, thickness: 1, color: theme.dividerColor.withValues(alpha: 0.5)),
              Expanded(
                child: active == null
                    ? Center(
                        child: TextButton.icon(
                          key: const ValueKey('terminal-empty-new'),
                          onPressed: _newTab,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('New terminal'),
                        ),
                      )
                    : Actions(
                        actions: {
                          _NewTabIntent: CallbackAction<_NewTabIntent>(onInvoke: (_) => _newTab()),
                          _CloseTabIntent: CallbackAction<_CloseTabIntent>(onInvoke: (_) => _close(active)),
                          _CycleTabIntent: CallbackAction<_CycleTabIntent>(
                            onInvoke: (i) {
                              final n = sessions.length;
                              if (n > 1) _select((hub.activeIndex + i.delta) % n);
                              return null;
                            },
                          ),
                        },
                        child: TerminalView(
                          active.terminal,
                          key: ValueKey('terminal-view-${active.id}'),
                          controller: active.controller,
                          focusNode: _nodeFor(active),
                          autofocus: true,
                          hardwareKeyboardOnly: widget.hardwareKeyboardOnly ?? _desktop,
                          theme: termTheme,
                          textStyle: TerminalStyle(
                            fontSize: widget.fontSize,
                            height: 1.25,
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: const ['DejaVu Sans Mono', 'Noto Sans Mono', 'monospace', 'Noto Color Emoji'],
                          ),
                          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                          shortcuts: _shortcuts,
                          keyboardAppearance: theme.brightness,
                          cursorType: TerminalCursorType.block,
                          readOnly: active.kind == TerminalKind.ai && !active.running,
                          onSecondaryTapDown: (details, _) => _contextMenu(active, details.globalPosition),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename tab'),
    content: TextField(
      key: const ValueKey('terminal-rename-field'),
      controller: _ctl,
      autofocus: true,
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.of(context).pop(_ctl.text), child: const Text('Rename')),
    ],
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.label, this.keys);
  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Row(
      children: [
        Expanded(child: Text(label)),
        if (keys.isNotEmpty) Text(keys, style: TextStyle(fontSize: 12, color: dim)),
      ],
    );
  }
}

(int, DateTime)? _lastTap;

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.sessions,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    required this.onRename,
    required this.onNew,
  });

  final List<TerminalSession> sessions;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<TerminalSession> onClose;
  final ValueChanged<TerminalSession> onRename;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Same tab look as the app's other tabs: label + accent underline.
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              itemCount: sessions.length,
              itemBuilder: (context, i) {
                final s = sessions[i];
                final on = i == activeIndex;
                final fg = on ? cs.onSurface : cs.onSurface.withValues(alpha: 0.6);
                return Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: GestureDetector(
                    onSecondaryTapDown: (d) => _tabMenu(context, s, d.globalPosition),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        key: ValueKey('terminal-tab-${s.id}'),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                        // A second click within 400 ms renames (no
                        // double-tap recognizer: it would delay every click).
                        onTap: () {
                          final now = DateTime.now();
                          final again =
                              _lastTap?.$1 == s.id && now.difference(_lastTap!.$2) < const Duration(milliseconds: 400);
                          _lastTap = again ? null : (s.id, now);
                          again ? onRename(s) : onSelect(i);
                        },
                        child: Container(
                          padding: const EdgeInsets.only(left: 10, right: 2),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: on ? cs.primary : Colors.transparent, width: 2)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                s.kind == TerminalKind.ai ? Icons.auto_awesome_outlined : Icons.terminal,
                                size: 14,
                                color: on ? cs.primary : fg,
                              ),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 160),
                                child: Text(
                                  s.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: fg,
                                    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (!s.running && s.kind == TerminalKind.shell && s.lastExitCode != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text('exited', style: TextStyle(fontSize: 11, color: cs.error)),
                                ),
                              IconButton(
                                key: ValueKey('terminal-close-${s.id}'),
                                tooltip: 'Close tab (Ctrl+Shift+W)',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                                iconSize: 14,
                                color: fg,
                                onPressed: () => onClose(s),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const ValueKey('terminal-new-tab'),
            tooltip: 'New tab (Ctrl+Shift+T)',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: cs.onSurface.withValues(alpha: 0.7),
            onPressed: onNew,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Future<void> _tabMenu(BuildContext context, TerminalSession s, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('Rename…')),
        PopupMenuItem(value: 'close', child: Text('Close')),
      ],
    );
    if (choice == 'rename') onRename(s);
    if (choice == 'close') onClose(s);
  }
}
