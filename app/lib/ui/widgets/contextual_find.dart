import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'glass.dart';

/// Literal, case-insensitive matches with offsets in the original text.
/// RegExp preserves UTF-16 offsets even when case folding changes a character.
List<TextRange> findTextRanges(String text, String query) {
  if (query.trim().isEmpty) return const [];
  return RegExp(
    RegExp.escape(query),
    caseSensitive: false,
    unicode: true,
  ).allMatches(text).map((m) => TextRange(start: m.start, end: m.end)).toList();
}

/// UI-only state for one tab's find operation. The mounted content owns the
/// matching and revealing; the shared header owns the input and navigation.
class ContextualFindController extends ChangeNotifier {
  String _query = '';
  int _count = 0;
  int _current = -1;
  Object? _owner;
  VoidCallback? _onQuery;
  ValueChanged<int>? _onNavigate;
  bool _disposed = false;
  bool _notifyQueued = false;

  String get query => _query;
  int get matchCount => _count;
  int get currentMatch => _current;

  void attach(Object owner, {required VoidCallback onQuery, required ValueChanged<int> onNavigate}) {
    _owner = owner;
    _onQuery = onQuery;
    _onNavigate = onNavigate;
    onQuery();
  }

  void detach(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _onQuery = null;
    _onNavigate = null;
    setMatches(0, reveal: false);
  }

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _count = 0;
    _current = -1;
    _onQuery?.call();
    _notify();
  }

  void clear() => setQuery('');

  void setMatches(int count, {bool reveal = true, int? current}) {
    final next = count == 0 ? -1 : (current ?? (_current < 0 ? 0 : _current)).clamp(0, count - 1);
    final changed = count != _count || next != _current;
    _count = count;
    _current = next;
    if (reveal && _current >= 0) _onNavigate?.call(_current);
    if (changed) _notify();
  }

  void move(int delta) {
    if (_count == 0) return;
    _current = (_current + delta) % _count;
    _onNavigate?.call(_current);
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    // A new tab can publish results while its parent is building. Defer only
    // that notification; key presses and query edits remain synchronous.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_notifyQueued) return;
      _notifyQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyQueued = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    _onQuery = null;
    _onNavigate = null;
    super.dispose();
  }
}

/// The single find entry point in the tab header. It remains anchored below
/// the button, within the viewport, and leaves the content available to click.
class ContextualFindButton extends StatefulWidget {
  const ContextualFindButton({super.key, required this.find, required this.label, this.size = 36});

  final ContextualFindController find;
  final String label;
  final double size;

  @override
  State<ContextualFindButton> createState() => ContextualFindButtonState();
}

class ContextualFindButtonState extends State<ContextualFindButton> {
  final _overlay = OverlayPortalController();
  final _focus = FocusNode(debugLabel: 'contextual-find');
  late final _text = TextEditingController(text: widget.find.query);
  bool _open = false;

  bool get isOpen => _open;

  @override
  void initState() {
    super.initState();
    widget.find.addListener(_onFind);
  }

  @override
  void didUpdateWidget(ContextualFindButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.find != widget.find) {
      oldWidget.find.removeListener(_onFind);
      widget.find.addListener(_onFind);
      _syncText();
    }
  }

  void _syncText() {
    if (_text.text == widget.find.query) return;
    _text.value = TextEditingValue(
      text: widget.find.query,
      selection: TextSelection.collapsed(offset: widget.find.query.length),
    );
  }

  void _onFind() {
    if (!mounted) return;
    _syncText();
    setState(() {});
  }

  void open() {
    if (!_open) {
      setState(() => _open = true);
      _overlay.show();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      _focus.requestFocus();
      _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    });
  }

  void close() {
    if (!_open) return;
    _overlay.hide();
    setState(() => _open = false);
    widget.find.clear();
    _focus.unfocus();
  }

  @override
  void dispose() {
    widget.find.removeListener(_onFind);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _overlay,
    overlayChildBuilder: (context) {
      final anchor = this.context.findRenderObject() as RenderBox;
      final overlayBox = Overlay.of(this.context).context.findRenderObject() as RenderBox;
      final origin = anchor.localToGlobal(Offset.zero, ancestor: overlayBox);
      final viewport = overlayBox.size;
      final width = math.min(360.0, viewport.width - 16);
      final left = (origin.dx + anchor.size.width - width).clamp(8.0, math.max(8.0, viewport.width - width - 8));
      return Positioned(
        left: left.toDouble(),
        top: origin.dy + anchor.size.height + 4,
        width: width,
        child: TapRegion(
          groupId: this,
          child: Material(
            key: const ValueKey('contextual-find-popover'),
            elevation: 10,
            color: WoiColors.bg2,
            borderRadius: BorderRadius.circular(WoiRadii.md),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.escape) {
                    close();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter) {
                    widget.find.move(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const ValueKey('contextual-find-input'),
                      controller: _text,
                      focusNode: _focus,
                      style: body(14),
                      textInputAction: TextInputAction.search,
                      onChanged: widget.find.setQuery,
                      onSubmitted: (_) {
                        widget.find.move(1);
                        _focus.requestFocus();
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Find in ${widget.label}',
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        suffixIcon: widget.find.query.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey('contextual-find-clear'),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  widget.find.clear();
                                  _focus.requestFocus();
                                },
                                icon: const Icon(Icons.backspace_outlined, size: 18),
                              ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                widget.find.query.isEmpty
                                    ? 'Search ${widget.label}'
                                    : widget.find.matchCount == 0
                                    ? 'No matches'
                                    : '${widget.find.currentMatch + 1} / ${widget.find.matchCount}',
                                key: const ValueKey('contextual-find-count'),
                                style: body(12, color: WoiColors.textDim),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('contextual-find-previous'),
                          tooltip: 'Previous match (Shift+Enter)',
                          onPressed: widget.find.matchCount == 0
                              ? null
                              : () {
                                  widget.find.move(-1);
                                  _focus.requestFocus();
                                },
                          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                        ),
                        IconButton(
                          key: const ValueKey('contextual-find-next'),
                          tooltip: 'Next match (Enter)',
                          onPressed: widget.find.matchCount == 0
                              ? null
                              : () {
                                  widget.find.move(1);
                                  _focus.requestFocus();
                                },
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                        ),
                        IconButton(
                          key: const ValueKey('contextual-find-close'),
                          tooltip: 'Close search (Esc)',
                          onPressed: close,
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    child: TapRegion(
      groupId: this,
      // Keep the result set stable while a control or result receives the tap.
      // Explicit close, Escape, or clear ends the search.
      onTapOutside: (_) => _focus.unfocus(),
      child: GlassIconButton(
        key: const ValueKey('contextual-find-button'),
        icon: Icons.search_rounded,
        tooltip: 'Find in ${widget.label} (Ctrl+F)',
        active: _open,
        size: widget.size,
        onPressed: () => _open ? close() : open(),
      ),
    ),
  );
}
