import '../core/notes/note_controller.dart';
import '../core/notes/note_ops.dart';
import '../core/voice/voice_backend.dart';
import 'tool_registry.dart';

/// `read_note` and `update_note`: the assistant's access to the
/// conversation note. No confirmation (unlike files); every edit is undoable
/// and highlighted in the editor.
List<ToolDefinition> noteTools(NoteController notes) => [
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
          'Edit the conversation\'s Markdown note (no confirmation needed; the user can undo). '
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
        final r = notes.applyEdit(
          mode,
          text: args.str('text'),
          heading: args.strOrNull('heading'),
          item: args.strOrNull('item'),
          checked: args.boolean('checked', true),
        );
        return {'ok': true, 'mode': mode.wire, 'done': r.summary, 'words': notes.wordCount};
      } on NoteEditException catch (e) {
        throw ToolFailure(e.message);
      }
    },
  ),
];
