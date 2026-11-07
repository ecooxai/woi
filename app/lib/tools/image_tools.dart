import '../core/voice/voice_backend.dart' show ToolSpec;
import 'tool_registry.dart';

ToolDefinition imageGenerationTool({
  required Future<Map<String, Object?>> Function(String prompt, String size)
  generate,
}) => ToolDefinition(
  spec: const ToolSpec(
    name: 'generate_image',
    description:
        'Generate or draw a new image from a detailed prompt using the image model and quality '
        'selected in Settings. Starts in the background and returns queued immediately; the image is '
        'posted to the original chat after completion. Do not report queued work as finished, and do '
        'not repeat the call for the same request. This tool creates one image per call.',
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'Complete visual description, 1–32,000 characters.',
        },
        'size': {
          'type': 'string',
          'enum': ['auto', '1024x1024', '1536x1024', '1024x1536'],
          'description': 'Image dimensions, auto by default.',
        },
      },
      'required': ['prompt'],
      'additionalProperties': false,
    },
  ),
  handler: (args, call) =>
      generate(args.str('prompt'), args.str('size', 'auto')),
);
