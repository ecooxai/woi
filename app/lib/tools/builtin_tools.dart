import 'dart:io';
import 'dart:math';

import '../core/delegate/delegate_backend.dart';
import '../core/models/message.dart';
import '../core/settings/settings.dart';
import '../core/vision/click_locator.dart';
import '../core/voice/voice_backend.dart';
import '../platform/files.dart';
import '../platform/input_control.dart';
import '../platform/media_viewer.dart';
import '../platform/platform_services.dart';
import '../platform/screen_capture.dart';
import '../platform/shell.dart';
import 'confirmation.dart';
import 'python_tool.dart';
import 'tool_registry.dart';

typedef PointerToolDelegate = Future<Map<String, Object?>> Function({
  required String tool,
  required Map<String, Object?> arguments,
  required String request,
  required String callId,
  Screenshot? reference,
});

/// Shared state and dependencies for the built-in tools.
class ToolEnvironment {
  ToolEnvironment({
    required this.platform,
    required this.confirmations,
    required this.delegate,
    required this.settings,
    required this.onScreenshot,
    this.terminalShell,
    this.locator,
    this.userText,
    this.pointerDelegate,
  });

  final PlatformServices platform;

  /// Runs commands visibly in the terminal ("Run in terminal" setting).
  final Shell? terminalShell;
  final ConfirmationService confirmations;
  final DelegateBackend delegate;
  final AppSettings Function() settings;

  /// Attaches a screenshot to the conversation and sends it to the model.
  final Future<void> Function(Screenshot shot, String note) onScreenshot;

  /// Most recent screenshot the model saw: click coordinates are relative to it.
  Screenshot? lastScreenshot;

  /// Finds click_screen `target`s precisely (accessibility tree, then a
  /// vision model on a full-resolution capture); null: x/y only.
  ClickLocator? locator;

  /// The user's latest utterance ('' while its transcript is pending): a
  /// click_screen whose user asked for "the center of the screen" clicks it
  /// however the model words the target.
  String Function()? userText;

  /// Installed by the app: click and move always pass through the dedicated
  /// visual agent while the setting is enabled, including ordinary delegates.
  final PointerToolDelegate? pointerDelegate;
}

/// click_screen: what to click and how it was found.
typedef ClickPlan = ({Point<int> point, Map<String, Object?> info});

/// Resolves a click_screen call to a real screen point: [position]
/// ("center", "top_left", ...) or a [target] naming a screen position (or,
/// when the target names no element, a [userText] that does) from the [shot]
/// geometry; else [target] through [locator] (the model's x/y as the hint),
/// else x/y mapped from [shot] (the screenshot the model saw). x/y alone
/// (gpt-live delegation, mock) skip the locator.
Future<ClickPlan> planClick({
  String target = '',
  String position = '',
  String userText = '',
  int? x,
  int? y,
  Screenshot? shot,
  ClickLocator? locator,
}) async {
  final guess = x == null || y == null
      ? null
      : (shot?.toScreen(x, y) ?? Point(x, y));
  final t = target.trim();
  if (shot != null) {
    // "the center of the screen": no element to find, skip the ~2 s grounding.
    final pos = position.trim().isNotEmpty && _mayBeScreenSpot(t)
        ? screenPositionPoint(position, shot)
        : null;
    if (pos != null) {
      return (
        point: pos,
        info: const <String, Object?>{'located_by': 'position'},
      );
    }
    final abs = absoluteScreenPoint(t, shot);
    if (abs != null) {
      return (
        point: abs,
        info: const <String, Object?>{'located_by': 'absolute'},
      );
    }
    final said = _mayBeScreenSpot(t) ? userScreenPosition(userText) : null;
    final heard = said == null ? null : screenPositionPoint(said, shot);
    if (heard != null) {
      return (
        point: heard,
        info: const <String, Object?>{'located_by': 'utterance'},
      );
    }
  }
  if (t.isNotEmpty && locator != null) {
    try {
      final found = await locator.locate(t, hint: guess);
      return (point: found.point, info: found.toJson());
    } on LocateFailure catch (e) {
      if (guess == null) {
        throw ToolFailure(
          'could not find "$t" on screen (${e.reason}); give x/y or describe it differently',
        );
      }
      return (
        point: guess,
        info: {'located_by': 'model_xy', 'locate_error': e.reason},
      );
    }
  }
  if (guess == null) {
    throw ToolFailure(
      t.isEmpty ? 'give target (what to click), position or x/y' : 'give x/y',
    );
  }
  return (point: guess, info: const <String, Object?>{});
}

/// click_screen `position` values.
const screenPositions = [
  'center',
  'top_left',
  'top_right',
  'bottom_left',
  'bottom_right',
];

/// The screen point of a [screenPositions] value on the screen [shot] covers;
/// null for an unknown value or an empty capture.
Point<int>? screenPositionPoint(String position, Screenshot shot) {
  final p = position.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  if (!screenPositions.contains(p)) return null;
  final w = shot.originalWidth, h = shot.originalHeight;
  if (w <= 0 || h <= 0) return null;
  if (p == 'center') return Point(shot.originX + w ~/ 2, shot.originY + h ~/ 2);
  // Corners: a few pixels in, so the click lands on the screen (not a hot edge).
  const inset = 5;
  final top = p.startsWith('top'), left = p.endsWith('left');
  return Point(
    shot.originX + (left ? inset : w - 1 - inset),
    shot.originY + (top ? inset : h - 1 - inset),
  );
}

final _absTarget = RegExp(
  r'^(?:the\s+)?(?:exact\s+|very\s+)?(?:(center|centre|middle)|(top|upper|bottom|lower)[\s-]+(left|right)(?:\s+corner)?)'
  r'(?:\s+(?:of|on)\s+(?:the\s+|my\s+)?(?:whole\s+|entire\s+)?(?:screen|display|desktop|monitor)(?:\s+area)?)?\.?$',
);

final _elementWord = RegExp(
  r'\b(button|icon|link|tab|field|menu|dialog|window|box|label|item|image|text|input|bar|panel|pane|card|list|row|'
  r'cell|column|page|form|popup|modal|toolbar|sidebar|checkbox|slider|entry|title|heading|header|footer|file|folder|'
  r'browser|terminal|editor|document|tile|thumbnail|video|picture|photo|logo|avatar|widget|switch|toggle|option|'
  r'dropdown|scrollbar|taskbar|dock|notification|message|chat|email|tooltip|badge)(?:s|es)?\b',
);

/// Whether a click_screen target names (or quotes the label of) an element.
bool namesElement(String target) {
  final t = target.toLowerCase();
  return _elementWord.hasMatch(t) || t.contains(RegExp('["\'‘’“”]'));
}

// ", empty background area" / " on the desktop background" after the position.
final _emptyAreaTail = RegExp(
  r'[\s,;:–-]+(?:on\s+|in\s+|at\s+)?(?:the\s+)?(?:empty\s+|blank\s+|open\s+)?(?:main\s+)?(?:(?:background|desktop|wallpaper|workspace|space|spot|point|area)\s*)+\.?\s*$',
);

final _centerWord = RegExp(r'\b(?:center|centre|middle)\b');
final _cornerWords = RegExp(r'\b(top|upper|bottom|lower)[\s-]*(left|right)\b');
final _screenWord = RegExp(r'\b(?:screen|desktop|display|monitor)s?\b');

/// The [screenPositions] value of a centre/corner phrase match.
String _positionOf(String? vertical, String? horizontal) => vertical == null
    ? 'center'
    : '${vertical == 'top' || vertical == 'upper' ? 'top' : 'bottom'}_$horizontal';

/// A click_screen target that names a position on the screen itself
/// ("center of the screen", "top left corner"), not an element: its point
/// on the screen [shot] covers. Null for anything else.
Point<int>? absoluteScreenPoint(String target, Screenshot shot) {
  var t = target.trim().toLowerCase();
  // The model often adds a note: "center of the screen (empty background area
  // in the main workspace)". Drop it unless it names an element.
  t = t.replaceAllMapped(
    RegExp(r'\s*\(([^)]*)\)'),
    (m) => namesElement(m[1]!) ? m[0]! : '',
  );
  t = t.replaceAll(RegExp('["\']'), '').replaceAll(_emptyAreaTail, '');
  final m = _absTarget.firstMatch(t.trim());
  if (m != null) {
    return screenPositionPoint(_positionOf(m.group(2), m.group(3)), shot);
  }
  // Looser: "center area of the desktop background (no labeled element), click
  // location in the middle of the screen": a centre or corner word plus a
  // screen word, and no element anywhere.
  if (namesElement(target) || !_screenWord.hasMatch(t)) return null;
  final corners = _cornerWords
      .allMatches(t)
      .map((c) => _positionOf(c[1], c[2]))
      .toSet();
  final center = _centerWord.hasMatch(t);
  if (corners.length + (center ? 1 : 0) != 1) return null; // none, or ambiguous
  return screenPositionPoint(center ? 'center' : corners.single, shot);
}

final _saidPosition = RegExp(
  r'\b(?:(center|centre|middle)|(top|upper|bottom|lower)[\s-]*(left|right)(?:[\s-]+(?:hand\s+)?corner)?)'
  r'\s+(?:of|on)\s+(?:the\s+|my\s+|this\s+)?(?:whole\s+|entire\s+)?(?:screen|display|desktop|monitor)\b',
);

final _spotWord = RegExp(
  r'\b(?:center|centre|middle|corner|empty|blank|background|wallpaper|desktop|screen)\b',
);

/// Whether a target may describe a screen spot rather than an element: no
/// quoted label, and any element word comes with a spot word ("empty area
/// beside the Woi window", not "'OK' button" or "gear icon").
bool _mayBeScreenSpot(String target) {
  final t = target.toLowerCase();
  if (t.contains(RegExp('["\u2018\u201c\u201d]')) ||
      RegExp(r"(^|\s)'").hasMatch(t)) {
    return false;
  }
  return !_elementWord.hasMatch(t) || _spotWord.hasMatch(t);
}

/// The screen position the user's own words ask to click ("click on the
/// center of the screen", "the top left corner of the display"); null when
/// they name an element anywhere ("the OK button in the middle of the
/// screen") or ask for more than one position.
String? userScreenPosition(String utterance) {
  final u = utterance.toLowerCase();
  if (u.trim().isEmpty || _elementWord.hasMatch(u)) {
    return null; // apostrophes are fine here
  }
  final found = _saidPosition
      .allMatches(u)
      .map((m) => _positionOf(m[2], m[3]))
      .toSet();
  return found.length == 1 ? found.single : null;
}

const _maxDirEntries = 300;

ToolSpec _spec(
  String name,
  String description,
  Map<String, Object?> props, [
  List<String> required = const [],
]) => ToolSpec(
  name: name,
  description: description,
  parameters: {
    'type': 'object',
    'properties': props,
    'required': required,
    'additionalProperties': false,
  },
);

List<ToolDefinition> builtinTools(ToolEnvironment env) {
  final p = env.platform;

  Future<bool> approveWrite(FileWriteRequest r, ToolInvocation call) async {
    call.onStatus?.call(ToolStatus.awaitingApproval);
    final ok = await env.confirmations.confirmFileWrite(r);
    call.onStatus?.call(ToolStatus.running);
    return ok;
  }

  Map<String, Object?> writeResult(WriteOutcome o) {
    if (!o.approved) throw ToolDenied('user rejected the change to ${o.path}');
    if (!o.written) throw ToolFailure('write failed: ${o.error}');
    return {
      'ok': true,
      'path': o.path,
      'bytes': o.bytes,
      '+': o.added,
      '-': o.removed,
    };
  }

  return [
    pythonTool(
      runner: p.python,
      files: p.files,
      confirmations: env.confirmations,
      settings: env.settings,
    ),
    ToolDefinition(
      spec: _spec(
        'take_screenshot',
        'Capture the whole screen. The image is attached to the conversation. '
            'Coordinates for click_screen refer to this image.',
        {},
      ),
      handler: (args, call) async {
        final s = env.settings();
        final shot = await p.screen.capture(
          scale: s.screenshotScale,
          jpegQuality: s.screenshotJpegQuality,
        );
        env.lastScreenshot = shot;
        await env.onScreenshot(shot, 'Screenshot requested by tool');
        return {
          'ok': true,
          'image': '${shot.width}x${shot.height}',
          'screen': '${shot.originalWidth}x${shot.originalHeight}',
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'click_screen',
        'Click a UI element on screen. Always give target: the element\'s visible label in quotes, its kind and '
            'where it is (e.g. "\'Save\' button in the Profile dialog", "\'Search\' field in the toolbar", '
            '"gear icon at the top right"); Woi then finds it precisely. Also give x/y, your estimate in pixels '
            'of the latest screenshot (a hint, and the click point if the target cannot be found). '
            'For a spot on the screen itself rather than an element (e.g. "the center of the screen"), '
            'set position and leave target empty.',
        {
          'target': {
            'type': 'string',
            'description':
                'What to click: quoted visible label + kind + location',
          },
          'position': {
            'type': 'string',
            'enum': screenPositions,
            'description': 'A screen spot, not an element',
          },
          'x': {
            'type': 'integer',
            'description': 'X in screenshot pixels (estimate)',
          },
          'y': {
            'type': 'integer',
            'description': 'Y in screenshot pixels (estimate)',
          },
          'button': {
            'type': 'string',
            'enum': ['left', 'right', 'middle'],
          },
          'double': {'type': 'boolean', 'description': 'Double-click'},
        },
      ),
      handler: (args, call) async {
        final pointer = env.pointerDelegate;
        if (pointer != null && env.settings().useLunaPointer) {
          return pointer(
            tool: call.name,
            callId: call.callId,
            arguments: args,
            request: env.userText?.call() ?? '',
            reference: env.lastScreenshot,
          );
        }
        final plan = await planClick(
          target: args.str('target'),
          position: args.str('position'),
          userText: env.userText?.call() ?? '',
          x: args['x'] is num ? args.integer('x', 0) : null,
          y: args['y'] is num ? args.integer('y', 0) : null,
          shot: env.lastScreenshot,
          locator: env.locator,
        );
        final sx = plan.point.x, sy = plan.point.y;
        final button =
            MouseButton.values.asNameMap()[args.str('button', 'left')] ??
            MouseButton.left;
        if (args.boolean('double')) {
          await p.input.doubleClick(sx, sy, button: button);
        } else {
          await p.input.click(sx, sy, button: button);
        }
        return {
          'ok': true,
          'screen_xy': [sx, sy],
          ...plan.info,
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'move_pointer',
        'Move the pointer to a screen position without clicking or typing. '
            'Coordinates use the latest screenshot, like click_screen. On a phone, '
            'show the touch pointer at that position without tapping. A light-blue '
            'indicator appears for one second before control; user movement cancels it. '
            'Never retry input after the user takes control until a new user request.',
        {
          'x': {
            'type': 'integer',
            'description': 'X in latest screenshot pixels',
          },
          'y': {
            'type': 'integer',
            'description': 'Y in latest screenshot pixels',
          },
          'position': {'type': 'string', 'enum': screenPositions},
        },
      ),
      handler: (args, call) async {
        final pointer = env.pointerDelegate;
        if (pointer != null && env.settings().useLunaPointer) {
          return pointer(
            tool: call.name,
            callId: call.callId,
            arguments: args,
            request: env.userText?.call() ?? '',
            reference: env.lastScreenshot,
          );
        }
        if (args.str('position').isEmpty &&
            (args['x'] is! num || args['y'] is! num)) {
          throw ToolFailure('Give both x and y, or a screen position.');
        }
        final plan = await planClick(
          position: args.str('position'),
          x: args['x'] is num ? args.integer('x', 0) : null,
          y: args['y'] is num ? args.integer('y', 0) : null,
          shot: env.lastScreenshot,
        );
        await p.input.moveMouse(plan.point.x, plan.point.y);
        return {
          'ok': true,
          'clicked': false,
          'screen_xy': [plan.point.x, plan.point.y],
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'type_text',
        'Insert literal text into the user\'s target editor immediately, before replying. '
            'The Android keyboard may be hidden; the tool recovers the input connection or uses the editable field directly. '
            'An actual editable target is still required. Does not interpret shortcuts or modify the clipboard. '
            'Report the returned delivery accurately: dispatched confirms input was sent, not that the app changed; '
            'applied means the editor acknowledged its edit action.',
        {
          'text': {'type': 'string'},
        },
        ['text'],
      ),
      handler: (args, call) async {
        final text = args.str('text');
        final input = p.input;
        final TextInputReceipt receipt;
        if (input case final AcknowledgedTextInput acknowledged) {
          receipt = await acknowledged.typeTextWithReceipt(text);
        } else {
          await input.typeText(text);
          receipt = const TextInputReceipt(delivery: 'dispatched', backend: 'platform_input');
        }
        return {'ok': true, 'chars': text.length, ...receipt.toJson()};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'key_combo',
        'Press a key combination, e.g. "ctrl+shift+t", "enter", or a sequence '
            'separated by spaces like "ctrl+a ctrl+c".',
        {
          'keys': {'type': 'string'},
        },
        ['keys'],
      ),
      handler: (args, call) async {
        await p.input.keyCombo(args.str('keys'));
        return {'ok': true};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'run_bash',
        'Run a bash command on the user\'s computer and return stdout, stderr '
            'and exit code (output is truncated).',
        {
          'command': {'type': 'string'},
          'timeout_s': {
            'type': 'integer',
            'description': 'Default 30, max 300',
          },
          'cwd': {
            'type': 'string',
            'description': 'Working directory (default: the workspace dir). ~ and \$HOME expand.',
          },
        },
        ['command'],
      ),
      handler: (args, call) async {
        final cmd = args.str('command');
        if (cmd.trim().isEmpty) throw ToolFailure('empty command');
        if (env.settings().confirmBeforeBash) {
          call.onStatus?.call(ToolStatus.awaitingApproval);
          final ok = await env.confirmations.confirmCommand(cmd);
          if (!ok) throw ToolDenied('user rejected the command');
          call.onStatus?.call(ToolStatus.running);
        }
        final cwdArg = args.strOrNull('cwd');
        final cwd = (cwdArg == null || cwdArg.trim().isEmpty)
            ? p.files.workspaceDir
            : p.files.resolveExisting(cwdArg);
        if (!await Directory(cwd).exists()) {
          throw ToolFailure(
            'working directory does not exist: $cwd'
            '${cwdArg == null ? '' : ' (from "$cwdArg")'}. HOME is ${p.files.homeDir}.',
          );
        }
        final term = env.terminalShell;
        final shell = term != null && env.settings().runBashInTerminal
            ? term
            : p.shell;
        final r = await shell.run(
          cmd,
          timeout: Duration(
            seconds: args.integer('timeout_s', 30).clamp(1, 300),
          ),
          workingDirectory: cwd,
        );
        return {'ok': r.exitCode == 0 && !r.timedOut, ...r.toJson()};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'read_file',
        'Read a text file. Paths may use ~. Use offset/limit (lines) for big files.',
        {
          'path': {'type': 'string'},
          'offset': {'type': 'integer', 'description': '1-based first line'},
          'limit': {'type': 'integer', 'description': 'Number of lines'},
        },
        ['path'],
      ),
      handler: (args, call) async {
        final path = args.str('path');
        final full = p.files.resolveExisting(path);
        if (!await File(full).exists()) {
          throw ToolFailure('no such file: $full');
        }
        final r = await p.files.read(
          path,
          maxBytes: 32 * 1024,
          offsetLine: args.intOrNull('offset'),
          limitLines: args.intOrNull('limit'),
        );
        if (r.isBinary) {
          return {
            'ok': false,
            'path': r.path,
            'binary': true,
            'bytes': r.totalBytes,
          };
        }
        return {
          'ok': true,
          'path': r.path,
          'content': r.content,
          if (r.startLine > 1) 'from_line': r.startLine,
          if (r.truncated) 'truncated': true,
          'bytes': r.totalBytes,
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'list_dir',
        'List a directory (directories first). t: f=file d=dir l=link.',
        {
          'path': {'type': 'string'},
          'hidden': {'type': 'boolean', 'description': 'Include dotfiles'},
        },
        ['path'],
      ),
      handler: (args, call) async {
        final path = args.str('path', '.');
        final full = p.files.resolveExisting(path);
        if (!await Directory(full).exists()) {
          throw ToolFailure('no such directory: $full');
        }
        final entries = await p.files.list(
          path,
          showHidden: args.boolean('hidden'),
        );
        return {
          'ok': true,
          'path': full,
          'entries': [for (final e in entries.take(_maxDirEntries)) e.toJson()],
          if (entries.length > _maxDirEntries)
            'more': entries.length - _maxDirEntries,
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'write_file',
        'Create or overwrite a text file. The user sees a diff and must approve.',
        {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        ['path', 'content'],
      ),
      handler: (args, call) async {
        final o = await p.files.write(
          args.str('path'),
          args.str('content'),
          approve: (r) => approveWrite(r, call),
        );
        return writeResult(o);
      },
    ),
    ToolDefinition(
      spec: _spec(
        'edit_file',
        'Replace exact text in a file. old_string must match exactly once unless '
            'replace_all is true. The user sees a diff and must approve.',
        {
          'path': {'type': 'string'},
          'old_string': {'type': 'string'},
          'new_string': {'type': 'string'},
          'replace_all': {'type': 'boolean'},
        },
        ['path', 'old_string', 'new_string'],
      ),
      handler: (args, call) async {
        final path = args.str('path');
        final full = p.files.resolveExisting(path);
        if (!await File(full).exists()) {
          throw ToolFailure('no such file: $full');
        }
        final current = await File(full).readAsString();
        final oldS = args.str('old_string'), newS = args.str('new_string');
        if (oldS.isEmpty) throw ToolFailure('old_string is empty');
        final count = oldS.allMatches(current).length;
        if (count == 0) throw ToolFailure('old_string not found in $full');
        final all = args.boolean('replace_all');
        if (count > 1 && !all) {
          throw ToolFailure(
            'old_string matches $count times; add context or set replace_all',
          );
        }
        final updated = all
            ? current.replaceAll(oldS, newS)
            : current.replaceFirst(oldS, newS);
        final o = await p.files.write(
          path,
          updated,
          approve: (r) => approveWrite(r, call),
        );
        return {...writeResult(o), 'replacements': all ? count : 1};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'show_file',
        'Show a file to the user inside Woi (its own viewer window: image zoom, audio, embedded video player, text/code, rendered Markdown). Never opens external apps.',
        {
          'path': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['image', 'audio', 'video', 'text'],
          },
        },
        ['path'],
      ),
      handler: (args, call) async {
        final full = p.files.resolveExisting(args.str('path'));
        if (!await File(full).exists()) {
          throw ToolFailure('no such file: $full');
        }
        final kind =
            MediaKind.values.asNameMap()[args.strOrNull('kind')] ??
            MediaItem.kindForPath(full);
        final surface = await p.viewer.show(MediaItem(kind: kind, path: full));
        return {'ok': true, 'shown_in': surface.name, 'kind': kind.name};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'delegate_task',
        'Hand a complex multi-step task (coding, analysis, long writing) to a '
            'stronger text model that has file and shell tools, and get its spoken summary. '
            'task: the user\'s request in their words, as an instruction (not your answer). '
            'Scripts, programs and documents are always saved as files in the workspace by the '
            'delegate; never tell it to only return or print the text.',
        {
          'task': {
            'type': 'string',
            'description': 'What the user asked for, e.g. "Write a Python script that finds duplicate files and save it"',
          },
          'context': {
            'type': 'string',
            'description':
                'Relevant details (paths, preferences); no answer text',
          },
        },
        ['task'],
      ),
      handler: (args, call) async {
        final r = await env.delegate.runTask(
          args.str('task'),
          model: env.settings().delegateModel,
          context: args.strOrNull('context'),
        );
        return r.toJson();
      },
    ),
  ];
}
