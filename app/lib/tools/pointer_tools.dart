import '../core/voice/voice_backend.dart';
import 'tool_registry.dart';

ToolDefinition pointerControlTool({
  required bool Function() enabled,
  required Future<Map<String, Object?>> Function(String action, String request, String callId) control,
}) => ToolDefinition(
  isEnabled: enabled,
  spec: const ToolSpec(
    name: 'control_pointer',
    description:
        'Use for every requested click or pointer movement when available. '
        'Send a clear description of ONE immediate action and its visible target; do not guess coordinates. '
        'A dedicated gpt-6-luna agent sees a fresh screenshot and performs only that pointer action. '
        'Do not use shell commands or another agent to control the pointer. '
        'Wait for the result and never retry after user cancellation until a new user request.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['click', 'move'],
        },
        'request': {
          'type': 'string',
          'description': 'Self-contained pointer action, target, location, and click type when needed.',
        },
      },
      'required': ['action', 'request'],
      'additionalProperties': false,
    },
  ),
  handler: (args, call) => control(args.str('action'), args.str('request'), call.callId),
);

/// Only a single explicit pointer action can bypass the general planner.
/// Mixed tasks keep the normal planner; their click/move tools still route
/// through Luna individually, with a new screenshot for each action.
String? pointerAction(String request) {
  var text = request.trim().toLowerCase();
  text = text.replaceFirst(RegExp(r'^(?:(?:ok(?:ay)?|hey|woi|please|now)[\s,]+)*'), '');
  text = text.replaceFirst(
    RegExp(r"^(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:want|need)\s+you\s+to\s+|go\s+ahead\s+and\s+)"),
    '',
  );
  // Never discard a later action or condition to get the fast path.
  if (RegExp(r'\b(?:and\s+(?:then\s+)?|then\s+|after\s+|before\s+|if\s+|unless\s+)|;|\n').hasMatch(text)) return null;
  if (RegExp(r'^(?:(?:double|right|left|middle)[ -]?)?(?:click|tap)\b').hasMatch(text)) return 'click';
  if (RegExp(r'^(?:move|position|place|put)\s+(?:the\s+)?(?:mouse(?:\s+pointer)?|pointer|cursor)\b|^hover\b')
      .hasMatch(text)) {
    return 'move';
  }
  return null;
}
