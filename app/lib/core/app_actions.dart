import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/media_viewer.dart';
import '../tools/note_tools.dart';
import 'app_controller.dart';
import 'edits/edit_review.dart';
import 'notes/note_copy.dart';
import 'notes/note_ops.dart';
import 'notes/note_text_ops.dart';
import 'pipeline/turn_pipeline.dart';
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

  /// A new empty note (the current one if it is still empty), optionally
  /// titled at once ("new note called Ideas"). Returns its title.
  Future<String> newNote({String? title}) async {
    await c.newConversation();
    final t = title?.trim() ?? '';
    if (t.isEmpty) return 'new note';
    await c.renameConversation(c.pipeline.conversation.id, t);
    return t;
  }

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

  /// Clears this conversation's chat messages and context summary; the note
  /// and the title stay. [confirm] asks first with an approval card.
  Future<String> clearChat({bool confirm = true}) async {
    final old = c.pipeline.conversation;
    if (old.messages.isEmpty && (old.summary ?? '').isEmpty) return 'the chat is already empty';
    final n = old.messages.length;
    if (confirm) {
      final ok = await c.review.review(
        PendingEdit(
          target: EditTarget.note,
          title: 'Clear the chat',
          oldText: '$n messages',
          newText: '',
          summary: 'clear the chat history (the note stays)',
          requireApproval: true,
        ),
      );
      if (!ok) throw AppActionError('the user kept the chat');
    }
    final text = c.notes.text;
    await c.deleteConversation(old.id);
    if (text.isNotEmpty) c.notes.setText(text);
    if (old.customTitle) await c.renameConversation(c.pipeline.conversation.id, old.title);
    return 'cleared $n messages';
  }

  /// "Compact the context now": summarizes older turns in the background.
  String compactContext() {
    final m = c.contextManager;
    if (m.compressing) return 'already compacting';
    if (c.pipeline.conversation.messages.isEmpty) throw AppActionError('nothing to compact yet');
    c.compactNow();
    return 'compacting the context in the background';
  }

  // ------------------------------------------------------------- connection

  /// Waited before checking whether the reply is still playing, and the
  /// longest wait for it to finish (voice disconnect / reconnect).
  @visibleForTesting
  Duration replyStartGrace = const Duration(milliseconds: 1500);
  @visibleForTesting
  Duration replyMaxWait = const Duration(seconds: 20);
  @visibleForTesting
  Duration replyPoll = const Duration(milliseconds: 200);

  /// Runs [f] once Woi has finished speaking its confirmation, so a voice
  /// "disconnect" does not cut off its own audio.
  Future<void> afterReply(Future<void> Function() f) async {
    await Future<void>.delayed(replyStartGrace);
    final until = DateTime.now().add(replyMaxWait);
    bool busy() => switch (c.pipeline.phase) {
      AssistantPhase.speaking || AssistantPhase.thinking || AssistantPhase.toolRunning => true,
      _ => false,
    };
    while (busy() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(replyPoll);
    }
    await f();
  }

  /// Ends the voice session after the spoken confirmation. It stays offline
  /// (no auto reconnect) until the user clicks Retry on the status chip.
  String disconnect() {
    if (c.pipeline.status == SessionStatus.disconnected) throw AppActionError('already disconnected');
    unawaited(afterReply(() => c.pipeline.suspend()));
    return 'disconnecting after this reply';
  }

  /// A fresh voice session (after the confirmation), e.g. when it glitches.
  String reconnect() {
    unawaited(afterReply(() => c.pipeline.connect()));
    return 'reconnecting after this reply';
  }

  /// Writes the system clipboard (tests swap it out).
  @visibleForTesting
  Future<void> Function(String text) writeClipboard = (t) => Clipboard.setData(ClipboardData(text: t));

  /// Last copy (label for the "Copied" confirmation); the editor listens.
  final copied = ValueNotifier<({String label, int seq})?>(null);
  int _copySeq = 0;

  /// Copies the note, or the line / paragraph / H1 section at [cursor]
  /// (default: the editor's last cursor). Returns the confirmation label.
  Future<String> copyNote(NoteCopyScope scope, {int? cursor}) async {
    final n = c.notes;
    final text = noteCopyText(n.text, cursor ?? n.cursorOrEnd, scope);
    if (text.trim().isEmpty) {
      throw AppActionError(scope == NoteCopyScope.note ? 'the note is empty' : 'no ${scope.label} at the cursor');
    }
    await writeClipboard(text);
    final label = noteCopyLabel(scope, text);
    copied.value = (label: label, seq: ++_copySeq);
    return label;
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
    var reconnects = false;
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
      case 'echo_cancellation' || 'echo_cancel' || 'aec' || 'echo':
        final on = RegExp(r'^(on|true|yes|enable|enabled|1)$').hasMatch(lv);
        final off = RegExp(r'^(off|false|no|disable|disabled|0)$').hasMatch(lv);
        if (!on && !off) throw AppActionError('echo_cancellation must be on or off');
        next = s.copyWith(echoCancellation: on);
        done = 'echo cancellation ${on ? 'on' : 'off'}';
        // gpt-live's WebRTC mic applies it with a new call.
        reconnects = on != s.echoCancellation && c.pipeline.backendManagesAudio;
      case 'audio_route' || 'android_audio_route' || 'audio_channel' || 'route':
        final r = RegExp(r'phone|call|communication|voice').hasMatch(lv)
            ? AndroidAudioRoute.phone
            : RegExp(r'media|music|speaker').hasMatch(lv)
            ? AndroidAudioRoute.media
            : null;
        if (r == null) throw AppActionError('audio_route must be phone or media');
        next = s.copyWith(androidAudioRoute: r);
        done = 'Android audio route ${r.name}';
      case 'stop_word_detection' || 'stop_word' || 'kws' || 'keyword_spotting':
        final on = RegExp(r'^(on|true|yes|enable|enabled|1)$').hasMatch(lv);
        final off = RegExp(r'^(off|false|no|disable|disabled|0)$').hasMatch(lv);
        if (!on && !off) throw AppActionError('stop_word_detection must be on or off');
        next = s.copyWith(stopWordDetection: on);
        done = 'stop word detection ${on ? 'on' : 'off'}';
      case 'stop_words' || 'stopwords' || 'keywords':
        final words = RegExp(r'^(default|reset)$').hasMatch(lv) ? const ['stop'] : parseStopWords(v);
        if (words.isEmpty) throw AppActionError('stop_words needs at least one word');
        next = s.copyWith(stopWords: words);
        done = 'stop words ${words.join(', ')}';
      case 'edit_apply_delay' || 'auto_apply' || 'edit_delay':
        final d = RegExp(r'approv|ask|never|manual|off').hasMatch(lv)
            ? kRequireApproval
            : int.tryParse(RegExp(r'\d+').firstMatch(lv)?[0] ?? '');
        if (d == null || !kEditApplyDelays.contains(d)) {
          throw AppActionError('edit apply delay must be 0, 3, 5, 10 seconds or approval');
        }
        next = s.copyWith(editApplyDelay: d);
        done = d == kRequireApproval ? 'edits need approval' : 'edits apply after $d s';
      case 'usage_guard' || 'usage_guard_percent' || 'usage_threshold':
        final n = int.tryParse(RegExp(r'\d+').firstMatch(lv)?[0] ?? (RegExp(r'off|never').hasMatch(lv) ? '0' : ''));
        if (n == null || n > 100) throw AppActionError('usage guard must be a percent (0 = off)');
        next = s.copyWith(usageGuardPercent: n);
        done = n == 0 ? 'usage guard off' : 'background work uses gpt-6-luna below $n% usage left';
      case 'auto_screenshot' || 'screenshots' || 'screenshot':
        final on = _onOff(lv, 'auto_screenshot');
        next = s.copyWith(autoScreenshot: on);
        done = 'auto screenshot ${on ? 'on' : 'off'}';
      case 'screenshot_delay':
        final m = RegExp(r'[\d.]+').firstMatch(lv);
        if (m == null) throw AppActionError('screenshot delay needs seconds');
        var secs = double.parse(m[0]!);
        if (lv.contains('ms') || secs > 10) secs /= 1000;
        final ms = (secs * 1000).round().clamp(0, 4000);
        next = s.copyWith(screenshotDelayMs: ms);
        done = 'screenshot delay ${(ms / 1000).toStringAsFixed(1)} s';
      case 'reply_delay' || 'end_of_turn_silence' || 'turn_silence':
        final m = RegExp(r'[\d.]+').firstMatch(lv);
        if (m == null) throw AppActionError('reply delay needs seconds');
        var secs = double.parse(m[0]!);
        if (lv.contains('ms') || secs > 10) secs /= 1000;
        final ms = (secs * 1000).round().clamp(kMinReplyDelayMs, kMaxReplyDelayMs);
        next = s.copyWith(replyDelayMs: ms);
        done = 'reply delay ${(ms / 1000).toStringAsFixed(1)} s';
      case 'idle_standby' || 'standby' || 'idle_disconnect':
        final secs = _standbySeconds(lv);
        next = s.copyWith(idleStandbySeconds: secs);
        done = secs == 0 ? 'idle standby off' : 'idle standby after $secs s';
      case 'camera_replaces_screenshot' || 'camera_replaces':
        final on = _onOff(lv, 'camera_replaces_screenshot');
        next = s.copyWith(cameraReplacesScreenshot: on);
        done = on ? 'camera replaces the screenshot' : 'camera adds to the screenshot';
      case 'thinking_chime' || 'chime' || 'thinking_earcon' || 'earcon':
        final on = _onOff(lv, 'thinking_chime');
        next = s.copyWith(thinkingEarcon: on);
        done = 'thinking chime ${on ? 'on' : 'off'}';
      case 'confirm_commands' || 'confirm_shell_commands' || 'confirm_before_bash' || 'confirm_bash':
        final on = _onOff(lv, 'confirm_commands');
        next = s.copyWith(confirmBeforeBash: on);
        done = on ? 'shell commands need approval' : 'shell commands run without asking';
      case 'fallback_to_direct' || 'direct_fallback' || 'fallback':
        final on = _onOff(lv, 'fallback_to_direct');
        next = s.copyWith(fallbackToDirectOnLimit: on);
        done = 'Direct realtime fallback at the usage limit ${on ? 'on' : 'off'}';
      case 'backend' || 'backend_mode' || 'connection':
        final b = lv.contains('live')
            ? BackendMode.gptLive
            : lv.contains('direct') || lv.contains('realtime')
            ? BackendMode.direct
            : lv.contains('api') || lv.contains('key')
            ? BackendMode.apiKey
            : throw AppActionError('backend must be gpt_live, direct or api_key');
        next = s.copyWith(backendMode: b);
        done = 'backend ${b.label}';
      case 'compression_model' || 'compaction_model' || 'delegate_model' || 'delegation_model':
        final m = lv.contains('luna') ? 'gpt-6-luna' : (lv.contains('sol') ? 'gpt-6.1-sol' : null);
        if (m == null) throw AppActionError('model must be gpt-6-luna or gpt-6.1-sol');
        final del = k.startsWith('deleg');
        next = del ? s.copyWith(delegateModel: m) : s.copyWith(compressionModel: m);
        done = '${del ? 'delegate' : 'compression'} model $m';
      case 'chat_pane' || 'chat_pane_fraction' || 'chat_width' || 'pane_split':
        final m = RegExp(r'[\d.]+').firstMatch(lv);
        final f = lv.contains('default') || lv.contains('reset')
            ? kDefaultChatPaneFraction
            : m == null
            ? throw AppActionError('chat pane needs a percent of the width (25 to 60) or "default"')
            : (double.parse(m[0]!) > 1 ? double.parse(m[0]!) / 100 : double.parse(m[0]!));
        final cl = f.clamp(kChatPaneMinFraction, kChatPaneMaxFraction).toDouble();
        next = s.copyWith(chatPaneFraction: cl);
        done = 'chat pane ${(cl * 100).round()}% of the width';
      case 'workspace' || 'workspace_dir' || 'workspace_folder':
        final dir = RegExp(r'^(default|none|reset|empty)$').hasMatch(lv) ? '' : v;
        if (dir.isNotEmpty && !Directory(dir.replaceFirst(RegExp(r'^~'), Platform.environment['HOME'] ?? '~')).existsSync()) {
          throw AppActionError('folder not found: $dir');
        }
        next = s.copyWith(workspaceDir: dir);
        done = dir.isEmpty ? 'workspace is the default folder' : 'workspace $dir';
      default:
        throw AppActionError(
          'unknown setting "$key" (theme, mic_mode, voice, voice_model, compaction_threshold, run_in_terminal, '
          'edit_apply_delay, echo_cancellation, audio_route, stop_word_detection, stop_words, usage_guard, auto_screenshot, screenshot_delay, reply_delay, idle_standby, '
          'camera_replaces_screenshot, thinking_chime, confirm_commands, fallback_to_direct, backend, '
          'compression_model, delegate_model, chat_pane, workspace)',
        );
    }
    if (reconnects || s.sessionDiffers(next)) {
      // Reconnecting now would cut off the reply to this very request.
      Timer(reconnectDelay, () => unawaited(c.updateSettings(next)));
      return '$done (reconnecting)';
    }
    await c.updateSettings(next);
    return done;
  }

  static final _on = RegExp(r'^(on|true|yes|enable|enabled|1)$');
  static final _off = RegExp(r'^(off|false|no|disable|disabled|0)$');

  static bool _onOff(String lv, String name) {
    if (_on.hasMatch(lv)) return true;
    if (_off.hasMatch(lv)) return false;
    throw AppActionError('$name must be on or off');
  }

  /// "off" / "on" (the default) / "90" / "2 min" / "90s" -> seconds.
  static int _standbySeconds(String lv) {
    if (_off.hasMatch(lv) || lv == 'never') return 0;
    final m = RegExp(r'[\d.]+').firstMatch(lv);
    if (m == null) {
      if (_on.hasMatch(lv)) return kDefaultIdleStandbySeconds;
      throw AppActionError('idle standby needs seconds or off');
    }
    var secs = double.parse(m[0]!);
    if (RegExp(r'\bmin').hasMatch(lv) || lv.endsWith('m')) secs *= 60;
    return secs.round().clamp(0, kMaxIdleStandbySeconds);
  }

  @visibleForTesting
  Duration reconnectDelay = const Duration(seconds: 4);

  /// "How much usage do I have left": the ChatGPT plan's 5-hour and weekly
  /// windows (refetched when older than a minute; the endpoint is free) and
  /// the models background work actually uses.
  Future<Map<String, Object?>> usageStatus() async {
    final u = c.usage;
    final s0 = u.snapshot;
    if (s0 == null || DateTime.now().difference(s0.updatedAt) > const Duration(minutes: 1)) await u.refresh();
    final s = u.snapshot;
    if (s == null) {
      throw AppActionError(
        u.error != null ? 'usage unavailable: ${u.error}' : 'usage is only available with a ChatGPT login',
      );
    }
    final comp = c.compactionChoice, del = c.delegationChoice;
    return {
      'summary': s.describe(),
      ...s.toJson(),
      'delegation_model': del.model,
      'compaction_model': comp.model,
      'model_note': ?(del.reason ?? comp.reason),
    };
  }

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

  /// Selects a terminal tab and shows the Terminal view. Returns its title.
  String switchTerminalTab(String? which) {
    final s = findTab(which);
    terminals.select(terminals.sessions.indexOf(s));
    showView(HomeView.terminal);
    return s.title;
  }

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
