import '../core/edits/edit_review.dart';
import '../core/models/message.dart';
import '../core/notes/note_controller.dart';
import '../core/notes/note_ops.dart';
import '../core/voice/voice_backend.dart';
import 'tool_registry.dart';

/// Shows a note edit as a diff card (auto-applies after the countdown) and
/// records it for "undo that". Returns false when the user rejected it.
Future<bool> reviewNoteEdit(
  NoteController notes,
  EditReview? review,
  String newText, {
  required String summary,
  ToolInvocation? call,
  bool requireApproval = false,
}) async {
  if (review == null) return true;
  call?.onStatus?.call(ToolStatus.awaitingApproval);
  final ok = await review.review(
    PendingEdit(
      target: EditTarget.note,
      title: 'Note',
      oldText: notes.text,
      newText: newText,
      summary: summary,
      requireApproval: requireApproval,
    ),
  );
  call?.onStatus?.call(ToolStatus.running);
  return ok;
}

/// `read_note` and `update_note`: the assistant's access to the
/// conversation note. With [review], edits show as an inline diff that
/// applies itself after a short countdown unless rejected; every edit is
/// undoable and highlighted in the editor.
List<ToolDefinition> noteTools(NoteController notes, {EditReview? review, EditHistory? history}) => [
  ToolDefinition(
    spec: const ToolSpec(
      name: 'read_note',
      description: 'Read the full Markdown note of this conversation (it is also pinned in your context).',
      parameters: {'type': 'object', 'properties': {}, 'required': [], 'additionalProperties': false},
    ),
    handler: (args, call) async => {
      'ok': true,
      'markdown': notes.text,
      'words': notes.wordCount,
      if (notes.isEmpty) 'empty': true,
    },
  ),
  ToolDefinition(
    spec: ToolSpec(
      name: 'update_note',
      description:
          'Edit the conversation\'s Markdown note (shown as a diff that applies itself after a few seconds '
          'unless the user rejects it; undoable). '
          'Record decisions, todos ("- [ ] task"), facts, names, dates and file paths proactively. '
          'mode: append (add text at the end), replace_section (replace the body under "heading"; '
          'creates the section if missing), replace_all (rewrite the whole note), check_item (tick off '
          'the checklist item matching "item"; checked=false unticks).',
      parameters: {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': [for (final m in NoteEditMode.values) m.wire],
          },
          'text': {'type': 'string', 'description': 'Markdown to add or the new content'},
          'heading': {'type': 'string', 'description': 'Section heading for replace_section'},
          'item': {'type': 'string', 'description': 'Checklist item text for check_item'},
          'checked': {'type': 'boolean'},
        },
        'required': ['mode'],
        'additionalProperties': false,
      },
    ),
    handler: (args, call) async {
      final mode = NoteEditMode.parse(args.strOrNull('mode'));
      if (mode == null) throw ToolFailure('unknown mode');
      try {
        final preview = applyNoteEdit(
          notes.text,
          mode,
          text: args.str('text'),
          heading: args.strOrNull('heading'),
          item: args.strOrNull('item'),
          checked: args.boolean('checked', true),
        );
        if (preview.text == notes.text) return {'ok': true, 'mode': mode.wire, 'done': 'no change'};
        if (!await reviewNoteEdit(notes, review, preview.text, summary: preview.summary, call: call)) {
          throw ToolDenied('the user rejected the note edit');
        }
        final r = notes.applyEdit(
          mode,
          text: args.str('text'),
          heading: args.strOrNull('heading'),
          item: args.strOrNull('item'),
          checked: args.boolean('checked', true),
        );
        history?.record(AppliedNoteEdit(notes.conversationId, r.summary, revisionAfter: notes.revision));
        return {'ok': true, 'mode': mode.wire, 'done': r.summary, 'words': notes.wordCount};
      } on NoteEditException catch (e) {
        throw ToolFailure(e.message);
      }
    },
  ),
];
