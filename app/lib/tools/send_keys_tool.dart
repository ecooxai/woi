import '../core/voice/voice_backend.dart';
import '../platform/input_control.dart';
import 'tool_registry.dart';

/// `send_keys`: key presses into another app's window (replaces key_combo).
ToolDefinition sendKeysTool(InputControl input) => ToolDefinition(
  spec: const ToolSpec(
    name: 'send_keys',
    description:
        'Press keys in another app (never in Woi). Default target: the app the user was '
        'using (active non-Woi window). Use `action` for edit intents, mapped per app '
        '(e.g. copy in a terminal = ctrl+shift+c), or `keys` for explicit chords: '
        '"ctrl+c", "esc", "enter", "alt+tab", or a sequence "ctrl+a ctrl+c".',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['copy', 'paste', 'cut', 'select_all', 'undo', 'redo', 'escape', 'enter', 'back'],
          'description': 'Edit intent (use keys for several presses in order).',
        },
        'keys': {'type': 'string', 'description': 'Chords separated by spaces, keys joined by +.'},
        'window': {'type': 'string', 'description': 'Optional window title or class to target, e.g. "xterm", "firefox".'},
      },
    },
  ),
  handler: (args, call) async {
    final keys = args.strOrNull('keys');
    final actionName = args.strOrNull('action');
    final action = KeyAction.parse(actionName);
    if (actionName != null && action == null && keys == null) throw ToolFailure('unknown action "$actionName"');
    if ((keys == null || keys.trim().isEmpty) && action == null) throw ToolFailure('give keys or action');
    try {
      final r = await input.sendKeys(
        keys: (keys == null || keys.trim().isEmpty) ? null : keys,
        action: (keys == null || keys.trim().isEmpty) ? action : null,
        target: KeyTarget(window: args.strOrNull('window')),
      );
      return {'ok': true, ...r.toJson()};
    } on FormatException catch (e) {
      throw ToolFailure('bad keys: ${e.message}');
    } on StateError catch (e) {
      throw ToolFailure(e.message);
    }
  },
);
