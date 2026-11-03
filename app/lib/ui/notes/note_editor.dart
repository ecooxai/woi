import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/notes/note_controller.dart';
import '../../core/notes/note_ops.dart';
import '../theme.dart';
import 'markdown_syntax.dart';
import 'markdown_view.dart';

/// Source, side-by-side or rendered.
enum NoteViewMode { edit, split, preview }

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _WrapIntent extends Intent {
  const _WrapIntent(this.marker);
  final String marker;
}

class _NewlineIntent extends Intent {
  const _NewlineIntent();
}

class _IndentIntent extends Intent {
  const _IndentIntent(this.outdent);
  final bool outdent;
}

class _ToggleCheckIntent extends Intent {
  const _ToggleCheckIntent();
}

class _RunIntent extends Intent {
  const _RunIntent();
}

/// The text "Run" sends: the selection, or else the line at the cursor
/// (trimmed). Empty when there is nothing to send.
String runTextFor(TextEditingValue v) {
  final t = v.text;
  final sel = v.selection;
  if (!sel.isValid) return '';
  if (!sel.isCollapsed) return sel.textInside(t).trim();
  final at = sel.baseOffset.clamp(0, t.length);
  final s = at <= 0 ? 0 : t.lastIndexOf('\n', at - 1) + 1;
  var e = t.indexOf('\n', at);
  if (e < 0) e = t.length;
  return t.substring(s, e).trim();
}

/// Action that only claims the key when [enabled] says so (otherwise the
/// key falls through to the text field, e.g. Enter outside a list).
class _FnAction<T extends Intent> extends Action<T> {
  _FnAction(this.fn, {this.enabled});
  final void Function(T intent) fn;
  final bool Function()? enabled;

  @override
  bool isEnabled(T intent) => enabled?.call() ?? true;

  @override
  Object? invoke(T intent) {
    fn(intent);
    return null;
  }
}

final _listLine = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\]\s+)?');

/// The note editor: highlighted Markdown source, live preview (toggle or
/// split), toolbar, clickable checklists, autosave state, undo/redo, word
/// count and the "AI edited" highlight with its Undo chip.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.notes,
    this.compact = false,
    this.onOpenLink,
    this.initialMode,
    this.onRun,
  });

  final NoteController notes;

  /// "Run": sends the cursor line or the selection to the assistant as a
  /// user turn. Null disables the button (e.g. while offline).
  final ValueChanged<String>? onRun;

  /// Phone layout: smaller toolbar, no split mode.
  final bool compact;

  /// Called for clicked links / file paths in the preview.
  final void Function(String target)? onOpenLink;
  final NoteViewMode? initialMode;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> with SingleTickerProviderStateMixin {
  static NoteViewMode _lastMode = NoteViewMode.edit;

  late final MarkdownEditingController _ctrl = MarkdownEditingController(text: widget.notes.text);
  final _focus = FocusNode(debugLabel: 'note-editor');
  final _editScroll = ScrollController();
  final _previewScroll = ScrollController();
  late NoteViewMode _mode = widget.initialMode ?? _lastMode;
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..addListener(_onGlow);
  bool _syncing = false;
  int _aiSeq = -1;

  NoteController get notes => widget.notes;
  NoteViewMode get mode => _effectiveMode;
  MarkdownEditingController get textController => _ctrl;

  NoteViewMode get _effectiveMode => _dense && _mode == NoteViewMode.split ? NoteViewMode.edit : _mode;

  /// Narrow pane (phone, or the note half of the side-by-side view): fewer
  /// toolbar buttons, icon-only mode switch, no in-editor split.
  bool _dense = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onText);
    notes.addListener(_onNotes);
    _syncAi();
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notes != widget.notes) {
      oldWidget.notes.removeListener(_onNotes);
      widget.notes.addListener(_onNotes);
      _onNotes();
    }
  }

  @override
  void dispose() {
    notes.removeListener(_onNotes);
    _ctrl.removeListener(_onText);
    _ctrl.dispose();
    _focus.dispose();
    _editScroll.dispose();
    _previewScroll.dispose();
    _glow.dispose();
    super.dispose();
  }

  void setMode(NoteViewMode m) {
    setState(() => _mode = _lastMode = m);
    if (m != NoteViewMode.preview) _focus.requestFocus();
  }

  // ------------------------------------------------------------------ sync

  void _onText() {
    if (_syncing) return;
    if (_ctrl.text != notes.text) notes.setText(_ctrl.text);
  }

  void _onNotes() {
    final next = notes.text;
    if (next != _ctrl.text) {
      final old = _ctrl.text;
      var pre = 0;
      final maxPre = math.min(old.length, next.length);
      while (pre < maxPre && old.codeUnitAt(pre) == next.codeUnitAt(pre)) {
        pre++;
      }
      var suf = 0;
      while (suf < old.length - pre &&
          suf < next.length - pre &&
          old.codeUnitAt(old.length - 1 - suf) == next.codeUnitAt(next.length - 1 - suf)) {
        suf++;
      }
      final sel = _ctrl.selection;
      TextSelection nextSel;
      if (!sel.isValid) {
        nextSel = sel;
      } else if (sel.end <= pre) {
        nextSel = sel; // change after the cursor
      } else if (sel.start >= old.length - suf) {
        final d = next.length - old.length;
        nextSel = TextSelection(baseOffset: sel.baseOffset + d, extentOffset: sel.extentOffset + d);
      } else {
        nextSel = TextSelection.collapsed(offset: next.length - suf);
      }
      _syncing = true;
      _ctrl.value = TextEditingValue(
        text: next,
        selection: nextSel.isValid
            ? TextSelection(
                baseOffset: nextSel.baseOffset.clamp(0, next.length),
                extentOffset: nextSel.extentOffset.clamp(0, next.length),
              )
            : nextSel,
      );
      _syncing = false;
    }
    _syncAi();
    if (mounted) setState(() {});
  }

  void _syncAi() {
    final ai = notes.lastAiEdit;
    if (ai == null) {
      _ctrl.aiRange = null;
      return;
    }
    _ctrl.aiRange = TextRange(start: ai.start, end: ai.end);
    if (ai.seq != _aiSeq) {
      _aiSeq = ai.seq;
      _glow.forward(from: 0);
    }
  }

  void _onGlow() {
    // Bright flash that settles to a steady tint.
    _ctrl.setGlow(1.8 - 0.8 * Curves.easeOut.transform(_glow.value));
  }

  // --------------------------------------------------------------- editing

  /// Replaces the editor value as one undo step.
  void _apply(TextEditingValue v) {
    notes.breakUndoGroup();
    _ctrl.value = v;
    notes.breakUndoGroup();
  }

  void _wrap(String marker, [String? close]) {
    close ??= marker;
    final v = _ctrl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final t = v.text;
    final inner = sel.textInside(t);
    final before = t.substring(0, sel.start), after = t.substring(sel.end);
    if (before.endsWith(marker) && after.startsWith(close)) {
      // Toggle off.
      final nt = before.substring(0, before.length - marker.length) + inner + after.substring(close.length);
      _apply(
        TextEditingValue(
          text: nt,
          selection: TextSelection(baseOffset: sel.start - marker.length, extentOffset: sel.end - marker.length),
        ),
      );
      return;
    }
    final nt = '$before$marker$inner$close$after';
    _apply(
      TextEditingValue(
        text: nt,
        selection: inner.isEmpty
            ? TextSelection.collapsed(offset: sel.start + marker.length)
            : TextSelection(baseOffset: sel.start + marker.length, extentOffset: sel.end + marker.length),
      ),
    );
    _focus.requestFocus();
  }

  void _link() {
    final v = _ctrl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final inner = sel.textInside(v.text);
    final label = inner.isEmpty ? 'link' : inner;
    final ins = '[$label](https://)';
    final nt = v.text.replaceRange(sel.start, sel.end, ins);
    final urlStart = sel.start + label.length + 3;
    _apply(
      TextEditingValue(
        text: nt,
        selection: TextSelection(baseOffset: urlStart, extentOffset: urlStart + 'https://'.length),
      ),
    );
    _focus.requestFocus();
  }

  (int, int) _lineBounds(String t, int from, int to) {
    final s = from <= 0 ? 0 : t.lastIndexOf('\n', from - 1) + 1;
    var e = t.indexOf('\n', to);
    if (e < 0) e = t.length;
    return (s, e);
  }

  /// Applies [edit] to every line touched by the selection.
  void _editLines(String Function(String line, int index) edit) {
    final v = _ctrl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final (s, e) = _lineBounds(v.text, sel.start, sel.end);
    final lines = v.text.substring(s, e).split('\n');
    final out = [for (var i = 0; i < lines.length; i++) edit(lines[i], i)].join('\n');
    final nt = v.text.replaceRange(s, e, out);
    final delta = out.length - (e - s);
    _apply(
      TextEditingValue(
        text: nt,
        selection: sel.isCollapsed
            ? TextSelection.collapsed(offset: (sel.start + (lines.length == 1 ? delta : 0)).clamp(s, s + out.length))
            : TextSelection(baseOffset: s, extentOffset: s + out.length),
      ),
    );
    _focus.requestFocus();
  }

  void _heading() => _editLines((l, _) {
    final m = RegExp(r'^(#{1,6})\s+').firstMatch(l);
    if (m == null) return '# $l';
    final level = m.group(1)!.length;
    final rest = l.substring(m.end);
    return level >= 3 ? rest : '${'#' * (level + 1)} $rest';
  });

  void _linePrefix(String kind) => _editLines((l, i) {
    final m = _listLine.firstMatch(l);
    final indent = m?.group(1) ?? RegExp(r'^\s*').firstMatch(l)!.group(0)!;
    final content = m == null ? l.substring(indent.length) : l.substring(m.end);
    final isCheck = m?.group(4) != null;
    final isNum = m != null && RegExp(r'^\d').hasMatch(m.group(2)!);
    final isBullet = m != null && !isCheck && !isNum;
    switch (kind) {
      case 'check':
        return isCheck ? '$indent$content' : '$indent- [ ] $content';
      case 'number':
        return isNum ? '$indent$content' : '$indent${i + 1}. $content';
      case 'quote':
        return l.startsWith('> ') ? l.substring(2) : '> $l';
      default:
        return isBullet ? '$indent$content' : '$indent- $content';
    }
  });

  void _codeBlock() {
    final v = _ctrl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final inner = sel.textInside(v.text);
    if (!inner.contains('\n') && inner.isNotEmpty) return _wrap('`');
    final before = v.text.substring(0, sel.start);
    final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
    final ins = '$lead```\n$inner\n```\n';
    _apply(
      TextEditingValue(
        text: v.text.replaceRange(sel.start, sel.end, ins),
        selection: TextSelection.collapsed(offset: sel.start + lead.length + 4 + inner.length),
      ),
    );
    _focus.requestFocus();
  }

  /// Enter on a list line continues the list (an empty item ends it).
  bool _listAtCursor() {
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    final (s, e) = _lineBounds(_ctrl.text, sel.start, sel.start);
    return _listLine.hasMatch(_ctrl.text.substring(s, e)) &&
        sel.start >= s + _listLine.firstMatch(_ctrl.text.substring(s, e))!.end;
  }

  void _newline() {
    final v = _ctrl.value;
    final at = v.selection.start;
    final (s, e) = _lineBounds(v.text, at, at);
    final line = v.text.substring(s, e);
    final m = _listLine.firstMatch(line)!;
    if (line.substring(m.end).trim().isEmpty && at == e) {
      // Empty item: end the list.
      _apply(
        TextEditingValue(
          text: v.text.replaceRange(s, e, ''),
          selection: TextSelection.collapsed(offset: s),
        ),
      );
      return;
    }
    var marker = m.group(2)!;
    final n = int.tryParse(marker.substring(0, marker.length - 1));
    if (RegExp(r'^\d').hasMatch(marker) && n != null) marker = '${n + 1}${marker[marker.length - 1]}';
    final cont = '\n${m.group(1)}$marker${m.group(3)}${m.group(4) != null ? '[ ] ' : ''}';
    _ctrl.value = TextEditingValue(
      text: v.text.replaceRange(at, v.selection.end, cont),
      selection: TextSelection.collapsed(offset: at + cont.length),
    );
  }

  bool _onListLine() {
    final sel = _ctrl.selection;
    if (!sel.isValid) return false;
    final (s, e) = _lineBounds(_ctrl.text, sel.start, sel.end);
    return _ctrl.text.substring(s, e).split('\n').any(_listLine.hasMatch);
  }

  void _indent(bool outdent) => _editLines((l, _) {
    if (!_listLine.hasMatch(l)) return l;
    if (!outdent) return '  $l';
    return l.startsWith('  ') ? l.substring(2) : l.trimLeft();
  });

  void toggleCheckAt(int line) {
    final next = toggleChecklistLine(notes.text, line);
    if (next == null) return;
    notes.breakUndoGroup();
    notes.setText(next);
    notes.breakUndoGroup();
  }

  void _toggleCheckAtCursor() {
    final sel = _ctrl.selection;
    if (!sel.isValid) return;
    final line = '\n'.allMatches(_ctrl.text.substring(0, sel.start)).length;
    toggleCheckAt(line);
  }

  /// Sends the selection or cursor line through [NoteEditor.onRun].
  void run() {
    final text = runTextFor(_ctrl.value);
    final onRun = widget.onRun;
    if (onRun == null) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Put the cursor on a line or select text to run it.')),
      );
      return;
    }
    onRun(text);
  }

  void _onTapEditor() {
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final line = checkboxLineAt(_ctrl.text, sel.baseOffset);
    if (line != null) toggleCheckAt(line);
  }

  // ------------------------------------------------------------------ view

  (int, int)? get _aiLines {
    final ai = notes.lastAiEdit;
    if (ai == null) return null;
    final t = notes.text;
    final a = '\n'.allMatches(t.substring(0, ai.start.clamp(0, t.length))).length;
    final b = '\n'.allMatches(t.substring(0, ai.end.clamp(0, t.length))).length;
    return (a, b);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _dense = widget.compact || box.maxWidth < 720;
      return _build();
    },
  );

  Widget _build() {
    final m = _effectiveMode;
    final editor = _editorPane();
    final preview = _previewPane();
    final content = switch (m) {
      NoteViewMode.edit => editor,
      NoteViewMode.preview => preview,
      NoteViewMode.split => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: editor),
          Container(width: 1, color: WoiColors.stroke),
          Expanded(child: preview),
        ],
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        Container(height: 1, color: WoiColors.stroke),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: WoiMotion.medium,
                  child: KeyedSubtree(key: ValueKey(m), child: content),
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 12, child: Center(child: _aiChip())),
            ],
          ),
        ),
        _footer(),
      ],
    );
  }

  Widget _editorPane() {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): const _UndoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): const _UndoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): const _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): const _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): const _WrapIntent('**'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): const _WrapIntent('*'),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): const _WrapIntent('`'),
        const SingleActivator(LogicalKeyboardKey.enter): const _NewlineIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): const _NewlineIntent(),
        const SingleActivator(LogicalKeyboardKey.tab): const _IndentIntent(false),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true): const _IndentIntent(true),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): const _ToggleCheckIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): const _RunIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _UndoIntent: _FnAction<_UndoIntent>((_) => notes.undo()),
          _RedoIntent: _FnAction<_RedoIntent>((_) => notes.redo()),
          _WrapIntent: _FnAction<_WrapIntent>((i) => _wrap(i.marker)),
          _NewlineIntent: _FnAction<_NewlineIntent>((_) => _newline(), enabled: _listAtCursor),
          _IndentIntent: _FnAction<_IndentIntent>((i) => _indent(i.outdent), enabled: _onListLine),
          _ToggleCheckIntent: _FnAction<_ToggleCheckIntent>((_) => _toggleCheckAtCursor()),
          _RunIntent: _FnAction<_RunIntent>((_) => run(), enabled: () => widget.onRun != null),
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final hPad = widget.compact ? 18.0 : math.max(28.0, (box.maxWidth - 820) / 2);
            return Scrollbar(
              controller: _editScroll,
              child: TextField(
                key: const ValueKey('note-editor-field'),
                controller: _ctrl,
                focusNode: _focus,
                scrollController: _editScroll,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                cursorColor: WoiColors.cyan,
                cursorWidth: 2,
                cursorRadius: const Radius.circular(2),
                style: MdEditorStyle.base(),
                onTap: _onTapEditor,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.fromLTRB(hPad, widget.compact ? 16 : 24, hPad, widget.compact ? 12 : 16),
                  hintText: '# Untitled note\n\nStart typing, or just talk.\nWoi records decisions, todos, facts and paths here as you go.',
                  hintMaxLines: 6,
                  hintStyle: body(15.5, height: 1.62, color: WoiColors.textFaint),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _previewPane() => LayoutBuilder(
    builder: (context, box) {
      final hPad = widget.compact ? 18.0 : math.max(28.0, (box.maxWidth - 820) / 2);
      return MarkdownView(
        key: const ValueKey('note-preview'),
        markdown: notes.text,
        scrollController: _previewScroll,
        onToggleLine: toggleCheckAt,
        onLink: widget.onOpenLink,
        highlightLines: _aiLines,
        padding: EdgeInsets.fromLTRB(hPad, widget.compact ? 16 : 24, hPad, 80),
        emptyHint: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 40, color: WoiColors.violet.withValues(alpha: 0.7)),
                const SizedBox(height: 12),
                Text('Nothing here yet', style: display(17)),
                const SizedBox(height: 6),
                Text(
                  'Talk to Woi: decisions, todos, facts and paths land in this note.',
                  textAlign: TextAlign.center,
                  style: body(13.5, color: WoiColors.textDim),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _toolbar() {
    final m = _effectiveMode;
    final editing = m != NoteViewMode.preview;
    Widget btn(IconData icon, String tip, VoidCallback? onTap, {Key? key}) =>
        _ToolButton(key: key, icon: icon, tooltip: tip, onTap: onTap, compact: widget.compact);
    final format = <Widget>[
      btn(Icons.title_rounded, 'Heading', editing ? _heading : null),
      btn(Icons.format_bold_rounded, 'Bold (Ctrl+B)', editing ? () => _wrap('**') : null),
      btn(Icons.format_italic_rounded, 'Italic (Ctrl+I)', editing ? () => _wrap('*') : null),
      btn(Icons.format_list_bulleted_rounded, 'Bulleted list', editing ? () => _linePrefix('bullet') : null),
      btn(
        Icons.checklist_rounded,
        'Checklist',
        editing ? () => _linePrefix('check') : null,
        key: const ValueKey('tb-check'),
      ),
      if (!_dense)
        btn(Icons.format_list_numbered_rounded, 'Numbered list', editing ? () => _linePrefix('number') : null),
      if (!_dense) btn(Icons.format_quote_rounded, 'Quote', editing ? () => _linePrefix('quote') : null),
      btn(Icons.code_rounded, 'Code (Ctrl+E)', editing ? _codeBlock : null),
      btn(Icons.link_rounded, 'Link', editing ? _link : null),
    ];
    final history = <Widget>[
      btn(Icons.undo_rounded, 'Undo (Ctrl+Z)', notes.canUndo ? notes.undo : null, key: const ValueKey('tb-undo')),
      btn(Icons.redo_rounded, 'Redo (Ctrl+Shift+Z)', notes.canRedo ? notes.redo : null, key: const ValueKey('tb-redo')),
    ];
    final modes = _ModeSwitch(mode: m, compact: _dense, onChanged: setMode);
    final runBtn = Tooltip(
      message: widget.onRun == null
          ? 'Run (connect first)'
          : 'Run: send the current line or selection to Woi (Ctrl+R)',
      child: FilledButton.icon(
        key: const ValueKey('note-run'),
        onPressed: widget.onRun == null ? null : run,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, widget.compact ? kTouchTarget : 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: body(13, weight: FontWeight.w600),
          disabledBackgroundColor: WoiColors.glassStrong,
          disabledForegroundColor: WoiColors.textFaint,
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 18),
        label: const Text('Run'),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.compact ? 8 : 14, 8, widget.compact ? 8 : 14, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...format,
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    color: WoiColors.stroke,
                  ),
                  ...history,
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          modes,
          const SizedBox(width: 8),
          runBtn,
        ],
      ),
    );
  }

  Widget _footer() {
    final words = notes.wordCount;
    final saved = notes.dirty
        ? ('Saving', WoiColors.amber, Icons.sync_rounded)
        : notes.savedAt != null
        ? ('Saved', WoiColors.mint, Icons.cloud_done_outlined)
        : notes.isEmpty
        ? ('Empty', WoiColors.textFaint, Icons.edit_note_rounded)
        : ('Saved', WoiColors.mint, Icons.cloud_done_outlined);
    final chars = notes.text.length;
    return Container(
      padding: EdgeInsets.fromLTRB(widget.compact ? 16 : 20, 7, widget.compact ? 16 : 20, 9),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: WoiColors.stroke)),
      ),
      child: Row(
        children: [
          Icon(saved.$3, size: 14, color: saved.$2),
          const SizedBox(width: 6),
          Text(
            saved.$1,
            key: const ValueKey('note-saved'),
            style: body(12, weight: FontWeight.w600, color: saved.$2),
          ),
          const SizedBox(width: 14),
          Text(
            '$words ${words == 1 ? 'word' : 'words'}',
            key: const ValueKey('note-words'),
            style: body(12, color: WoiColors.textDim).copyWith(fontFeatures: kTabular),
          ),
          if (!_dense) ...[
            const SizedBox(width: 10),
            Text(
              '$chars chars',
              style: body(12, color: WoiColors.textFaint).copyWith(fontFeatures: kTabular),
            ),
          ],
          const SizedBox(width: 12),
          Expanded(
            child: _dense
                ? const SizedBox.shrink()
                : Text(
                    'Markdown  ·  Ctrl+B  Ctrl+I  Ctrl+E  ·  Ctrl+Enter toggles a todo  ·  Ctrl+R runs a line',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: body(11.5, color: WoiColors.textFaint),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _aiChip() {
    final ai = notes.lastAiEdit;
    return AnimatedSwitcher(
      duration: WoiMotion.medium,
      switchInCurve: WoiMotion.emphasized,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.5), end: Offset.zero).animate(a),
          child: c,
        ),
      ),
      child: ai == null
          ? const SizedBox.shrink()
          : Container(
              key: ValueKey('ai-chip-${ai.seq}'),
              constraints: BoxConstraints(maxWidth: widget.compact ? 360 : 560),
              padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
              decoration: BoxDecoration(
                color: WoiColors.bg1,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: WoiColors.violet.withValues(alpha: 0.45)),
                boxShadow: [BoxShadow(color: WoiColors.shadow, blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 16, color: WoiColors.violet),
                  const SizedBox(width: 8),
                  Text(
                    'AI edited',
                    style: body(12.5, weight: FontWeight.w700, color: WoiColors.violet),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      ai.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(12.5, color: WoiColors.textDim),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: const ValueKey('ai-undo'),
                    onPressed: notes.undoAiEdit,
                    style: TextButton.styleFrom(
                      foregroundColor: WoiColors.violet,
                      backgroundColor: WoiColors.violet.withValues(alpha: 0.10),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 32),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.undo_rounded, size: 16),
                    label: Text('Undo', style: body(12.5, weight: FontWeight.w600)),
                  ),
                  IconButton(
                    key: const ValueKey('ai-dismiss'),
                    tooltip: 'Keep',
                    onPressed: notes.dismissAiEdit,
                    iconSize: 16,
                    style: IconButton.styleFrom(minimumSize: const Size(32, 32), foregroundColor: WoiColors.textDim),
                    icon: const Icon(Icons.check_rounded),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.tooltip, this.onTap, this.compact = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: compact ? 40 : 34,
        height: compact ? 40 : 34,
        child: Icon(
          icon,
          size: 19,
          color: onTap == null ? WoiColors.textFaint.withValues(alpha: 0.5) : WoiColors.textDim,
        ),
      ),
    ),
  );
}

/// Edit / Split / Preview pill switch.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged, this.compact = false});
  final NoteViewMode mode;
  final ValueChanged<NoteViewMode> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final items = [
      (NoteViewMode.edit, Icons.edit_outlined, 'Edit'),
      if (!compact) (NoteViewMode.split, Icons.vertical_split_outlined, 'Split'),
      (NoteViewMode.preview, Icons.visibility_outlined, 'Preview'),
    ];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: WoiColors.glass,
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (m, icon, label) in items)
            Semantics(
              selected: m == mode,
              button: true,
              label: label,
              child: Tooltip(
                message: label,
                child: InkWell(
                  key: ValueKey('note-mode-${m.name}'),
                  onTap: () => onChanged(m),
                  borderRadius: BorderRadius.circular(WoiRadii.sm),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 10, vertical: compact ? 8 : 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WoiRadii.sm),
                      color: m == mode ? WoiColors.bg1 : null,
                      border: Border.all(color: m == mode ? WoiColors.stroke : Colors.transparent),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 15, color: m == mode ? WoiColors.text : WoiColors.textDim),
                        if (!compact) ...[
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: body(
                              12,
                              weight: FontWeight.w600,
                              color: m == mode ? WoiColors.text : WoiColors.textDim,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
