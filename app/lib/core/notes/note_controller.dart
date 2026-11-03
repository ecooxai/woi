import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'note.dart';
import 'note_ops.dart';
import 'note_store.dart';

enum NoteEditSource { user, ai }

/// The latest edit made by the assistant: what changed (kept in sync with
/// later user edits) and the text before it, for the "AI edited · Undo" chip.
class AiNoteEdit {
  AiNoteEdit({required this.start, required this.end, required this.before, required this.summary, required this.seq})
    : at = DateTime.now();

  int start;
  int end;
  final String before;
  final String summary;

  /// Increments with every AI edit (the UI restarts its highlight on change).
  final int seq;
  final DateTime at;
}

/// Undo snapshot.
class _Snap {
  const _Snap(this.text, this.source);
  final String text;
  final NoteEditSource source;
}

/// The note of the active conversation: text, autosave, undo/redo (user and
/// AI edits on one stack) and the AI-edit highlight. The UI editor and the
/// `read_note` / `update_note` tools both go through it.
class NoteController extends ChangeNotifier {
  NoteController({
    required this.store,
    this.autosaveDelay = const Duration(milliseconds: 700),
    this.typingGroup = const Duration(milliseconds: 1200),
    this.maxUndo = 200,
  });

  final NoteStore store;
  final Duration autosaveDelay;

  /// User keystrokes closer together than this form one undo step.
  final Duration typingGroup;
  final int maxUndo;

  Note _note = Note(conversationId: '');
  final List<_Snap> _undo = [];
  final List<_Snap> _redo = [];
  DateTime? _lastUserEdit;
  Timer? _saveTimer;
  bool _dirty = false;
  int _aiSeq = 0;
  AiNoteEdit? _lastAi;
  DateTime? savedAt;

  /// Increments on every text change (cheap change detection for listeners).
  int revision = 0;

  String get conversationId => _note.conversationId;
  String get text => _note.markdown;
  bool get isEmpty => _note.isEmpty;
  DateTime get updatedAt => _note.updatedAt;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get dirty => _dirty;
  int get wordCount => noteWordCount(text);
  AiNoteEdit? get lastAiEdit => _lastAi;

  /// Called after every text change that should be persisted elsewhere too
  /// (the app saves note-only conversations so they show up in history).
  void Function(Note note)? onSaved;

  /// Switches to the note of [conversationId] (flushing the current one).
  Future<void> open(String conversationId) async {
    if (conversationId == _note.conversationId && conversationId.isNotEmpty) return;
    await flush();
    final n = await store.load(conversationId);
    _note = n;
    _undo.clear();
    _redo.clear();
    _lastAi = null;
    _lastUserEdit = null;
    _dirty = false;
    revision++;
    notifyListeners();
  }

  /// Text typed by the user in the editor.
  void setText(String next) {
    if (next == text) return;
    final now = DateTime.now();
    final last = _lastUserEdit;
    final grouped =
        last != null &&
        now.difference(last) < typingGroup &&
        _undo.isNotEmpty &&
        _undo.last.source == NoteEditSource.user;
    if (!grouped) _pushUndo(NoteEditSource.user);
    _redo.clear();
    _lastUserEdit = now;
    _trackAiRange(text, next);
    _set(next);
  }

  /// Ends the current typing group (e.g. on toolbar actions).
  void breakUndoGroup() => _lastUserEdit = null;

  /// Applies an `update_note` edit. Never asks for confirmation; undoable
  /// and highlighted.
  NoteEditResult applyEdit(
    NoteEditMode mode, {
    String text = '',
    String? heading,
    String? item,
    bool checked = true,
    NoteEditSource source = NoteEditSource.ai,
  }) {
    final before = this.text;
    final r = applyNoteEdit(before, mode, text: text, heading: heading, item: item, checked: checked);
    if (r.text == before) return r;
    _pushUndo(source);
    _redo.clear();
    _lastUserEdit = null;
    if (source == NoteEditSource.ai) {
      _lastAi = AiNoteEdit(start: r.start, end: r.end, before: before, summary: r.summary, seq: ++_aiSeq);
    } else {
      _trackAiRange(before, r.text);
    }
    _set(r.text);
    return r;
  }

  /// Reverts the latest AI edit (the chip's Undo). Later user typing inside
  /// the note is lost only if it happened after the AI edit; the revert is
  /// itself undoable.
  void undoAiEdit() {
    final ai = _lastAi;
    if (ai == null) return;
    _pushUndo(NoteEditSource.user);
    _redo.clear();
    _lastAi = null;
    _lastUserEdit = null;
    _set(ai.before);
  }

  /// Hides the AI-edit chip/highlight.
  void dismissAiEdit() {
    if (_lastAi == null) return;
    _lastAi = null;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final s = _undo.removeLast();
    _redo.add(_Snap(text, s.source));
    _lastUserEdit = null;
    if (_lastAi != null && s.source == NoteEditSource.ai) _lastAi = null;
    _trackAiRange(text, s.text);
    _set(s.text);
  }

  void redo() {
    if (_redo.isEmpty) return;
    final s = _redo.removeLast();
    _undo.add(_Snap(text, s.source));
    _lastUserEdit = null;
    _trackAiRange(text, s.text);
    _set(s.text);
  }

  void _pushUndo(NoteEditSource source) {
    _undo.add(_Snap(text, source));
    if (_undo.length > maxUndo) _undo.removeAt(0);
  }

  void _set(String next) {
    _note.markdown = next;
    _note.updatedAt = DateTime.now();
    _dirty = true;
    revision++;
    _scheduleSave();
    notifyListeners();
  }

  /// Keeps the AI highlight on the same characters while the user edits
  /// elsewhere (single-span diff by common prefix / suffix).
  void _trackAiRange(String before, String after) {
    final ai = _lastAi;
    if (ai == null) return;
    var pre = 0;
    final maxPre = math.min(before.length, after.length);
    while (pre < maxPre && before.codeUnitAt(pre) == after.codeUnitAt(pre)) {
      pre++;
    }
    var suf = 0;
    while (suf < before.length - pre &&
        suf < after.length - pre &&
        before.codeUnitAt(before.length - 1 - suf) == after.codeUnitAt(after.length - 1 - suf)) {
      suf++;
    }
    final oldEnd = before.length - suf;
    final delta = after.length - before.length;
    if (oldEnd <= ai.start) {
      ai.start += delta;
      ai.end += delta;
    } else if (pre < ai.end) {
      // Edit overlaps the highlighted range: grow/shrink its end.
      ai.end = math.max(ai.start, ai.end + delta);
    }
    ai.start = ai.start.clamp(0, after.length);
    ai.end = ai.end.clamp(ai.start, after.length);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(autosaveDelay, () => unawaited(flush()));
  }

  /// Writes pending changes now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty || _note.conversationId.isEmpty) return;
    _dirty = false;
    final n = _note;
    try {
      await store.save(n);
      savedAt = DateTime.now();
      onSaved?.call(n);
      notifyListeners();
    } catch (e) {
      _dirty = true;
      debugPrint('saving note failed: $e');
    }
  }

  /// Forgets the note of a deleted conversation.
  Future<void> deleteFor(String conversationId) async {
    if (conversationId == _note.conversationId) {
      _saveTimer?.cancel();
      _dirty = false;
    }
    await store.delete(conversationId);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
