import '../core/app_actions.dart';
import '../core/notes/note_copy.dart';
import '../core/models/message.dart';
import '../core/voice/voice_backend.dart';
import '../platform/media_viewer.dart';
import 'tool_registry.dart';

/// `note_control` and `app_control`: voice control of every app function,
/// through [AppActions] (the same code the UI buttons run).
List<ToolDefinition> appTools(AppActions actions) => [noteControlTool(actions), appControlTool(actions)];

Future<Map<String, Object?>> _guard(Future<Map<String, Object?>> Function() f) async {
  try {
    return await f();
  } on AppActionError catch (e) {
    if (e.message.startsWith('the user')) throw ToolDenied(e.message);
    throw ToolFailure(e.message);
  }
}

String _need(Map<String, Object?> a, String k, String action) {
  final v = a.strOrNull(k)?.trim();
  if (v == null || v.isEmpty) throw ToolFailure('$action needs "$k"');
  return v;
}

ToolDefinition noteControlTool(AppActions actions) => ToolDefinition(
  spec: const ToolSpec(
    name: 'note_control',
    description:
        'Control the notes (one note per conversation, shown as tabs). Text edits are previewed as a diff and '
        'apply themselves after a few seconds unless the user rejects them. Actions: '
        'append (text at the end), insert (text after the line containing "after", before "before", else at top), '
        'replace ("find" -> "text"), delete_text (remove "find"; a matching list item or line is removed whole), '
        'undo / redo (the editor\'s undo stack), new (empty note), list, switch ("name": title words, '
        '"previous", or a number), rename ("title"; "name" picks another note), delete ("name" or this note; '
        'the user confirms), copy (to the clipboard; "what": note [default], line, paragraph or section = the H1 '
        'section, all at the editor cursor: "copy this paragraph").',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['append', 'insert', 'replace', 'delete_text', 'undo', 'redo', 'new', 'list', 'switch', 'rename', 'delete', 'copy'],
        },
        'text': {'type': 'string', 'description': 'Markdown to add, or the replacement'},
        'find': {'type': 'string', 'description': 'Existing text to replace or delete'},
        'after': {'type': 'string'},
        'before': {'type': 'string'},
        'name': {'type': 'string', 'description': 'Which note (title words, "previous", number)'},
        'title': {'type': 'string', 'description': 'New title for rename'},
        'what': {
          'type': 'string',
          'enum': ['note', 'line', 'paragraph', 'section'],
          'description': 'What copy copies (at the cursor)',
        },
      },
      'required': ['action'],
    },
  ),
  handler: (args, call) => _guard(() async {
    final action = args.str('action');
    switch (action) {
      case 'append':
        return {'ok': true, 'done': await actions.appendToNote(_need(args, 'text', action))};
      case 'insert':
        return {
          'ok': true,
          'done': await actions.insertInNote(
            _need(args, 'text', action),
            after: args.strOrNull('after'),
            before: args.strOrNull('before'),
          ),
        };
      case 'replace':
        return {'ok': true, 'done': await actions.replaceInNote(_need(args, 'find', action), args.str('text'))};
      case 'delete_text':
        return {'ok': true, 'done': await actions.deleteFromNote(_need(args, 'find', action))};
      case 'undo':
        if (!actions.c.notes.canUndo) throw ToolFailure('nothing to undo in the note');
        actions.noteUndo();
        return {'ok': true};
      case 'redo':
        if (!actions.c.notes.canRedo) throw ToolFailure('nothing to redo in the note');
        actions.noteRedo();
        return {'ok': true};
      case 'new':
        await actions.newNote();
        actions.showView(HomeView.note);
        return {'ok': true};
      case 'list':
        final all = await actions.listNotes();
        final cur = actions.c.pipeline.conversation.id;
        return {
          'ok': true,
          'notes': [
            for (final (i, s) in all.take(30).indexed) {'n': i + 1, 'title': s.title, if (s.id == cur) 'current': true},
          ],
        };
      case 'switch':
        final t = await actions.switchNote(_need(args, 'name', action));
        actions.showView(HomeView.note);
        return {'ok': true, 'note': t};
      case 'rename':
        return {'ok': true, 'title': await actions.renameNote(_need(args, 'title', action), which: args.strOrNull('name'))};
      case 'delete':
        call.onStatus?.call(ToolStatus.awaitingApproval);
        final deleted = await actions.deleteNote(which: args.strOrNull('name'));
        call.onStatus?.call(ToolStatus.running);
        return {'ok': true, 'deleted': deleted};
      case 'copy':
        final what = args.strOrNull('what');
        final scope = NoteCopyScope.parse(what);
        if (scope == null) throw ToolFailure('copy "what" must be note, line, paragraph or section');
        return {'ok': true, 'done': await actions.copyNote(scope)};
      default:
        throw ToolFailure('unknown action "$action"');
    }
  }),
);

ToolDefinition appControlTool(AppActions actions) => ToolDefinition(
  spec: const ToolSpec(
    name: 'app_control',
    description:
        'Control Woi itself. show_view (view: note, chat, terminal, settings, split, single; selects that tab); '
        'set_setting (key: theme [light|dark|system], mic_mode [hands_free|push_to_talk|muted], voice, '
        'voice_model, compaction_threshold [tokens], run_in_terminal [on|off], edit_apply_delay [0|3|5|10|approval], usage_guard [percent left below which delegation/compaction use '
        'gpt-6-luna; 0 = off]; value); '
        'terminal_new; terminal_run (command typed into a shell tab; tab: number/title/"new"); terminal_close (tab); '
        'viewer_open (path), viewer_close, viewer_pause, viewer_play, viewer_seek (seconds: relative, or to=true for '
        'absolute); apply_edit / reject_edit (the pending edit preview); undo_edit ("undo that": reverts your last '
        'note or file edit); usage ("how much usage do I have left": the ChatGPT plan\'s 5-hour and weekly limits, '
        'used/left percent and reset times).',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'show_view',
            'set_setting',
            'terminal_new',
            'terminal_run',
            'terminal_close',
            'viewer_open',
            'viewer_close',
            'viewer_pause',
            'viewer_play',
            'viewer_seek',
            'apply_edit',
            'reject_edit',
            'undo_edit',
            'usage',
          ],
        },
        'view': {'type': 'string'},
        'key': {'type': 'string'},
        'value': {'type': 'string'},
        'command': {'type': 'string'},
        'tab': {'type': 'string'},
        'path': {'type': 'string'},
        'seconds': {'type': 'number'},
        'to': {'type': 'boolean'},
      },
      'required': ['action'],
    },
  ),
  handler: (args, call) => _guard(() async {
    final action = args.str('action');
    switch (action) {
      case 'show_view':
        return {'ok': true, 'view': actions.showViewNamed(_need(args, 'view', action))};
      case 'set_setting':
        return {'ok': true, 'done': await actions.setSetting(_need(args, 'key', action), _need(args, 'value', action))};
      case 'terminal_new':
        return {'ok': true, 'tab': actions.newTerminalTab().title};
      case 'terminal_run':
        if (actions.c.settings.confirmBeforeBash) call.onStatus?.call(ToolStatus.awaitingApproval);
        final tab = await actions.runInTerminalTab(_need(args, 'command', action), tab: args.strOrNull('tab'));
        call.onStatus?.call(ToolStatus.running);
        return {'ok': true, 'tab': tab, 'note': 'typed into the tab; output is visible there'};
      case 'terminal_close':
        final s = actions.findTab(args.strOrNull('tab'));
        actions.closeTerminalTab(s);
        return {'ok': true, 'closed': s.title};
      case 'viewer_open':
        return {'ok': true, 'shown': await actions.openInViewer(_need(args, 'path', action))};
      case 'viewer_close':
        await actions.viewerCommand(ViewerCommand.close);
        return {'ok': true};
      case 'viewer_pause':
        await actions.viewerCommand(ViewerCommand.pause);
        return {'ok': true};
      case 'viewer_play':
        await actions.viewerCommand(ViewerCommand.play);
        return {'ok': true};
      case 'viewer_seek':
        final secs = (args['seconds'] as num?)?.toDouble();
        if (secs == null) throw ToolFailure('viewer_seek needs "seconds"');
        await actions.viewerCommand(args.boolean('to') ? ViewerCommand.seekTo : ViewerCommand.seekBy, seconds: secs);
        return {'ok': true};
      case 'apply_edit':
        if (!actions.applyPendingEdit()) throw ToolFailure('no edit is waiting');
        return {'ok': true};
      case 'reject_edit':
        if (!actions.rejectPendingEdit()) throw ToolFailure('no edit is waiting');
        return {'ok': true};
      case 'undo_edit':
        return {'ok': true, 'done': await actions.undoLastEdit()};
      case 'usage':
        return {'ok': true, ...await actions.usageStatus()};
      default:
        throw ToolFailure('unknown action "$action"');
    }
  }),
);
