import '../core/voice/voice_backend.dart' show ToolSpec;
import 'tool_registry.dart';

ToolDefinition imageGenerationTool({
  required Future<Map<String, Object?>> Function(
    String prompt,
    String? size,
    String action,
    String? sourceMessageId,
  )
  generate,
}) => ToolDefinition(
  spec: const ToolSpec(
    name: 'generate_image',
    description:
        'Generate a new image or edit an existing image in this chat using the image model, quality, '
        'size and format selected in Settings. Use action edit for requested changes to an image; '
        'provide its source_message_id when known, otherwise the latest image in this chat is used. '
        'Edits send the actual source image to the image API. Starts in the background and returns '
        'queued immediately. The finished image is posted at the bottom of the original chat and '
        'added to context. Do not report queued work as finished or repeat it. One image per call.',
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'Complete visual description or editing instructions, 1–32,000 characters.',
        },
        'action': {
          'type': 'string',
          'enum': ['generate', 'edit'],
          'description':
              'generate for a new image; edit to modify an existing one.',
        },
        'source_message_id': {
          'type': 'string',
          'description': 'For edit only: the image message reference ID from this chat. Omit to edit the latest image.',
        },
        'size': {
          'type': 'string',
          'enum': ['auto', '1024x1024', '1536x1024', '1024x1536'],
          'description': 'Optional size override. Omit to use Settings (default 1024x1024).',
        },
      },
      'required': ['prompt'],
      'additionalProperties': false,
    },
  ),
  handler: (args, call) => generate(
    args.str('prompt'),
    args.containsKey('size') ? args.str('size') : null,
    args.str('action', 'generate'),
    args.containsKey('source_message_id')
        ? args.str('source_message_id')
        : null,
  ),
);
