import 'dart:math';

import '../core/voice/voice_backend.dart';
import '../platform/input_control.dart';
import '../platform/screen_capture.dart';
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
        'Use scroll_screen for page scrolling when available. Do not use shell commands or another agent to control the pointer. '
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

/// Scrolling has a deterministic viewport default, so it does not need a
/// guessed click target or an image-model round trip. Optional pane anchors
/// still use the exact screenshot coordinate transform used by clicks.
ToolDefinition scrollScreenTool(ScreenScrollInput input, {required Screenshot? Function() reference}) => ToolDefinition(
  spec: const ToolSpec(
    name: 'scroll_screen',
    description:
        'Scroll the visible app or page up, down, left or right. Works in Android browsers and other apps. '
        'Direction means where to read next: down reveals later content (the finger moves upward). '
        'amount is 0.1 to 5 viewports, default 1. Optionally give x AND y inside a specific scroll pane, '
        'in pixels of the latest screenshot. Omit coordinates to use the current main viewport. '
        'auto uses supported accessibility actions and falls back to a bounded gesture when refused; '
        'gesture explicitly swipes the viewport. A dispatched result proves delivery, not that content moved '
        '(the page may be at an edge); inspect the screen if needed. Never retry after user takeover without a new request.',
    parameters: {
      'type': 'object',
      'properties': {
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'left', 'right'],
        },
        'amount': {'type': 'number', 'minimum': 0.1, 'maximum': 5, 'description': 'Viewport amounts; default 1.'},
        'x': {'type': 'integer', 'description': 'Optional pane anchor X in latest screenshot pixels; requires y.'},
        'y': {'type': 'integer', 'description': 'Optional pane anchor Y in latest screenshot pixels; requires x.'},
        'strategy': {
          'type': 'string',
          'enum': ['auto', 'gesture'],
        },
      },
      'required': ['direction'],
      'additionalProperties': false,
    },
  ),
  handler: (args, call) async {
    final direction = ScrollDirection.values.asNameMap()[args.str('direction')];
    if (direction == null) throw ToolFailure('Scroll direction must be up, down, left or right.');
    final amount = args['amount'] ?? 1;
    if (amount is! num || !amount.isFinite || amount < 0.1 || amount > 5) {
      throw ToolFailure('Scroll amount must be between 0.1 and 5 viewports.');
    }
    final strategy = args.str('strategy', 'auto');
    if (!const {'auto', 'gesture'}.contains(strategy)) throw ToolFailure('Scroll strategy must be auto or gesture.');
    final x = args['x'], y = args['y'];
    Point<int>? point;
    if (x != null || y != null) {
      final shot = reference();
      if (x is! num || y is! num || !x.isFinite || !y.isFinite || x != x.roundToDouble() || y != y.roundToDouble()) {
        throw ToolFailure('Give both integer x and y screenshot coordinates, or omit both.');
      }
      if (shot == null || shot.width <= 0 || shot.height <= 0 || shot.originalWidth <= 0 || shot.originalHeight <= 0) {
        throw ToolFailure(
          'Take a screenshot before selecting a scroll pane, or omit coordinates for the current viewport.',
        );
      }
      if (x < 0 || x >= shot.width || y < 0 || y >= shot.height) {
        throw ToolFailure('The scroll anchor is outside the latest screenshot.');
      }
      point = shot.toScreen(x, y);
    }
    final result = await input.scroll(direction: direction, amount: amount.toDouble(), at: point, strategy: strategy);
    return {
      'ok': true,
      ...result,
      if (point != null) 'screen_xy': [point.x, point.y],
    };
  },
);

/// Only a complete, unambiguous viewport request bypasses the planner. Pane
/// targets, conditions and mixed tasks retain the full model/tool path.
Map<String, Object?>? scrollAction(String request) {
  var text = request.trim().toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '').trim();
  text = text.replaceFirst(RegExp(r'^(?:(?:ok(?:ay)?|hey|woi|please|now)[\s,]+)*'), '');
  text = text.replaceFirst(RegExp(r'^(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|go\s+ahead\s+and\s+)'), '');
  text = text.replaceFirst(RegExp(r'\s+please$'), '').trim();
  final match = RegExp(
    r'^scroll(?:\s+(?:the\s+)?(?:page|screen))?\s+(up|down|left|right)'
    r'(?:\s+(?:by\s+)?(?:(a|one|two|three|four|five|half|[0-9]+(?:\.[0-9]+)?)\s+(?:a\s+)?(?:page|screen|viewport)s?|(a little|a bit)))?$',
  ).firstMatch(text);
  if (match == null) return null;
  final word = match.group(2);
  final amount = word == null
      ? (match.group(3) == null ? 1.0 : 0.25)
      : const {'a': 1.0, 'one': 1.0, 'two': 2.0, 'three': 3.0, 'four': 4.0, 'five': 5.0, 'half': 0.5}[word] ??
            double.tryParse(word);
  if (amount == null || amount < 0.1 || amount > 5) return null;
  return {'direction': match.group(1), 'amount': amount};
}
