import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/media_viewer.dart';
import '../tools/note_tools.dart';
import 'app_controller.dart';
import 'edits/edit_review.dart';
import 'notes/note_ops.dart';
import 'notes/note_text_ops.dart';
import 'settings/settings.dart';
import 'storage/history_store.dart';
import 'terminal/terminal_hub.dart';

/// The top-level tabs, in tab order (Ctrl+1..4).
enum HomeView { note, chat, terminal, settings }

/// Failure of an app action, with a message for the user / model.
class AppActionError implements Exception {
  AppActionError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Every user-facing app function in one place. UI buttons and shortcuts,
/// the `note_control` / `app_control` tools and the delegation fast paths
/// all go through here, so voice and clicks behave the same.
class AppActions {
  AppActions(this.c);

  final AppController c;

  // ------------------------------------------------------------------ views

  /// Selected tab; the home screen renders whatever this says.
  final view = ValueNotifier<HomeView>(HomeView.note);

  /// The tab before the current one (Esc in Settings goes back to it).
  HomeView previousView = HomeView.note;

  /// Note and chat side by side. Only effective when [splitAvailable] and
  /// the Note or Chat tab is selected; Terminal and Settings stay full size
  /// and going back to Note or Chat restores the split.
  final split = ValueNotifier<bool>(false);

  /// Set by the home screen from its width.
  bool splitAvailable = true;

  bool get splitActive => split.value && splitAvailable && isNoteOrChat(view.value);

  static bool isNoteOrChat(HomeView v) => v == HomeView.note || v == HomeView.chat;

  void showView(HomeView v) {
    if (v == HomeView.terminal) c.terminals.ensureTab();
    if (v != view.value) previousView = view.value;
    view.value = v;
  }

  /// Leaves Settings for the tab shown before it.
  void closeSettings() {
    if (view.value != HomeView.settings) return;
    showView(previousView == HomeView.settings ? HomeView.note : previousView);
  }

  /// "note", "chat", "terminal", "settings", "split" / "side by side", "single".
  String showViewNamed(String name) {
    final n = name.trim().toLowerCase();
    if (RegExp(r'setting|preference|option|config').hasMatch(n)) {
      showView(HomeView.settings);
      return HomeView.settings.name;
    }
    if (RegExp(r'split|side|both').hasMatch(n)) {
      if (!splitAvailable) throw AppActionError('the window is too narrow for side by side');
      if (!isNoteOrChat(view.value)) showView(HomeView.note);
      split.value = true;
      return 'note and chat side by side';
    }
    if (RegExp(r'single|one|unsplit').hasMatch(n)) {
      split.value = false;
      return 'single view';
    }
    final v = n.contains('term') || n.contains('shell') || n.contains('console')
        ? HomeView.terminal
        : n.contains('chat') || n.contains('conversation') || n.contains('message')
        ? HomeView.chat
        : n.contains('note')
        ? HomeView.note
        : throw AppActionError('unknown view "$name" (note, chat, terminal, settings, split)');
    showView(v);
    return v.name;
  }

  void toggleSplit() {
    if (!splitAvailable) return;
    if (!split.value && !isNoteOrChat(view.value)) showView(HomeView.note);
    split.value = !split.value;
  }

  // ------------------------------------------------------------------ notes

  Future<void> newNote() => c.newConversation();

  Future<List<ConversationSummary>> listNotes() => c.listConversations();

  Future<void> openNote(String id) => c.openConversation(id);

  /// Deletes a note by id without asking (the UI confirms itself).
  Future<void> deleteNoteById(String id) => c.deleteConversation(id);

  /// Finds a note by (part of) its title, "previous" / "last" (the most
  /// recent other one), or a 1-based position in the list.
  Future<ConversationSummary> findNote(String query) async {
    final all = await c.listConversations();
    final q = query.trim().toLowerCase();
    final current = c.pipeline.conversation.id;
    if (all.isEmpty) throw AppActionError('there are no notes');
    if (RegExp(r'^(previous|last|other|recent)').hasMatch(q)) {
      final other = all.where((s) => s.id != current).firstOrNull;
      if (other == null) throw AppActionError('there is no other note');
      return other;
    }
    if (q.isEmpty || q == 'this' || q == 'current') {
      return all.firstWhere((s) => s.id == current, orElse: () => throw AppActionError('this note is not saved yet'));
    }
    final n = int.tryParse(q);
    if (n != null && n >= 1 && n <= all.length) return all[n - 1];
    final exact = all.where((s) => s.title.toLowerCase() == q).firstOrNull;
    if (exact != null) return exact;
    final part = all.where((s) => s.title.toLowerCase().contains(q)).toList();
    if (part.isNotEmpty) return part.first;
    final words = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
    final fuzzy = all.where((s) => words.any((w) => s.title.toLowerCase().contains(w))).firstOrNull;
    if (fuzzy != null) return fuzzy;
    throw AppActionError('no note matching "$query"');
  }

  Future<String> switchNote(String query) async {
    final s = await findNote(query);
    await c.openConversation(s.id);
    return s.title;
  }

  Future<String> renameNote(String title, {String? which}) async {
    final t = title.trim();
    if (t.isEmpty) throw AppActionError('rename needs a title');
    final id = which == null || which.trim().isEmpty ? c.pipeline.conversation.id : (await findNote(which)).id;
    await c.renameConversation(id, t);
    return t;
  }

  /// Deletes a note and its conversation. [confirm] (voice) asks first with
  /// an approval card without countdown.
  Future<String> deleteNote({String? which, bool confirm = true}) async {
    final current = c.pipeline.conversation;
    final ConversationSummary? s = which == null || which.trim().isEmpty ? null : await findNote(which);
    final id = s?.id ?? current.id;
    final title = s?.title ?? (current.title.isEmpty ? 'this note' : current.title);
    if (confirm) {
      final text = id == current.id ? c.notes.text : '';
      final ok = await c.review.review(
        PendingEdit(
          target: EditTarget.note,
          title: 'Delete "$title"',
          oldText: text,
          newText: '',
          summary: 'delete the note and its conversation',
          requireApproval: true,
        ),
      );
      if (!ok) throw AppActionError('the user kept the note');
    }
    await c.deleteConversation(id);
    return title;
  }

  void noteUndo() => c.notes.undo();
  void noteRedo() => c.notes.redo();

  /// AI text edit of the note: preview card, countdown, then apply.
  Future<String> editNote(NoteEditResult r) async {
    final notes = c.notes;
    if (r.text == notes.text) return 'no change';
    final convId = notes.conversationId;
    if (!await reviewNoteEdit(notes, c.review, r.text, summary: r.summary)) {
      throw AppActionError('the user rejected the note edit');
    }
    if (notes.conversationId != convId) throw AppActionError('the note changed meanwhile');
    notes.applyResult(r);
    c.editHistory.record(AppliedNoteEdit(convId, r.summary, revisionAfter: notes.revision));
    return r.summary;
  }

  Future<String> appendToNote(String text) => _edit(() => applyNoteEdit(c.notes.text, NoteEditMode.append, text: text));
  Future<String> insertInNote(String text, {String? after, String? before}) =>
      _edit(() => insertNoteText(c.notes.text, text, after: after, before: before));
  Future<String> replaceInNote(String find, String text, {bool all = false}) =>
      _edit(() => replaceNoteText(c.notes.text, find, text, all: all));
  Future<String> deleteFromNote(String find) => _edit(() => deleteNoteText(c.notes.text, find));

  Future<String> _edit(NoteEditResult Function() compute) {
    final NoteEditResult r;
    try {
      r = compute();
    } on NoteEditException catch (e) {
      throw AppActionError(e.message);
    }
    return editNote(r);
  }

  // ------------------------------------------------------------------ edits

  /// Applies the edit shown in the preview card now.
  bool applyPendingEdit() => c.review.apply();

  /// Rejects the edit shown in the preview card.
  bool rejectPendingEdit() => c.review.reject();

  /// "Undo that": a pending edit is rejected; otherwise the last applied AI
  /// edit (note or file) of this conversation is reverted.
  Future<String> undoLastEdit() async {
    if (c.review.reject()) return 'rejected the pending edit';
    final r = await c.editHistory.undoLast();
    if (r == null) throw AppActionError('nothing to undo');
    return r;
  }

  // --------------------------------------------------------------- settings

  Future<void> updateSettings(AppSettings next) => c.updateSettings(next);
  Future<void> setMicMode(MicMode m) => c.setMicMode(m);
  Future<void> setTheme(AppTheme t) => c.updateSettings(c.settings.copyWith(theme: t));

  /// Settings by voice. Session-level changes (voice, model) reconnect after
  /// a short delay so the current reply is not cut off.
  Future<String> setSetting(String key, String value) async {
    final s = c.settings;
    final k = key.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    final v = value.trim();
    final lv = v.toLowerCase();
    AppSettings next;
    String done;
    switch (k) {
      case 'theme' || 'color_theme' || 'appearance':
        final t = AppTheme.values.where((t) => lv.contains(t.name)).firstOrNull ??
            (lv.contains('night') ? AppTheme.dark : (lv.contains('day') ? AppTheme.light : null));
        if (t == null) throw AppActionError('theme must be light, dark or system');
        next = s.copyWith(theme: t);
        done = 'theme ${t.name}';
      case 'mic_mode' || 'mic' || 'microphone':
        final m = lv.contains('push') || lv.contains('ptt')
            ? MicMode.pushToTalk
            : lv.contains('mute') || lv == 'off'
            ? MicMode.muted
            : lv.contains('hands') || lv.contains('free') || lv == 'on' || lv.contains('unmute') || lv.contains('open')
            ? MicMode.handsFree
            : throw AppActionError('mic mode must be hands_free, push_to_talk or muted');
        next = s.copyWith(micMode: m);
        done = 'mic ${m.label}';
      case 'voice':
        final choice = s.voiceChoices.where((x) => x == lv).firstOrNull ??
            s.voiceChoices.where((x) => lv.contains(x)).firstOrNull;
        if (choice == null) throw AppActionError('unknown voice "$v"; choices: ${s.voiceChoices.join(', ')}');
        next = s.backendMode == BackendMode.gptLive ? s.copyWith(liveVoice: choice) : s.copyWith(voice: choice);
        done = 'voice $choice';
      case 'voice_model' || 'model':
        final norm = lv.replaceAll(' ', '-');
        final live = kVoiceModels.where((x) => x == norm).firstOrNull;
        final rt = kRealtimeModels.where((x) => x == norm).firstOrNull;
        if (live != null) {
          next = s.copyWith(voiceModel: live);
        } else if (rt != null) {
          next = s.copyWith(realtimeModel: rt);
        } else {
          throw AppActionError('unknown voice model "$v"; choices: ${[...kVoiceModels, ...kRealtimeModels].join(', ')}');
        }
        done = 'voice model ${live ?? rt}';
      case 'compaction_threshold' || 'compression_threshold' || 'compaction':
        final m = RegExp(r'([\d.]+)\s*(k|thousand)?').firstMatch(lv);
        if (m == null) throw AppActionError('compaction threshold needs a number of tokens');
        final n = (double.parse(m[1]!) * (m[2] != null ? 1000 : 1)).round().clamp(1000, 1000000);
        next = s.copyWith(compressionThreshold: n);
        done = 'compaction at $n tokens';
      case 'run_in_terminal' || 'run_bash_in_terminal' || 'terminal':
        final on = RegExp(r'^(on|true|yes|enable|enabled|1)$').hasMatch(lv);
        final off = RegExp(r'^(off|false|no|disable|disabled|0)$').hasMatch(lv);
        if (!on && !off) throw AppActionError('run_in_terminal must be on or off');
        next = s.copyWith(runBashInTerminal: on);
        done = 'run commands in terminal ${on ? 'on' : 'off'}';
      case 'edit_apply_delay' || 'auto_apply' || 'edit_delay':
        final d = RegExp(r'approv|ask|never|manual|off').hasMatch(lv)
            ? kRequireApproval
            : int.tryParse(RegExp(r'\d+').firstMatch(lv)?[0] ?? '');
        if (d == null || !kEditApplyDelays.contains(d)) {
          throw AppActionError('edit apply delay must be 0, 3, 5, 10 seconds or approval');
        }
        next = s.copyWith(editApplyDelay: d);
        done = d == kRequireApproval ? 'edits need approval' : 'edits apply after $d s';
      default:
        throw AppActionError(
          'unknown setting "$key" (theme, mic_mode, voice, voice_model, compaction_threshold, run_in_terminal, edit_apply_delay)',
        );
    }
    if (s.sessionDiffers(next)) {
      // Reconnecting now would cut off the reply to this very request.
      Timer(reconnectDelay, () => unawaited(c.updateSettings(next)));
      return '$done (reconnecting)';
    }
    await c.updateSettings(next);
    return done;
  }

  @visibleForTesting
  Duration reconnectDelay = const Duration(seconds: 4);

  // --------------------------------------------------------------- terminal

  TerminalHub get terminals => c.terminals;

  TerminalSession newTerminalTab() {
    final s = terminals.newShell();
    showView(HomeView.terminal);
    return s;
  }

  void closeTerminalTab(TerminalSession s) => terminals.close(s);

  void selectTerminalTab(int index) => terminals.select(index);

  void renameTerminalTab(TerminalSession s, String title) => s.rename(title);

  /// Tab by 1-based number, title, "current"/"last", or null = active.
  TerminalSession findTab(String? which) {
    final all = terminals.sessions;
    if (all.isEmpty) throw AppActionError('no terminal tabs are open');
    final q = (which ?? '').trim().toLowerCase();
    if (q.isEmpty || q == 'current' || q == 'this' || q == 'active') return terminals.active!;
    if (q == 'last' || q == 'newest') return all.last;
    final n = int.tryParse(RegExp(r'\d+').firstMatch(q)?[0] ?? '');
    if (n != null && n >= 1 && n <= all.length && !q.contains('shell')) return all[n - 1];
    final byTitle = all.where((s) => s.title.toLowerCase() == q || s.title.toLowerCase().contains(q)).firstOrNull;
    if (byTitle != null) return byTitle;
    if (n != null && n >= 1 && n <= all.length) return all[n - 1];
    throw AppActionError('no terminal tab "$which"');
  }

  /// Types [command] + Enter into a shell tab (a new one when [tab] is
  /// "new" or no shell tab exists). Asks first when bash needs approval.
  Future<String> runInTerminalTab(String command, {String? tab}) async {
    final cmd = command.trim();
    if (cmd.isEmpty) throw AppActionError('empty command');
    if (c.settings.confirmBeforeBash && !await c.confirmations.confirmCommand(cmd)) {
      throw AppActionError('the user rejected the command');
    }
    TerminalSession s;
    if (tab != null && tab.trim().toLowerCase() == 'new') {
      s = terminals.newShell();
    } else {
      final shells = terminals.sessions.where((x) => x.kind == TerminalKind.shell);
      s = tab == null || tab.trim().isEmpty
          ? (terminals.active?.kind == TerminalKind.shell ? terminals.active! : (shells.firstOrNull ?? terminals.newShell()))
          : findTab(tab);
    }
    if (s.kind != TerminalKind.shell) throw AppActionError('"${s.title}" is not a shell tab');
    terminals.select(terminals.sessions.indexOf(s));
    showView(HomeView.terminal);
    s.typeCommand(cmd);
    return s.title;
  }

  // ----------------------------------------------------------------- viewer

  Future<String> openInViewer(String path) async {
    final full = c.platform.files.resolveExisting(path);
    if (!await File(full).exists()) throw AppActionError('file not found: $full');
    await c.platform.viewer.show(MediaItem(kind: MediaItem.kindForPath(full), path: full));
    return full;
  }

  Future<void> viewerCommand(ViewerCommand cmd, {double seconds = 0}) async {
    final ok = await c.platform.viewer.control(cmd, seconds: seconds);
    if (!ok) {
      throw AppActionError(
        cmd == ViewerCommand.close ? 'no viewer is open' : 'no video is playing in the viewer',
      );
    }
  }
}
