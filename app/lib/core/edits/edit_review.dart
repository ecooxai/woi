import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../platform/files.dart';
import '../../tools/confirmation.dart';
import '../notes/note_controller.dart';
import '../settings/settings.dart';
import '../util/diff.dart';

enum EditTarget { note, file }

/// An AI edit shown as an inline diff card until it is applied (countdown,
/// "Apply now", Enter, "apply") or rejected ("Reject", Esc, "cancel").
class PendingEdit {
  PendingEdit({
    required this.target,
    required this.title,
    required this.oldText,
    required this.newText,
    LineDiff? diff,
    this.summary,
    this.isNewFile = false,
    this.requireApproval = false,
  }) : diff = diff ?? diffLines(oldText, newText),
       id = ++_seq;

  static int _seq = 0;

  final int id;
  final EditTarget target;

  /// File path or note title.
  final String title;
  final String oldText;
  final String newText;
  final LineDiff diff;

  /// "appended 2 lines", "replace section Todo".
  final String? summary;
  final bool isNewFile;

  /// No countdown, whatever the setting (destructive edits, e.g. deleting a
  /// whole note).
  final bool requireApproval;

  /// Countdown length and end; null while queued or when approval is needed.
  Duration? countdown;
  DateTime? deadline;

  final _done = Completer<bool>();
  bool get decided => _done.isCompleted;
}

/// Queue of [PendingEdit]s, one shown at a time. [review] resolves true when
/// the edit should be applied. The countdown comes from [delaySeconds]
/// (`AppSettings.editApplyDelay`): 0 applies at once without a card,
/// [kRequireApproval] waits for an explicit decision.
class EditReview extends ChangeNotifier {
  EditReview({required this.delaySeconds, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final int Function() delaySeconds;
  final DateTime Function() _now;
  final List<PendingEdit> _queue = [];
  Timer? _timer;

  /// Fired after every decision (applied = true).
  void Function(PendingEdit edit, bool applied)? onDecided;

  PendingEdit? get current => _queue.firstOrNull;
  int get pendingCount => _queue.length;
  bool get hasPending => _queue.isNotEmpty;

  Future<bool> review(PendingEdit e) {
    if (!e.requireApproval && delaySeconds() == 0) {
      e._done.complete(true);
      onDecided?.call(e, true);
      return e._done.future;
    }
    _queue.add(e);
    if (_queue.length == 1) _startCurrent();
    notifyListeners();
    return e._done.future;
  }

  /// Time left on the current countdown (null: waiting for approval).
  Duration? remaining([PendingEdit? e]) {
    final edit = e ?? current;
    final d = edit?.deadline;
    if (d == null) return null;
    final left = d.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Applies the current (or [id]) edit now. False when there is none.
  bool apply([int? id]) => _decideId(id, true);

  /// Rejects the current (or [id]) edit. False when there is none.
  bool reject([int? id]) => _decideId(id, false);

  /// Rejects everything pending (conversation switch, shutdown).
  void rejectAll() {
    for (final e in List.of(_queue)) {
      _decide(e, false);
    }
  }

  bool _decideId(int? id, bool ok) {
    final e = id == null ? current : _queue.where((x) => x.id == id).firstOrNull;
    if (e == null) return false;
    _decide(e, ok);
    return true;
  }

  void _startCurrent() {
    _timer?.cancel();
    _timer = null;
    final e = current;
    if (e == null) return;
    final secs = delaySeconds();
    if (e.requireApproval || secs < 0) {
      e
        ..countdown = null
        ..deadline = null;
      debugPrint('edit preview shown: ${e.target.name} "${e.title}" (waiting for approval)');
      return;
    }
    debugPrint('edit preview shown: ${e.target.name} "${e.title}" (auto-apply in ${secs}s)');
    final d = Duration(seconds: secs);
    e
      ..countdown = d
      ..deadline = _now().add(d);
    _timer = Timer(d, () => _decide(e, true));
  }

  void _decide(PendingEdit e, bool ok) {
    if (e.decided) return;
    final wasCurrent = identical(e, current);
    _queue.remove(e);
    e._done.complete(ok);
    debugPrint('edit ${ok ? 'applied' : 'rejected'}: ${e.target.name} "${e.title}"');
    onDecided?.call(e, ok);
    if (wasCurrent) _startCurrent();
    notifyListeners();
  }

  @override
  void dispose() {
    rejectAll();
    _timer?.cancel();
    super.dispose();
  }
}

// ------------------------------------------------------------------ undo

/// An applied AI edit that "undo that" can revert.
sealed class AppliedEdit {
  AppliedEdit(this.conversationId, this.summary);
  final String conversationId;
  final String summary;
}

class AppliedNoteEdit extends AppliedEdit {
  AppliedNoteEdit(super.conversationId, super.summary, {required this.revisionAfter});

  /// Note revision right after the edit (to tell whether the user typed since).
  final int revisionAfter;
}

class AppliedFileEdit extends AppliedEdit {
  AppliedFileEdit(super.conversationId, super.summary, {required this.path, this.backupPath});
  final String path;

  /// Copy of the file before the write; null when the write created it.
  final String? backupPath;
}

/// Applied AI edits per conversation, newest last, and file backups under
/// `<backupRoot>/<conversation id>/`.
class EditHistory {
  EditHistory({required this.backupRoot, required this.notes, required this.conversationId, this.maxPerConversation = 50});

  final String backupRoot;
  final NoteController notes;
  final String Function() conversationId;
  final int maxPerConversation;
  final List<AppliedEdit> _log = [];
  int _backupSeq = 0;

  List<AppliedEdit> get all => List.unmodifiable(_log);

  AppliedEdit? get last {
    final id = conversationId();
    for (final e in _log.reversed) {
      if (e.conversationId == id) return e;
    }
    return null;
  }

  void record(AppliedEdit e) {
    _log.add(e);
    final mine = _log.where((x) => x.conversationId == e.conversationId).toList();
    if (mine.length > maxPerConversation) _log.remove(mine.first);
  }

  /// Copies [path] (if it exists) before it is overwritten. Returns the
  /// backup path, or null for a new file.
  Future<String?> backup(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final dir = Directory(p.join(backupRoot, _safe(conversationId())));
    await dir.create(recursive: true);
    final name = '${DateTime.now().millisecondsSinceEpoch}-${++_backupSeq}-${p.basename(path)}';
    final copy = await f.copy(p.join(dir.path, name));
    return copy.path;
  }

  static String _safe(String id) => id.isEmpty ? '_' : id.replaceAll(RegExp(r'[^\w.-]'), '_');

  /// Reverts the latest applied edit of the current conversation. Returns
  /// what was undone, or null when there is nothing to undo.
  Future<String?> undoLast() async {
    final e = last;
    if (e == null) return null;
    _log.remove(e);
    switch (e) {
      case AppliedNoteEdit():
        if (notes.conversationId != e.conversationId) return null;
        if (notes.revision == e.revisionAfter && notes.canUndo) {
          notes.undo();
        } else if (notes.lastAiEdit != null) {
          notes.undoAiEdit();
        } else {
          notes.undo();
        }
        return 'note: undid ${e.summary}';
      case AppliedFileEdit(:final path, :final backupPath):
        if (backupPath == null) {
          final f = File(path);
          if (await f.exists()) await f.delete();
          return 'removed new file $path';
        }
        final tmp = File('$path.woi-undo');
        await File(backupPath).copy(tmp.path);
        await tmp.rename(path);
        return 'restored $path';
    }
  }
}

// ------------------------------------------------------------------ wiring

/// [ConfirmationService] that routes file writes through [EditReview]
/// (inline diff card with countdown) and backs files up before they change.
/// Shell commands keep [inner]'s explicit dialog.
class ReviewingConfirmations implements ConfirmationService {
  ReviewingConfirmations({required this.inner, required this.review, required this.history});

  final ConfirmationService inner;
  final EditReview review;
  final EditHistory history;

  @override
  Future<bool> confirmFileWrite(FileWriteRequest r) async {
    final ok = await review.review(
      PendingEdit(
        target: EditTarget.file,
        title: r.path,
        oldText: r.oldContent ?? '',
        newText: r.newContent,
        diff: r.diff,
        isNewFile: r.isNewFile,
        summary: r.isNewFile ? 'new file, ${r.diff.added} lines' : '+${r.diff.added} -${r.diff.removed}',
      ),
    );
    if (!ok) return false;
    String? backup;
    try {
      backup = await history.backup(r.path);
    } catch (e) {
      debugPrint('edit backup failed: $e');
      if (!r.isNewFile) return false; // never overwrite without a way back
    }
    history.record(
      AppliedFileEdit(
        history.conversationId(),
        '${r.isNewFile ? 'created' : 'edited'} ${p.basename(r.path)}',
        path: r.path,
        backupPath: backup,
      ),
    );
    return true;
  }

  @override
  Future<bool> confirmCommand(String command) => inner.confirmCommand(command);
}

/// Words that decide a pending edit when said or typed on their own.
enum EditVoiceCommand { apply, reject, undo }

final _apply = RegExp(
  r"^(?:(?:ok(?:ay)?|yes|yeah|yep|sure|please|go ahead(?: and)?)[\s,]+)*(?:apply|accept|approve|confirm|do it|looks good|keep it)(?:\s+(?:it|that|this|the edit|the change|now|please))*$",
  caseSensitive: false,
);
final _reject = RegExp(
  r"^(?:(?:no|nope|please)[\s,]+)*(?:reject|cancel|discard|decline|don'?t apply|do not apply|no)(?:\s+(?:it|that|this|the edit|the change|please))*$",
  caseSensitive: false,
);
final _undo = RegExp(
  r"^(?:(?:ok(?:ay)?|please|no|oops|actually)[\s,]+)*(?:undo|revert|take back|roll back)(?:\s+(?:it|that|this|the (?:last )?(?:edit|change)|your (?:last )?(?:edit|change)|please))*$",
  caseSensitive: false,
);

/// Parses "apply", "cancel", "reject that", "undo that". Apply/reject only
/// count while an edit is pending (otherwise "cancel" is a stop phrase).
EditVoiceCommand? parseEditCommand(String text, {required bool pending}) {
  final t = text.trim().replaceAll(RegExp(r'[\s.!?]+$'), '');
  if (t.isEmpty) return null;
  if (pending && _apply.hasMatch(t)) return EditVoiceCommand.apply;
  if (pending && _reject.hasMatch(t)) return EditVoiceCommand.reject;
  if (_undo.hasMatch(t)) return EditVoiceCommand.undo;
  return null;
}
