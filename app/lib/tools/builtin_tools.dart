import 'dart:io';

import '../core/delegate/delegate_backend.dart';
import '../core/models/message.dart';
import '../core/settings/settings.dart';
import '../core/voice/voice_backend.dart';
import '../platform/files.dart';
import '../platform/input_control.dart';
import '../platform/media_viewer.dart';
import '../platform/platform_services.dart';
import '../platform/screen_capture.dart';
import 'confirmation.dart';
import 'tool_registry.dart';

/// Shared state and dependencies for the built-in tools.
class ToolEnvironment {
  ToolEnvironment({
    required this.platform,
    required this.confirmations,
    required this.delegate,
    required this.settings,
    required this.onScreenshot,
  });

  final PlatformServices platform;
  final ConfirmationService confirmations;
  final DelegateBackend delegate;
  final AppSettings Function() settings;

  /// Attaches a screenshot to the conversation and sends it to the model.
  final Future<void> Function(Screenshot shot, String note) onScreenshot;

  /// Most recent screenshot the model saw: click coordinates are relative to it.
  Screenshot? lastScreenshot;
}

const _maxDirEntries = 300;

ToolSpec _spec(String name, String description, Map<String, Object?> props,
        [List<String> required = const []]) =>
    ToolSpec(name: name, description: description, parameters: {
      'type': 'object',
      'properties': props,
      'required': required,
      'additionalProperties': false,
    });

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
    return {'ok': true, 'path': o.path, 'bytes': o.bytes, '+': o.added, '-': o.removed};
  }

  return [
    ToolDefinition(
      spec: _spec(
        'take_screenshot',
        'Capture the whole screen. The image is attached to the conversation. '
            'Coordinates for click_screen refer to this image.',
        {},
      ),
      handler: (args, call) async {
        final shot = await p.screen.capture(maxWidth: 1280);
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
        'Click at a position given in the coordinates of the latest screenshot.',
        {
          'x': {'type': 'integer', 'description': 'X in screenshot pixels'},
          'y': {'type': 'integer', 'description': 'Y in screenshot pixels'},
          'button': {'type': 'string', 'enum': ['left', 'right', 'middle']},
          'double': {'type': 'boolean', 'description': 'Double-click'},
        },
        ['x', 'y'],
      ),
      handler: (args, call) async {
        final x = args.integer('x', 0), y = args.integer('y', 0);
        final shot = env.lastScreenshot;
        final pt = shot?.toScreen(x, y);
        final sx = pt?.x ?? x, sy = pt?.y ?? y;
        final button = MouseButton.values.asNameMap()[args.str('button', 'left')] ??
            MouseButton.left;
        if (args.boolean('double')) {
          await p.input.doubleClick(sx, sy, button: button);
        } else {
          await p.input.click(sx, sy, button: button);
        }
        return {'ok': true, 'screen_xy': [sx, sy]};
      },
    ),
    ToolDefinition(
      spec: _spec('type_text', 'Type text into the focused window.',
          {'text': {'type': 'string'}}, ['text']),
      handler: (args, call) async {
        final text = args.str('text');
        await p.input.typeText(text);
        return {'ok': true, 'chars': text.length};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'key_combo',
        'Press a key combination, e.g. "ctrl+shift+t", "enter", or a sequence '
            'separated by spaces like "ctrl+a ctrl+c".',
        {'keys': {'type': 'string'}},
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
          'timeout_s': {'type': 'integer', 'description': 'Default 30, max 300'},
          'cwd': {'type': 'string', 'description': 'Working directory'},
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
        final cwd = args.strOrNull('cwd');
        final r = await p.shell.run(
          cmd,
          timeout: Duration(seconds: args.integer('timeout_s', 30).clamp(1, 300)),
          workingDirectory: cwd == null ? null : p.files.resolve(cwd),
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
        final full = p.files.resolve(path);
        if (!await File(full).exists()) throw ToolFailure('no such file: $full');
        final r = await p.files.read(path,
            maxBytes: 32 * 1024,
            offsetLine: args.intOrNull('offset'),
            limitLines: args.intOrNull('limit'));
        if (r.isBinary) {
          return {'ok': false, 'path': r.path, 'binary': true, 'bytes': r.totalBytes};
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
        final path = args.str('path', '~');
        final full = p.files.resolve(path);
        if (!await Directory(full).exists()) throw ToolFailure('no such directory: $full');
        final entries = await p.files.list(path, showHidden: args.boolean('hidden'));
        return {
          'ok': true,
          'path': full,
          'entries': [for (final e in entries.take(_maxDirEntries)) e.toJson()],
          if (entries.length > _maxDirEntries) 'more': entries.length - _maxDirEntries,
        };
      },
    ),
    ToolDefinition(
      spec: _spec(
        'write_file',
        'Create or overwrite a text file. The user sees a diff and must approve.',
        {'path': {'type': 'string'}, 'content': {'type': 'string'}},
        ['path', 'content'],
      ),
      handler: (args, call) async {
        final o = await p.files.write(args.str('path'), args.str('content'),
            approve: (r) => approveWrite(r, call));
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
        final full = p.files.resolve(path);
        if (!await File(full).exists()) throw ToolFailure('no such file: $full');
        final current = await File(full).readAsString();
        final oldS = args.str('old_string'), newS = args.str('new_string');
        if (oldS.isEmpty) throw ToolFailure('old_string is empty');
        final count = oldS.allMatches(current).length;
        if (count == 0) throw ToolFailure('old_string not found in $full');
        final all = args.boolean('replace_all');
        if (count > 1 && !all) {
          throw ToolFailure('old_string matches $count times; add context or set replace_all');
        }
        final updated = all ? current.replaceAll(oldS, newS) : current.replaceFirst(oldS, newS);
        final o = await p.files.write(path, updated, approve: (r) => approveWrite(r, call));
        return {...writeResult(o), 'replacements': all ? count : 1};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'show_file',
        'Open a file for the user in a viewer popup (image, audio, video, or text/code).',
        {
          'path': {'type': 'string'},
          'kind': {'type': 'string', 'enum': ['image', 'audio', 'video', 'text']},
        },
        ['path'],
      ),
      handler: (args, call) async {
        final full = p.files.resolve(args.str('path'));
        if (!await File(full).exists()) throw ToolFailure('no such file: $full');
        final kind = MediaKind.values.asNameMap()[args.strOrNull('kind')] ??
            MediaItem.kindForPath(full);
        final surface = await p.viewer.show(MediaItem(kind: kind, path: full));
        return {'ok': true, 'shown_in': surface.name, 'kind': kind.name};
      },
    ),
    ToolDefinition(
      spec: _spec(
        'delegate_task',
        'Hand a complex multi-step task (coding, analysis, long writing) to a '
            'stronger text model and get its answer.',
        {
          'task': {'type': 'string'},
          'context': {'type': 'string', 'description': 'Relevant details'},
        },
        ['task'],
      ),
      handler: (args, call) async {
        final r = await env.delegate.runTask(args.str('task'),
            model: env.settings().delegateModel, context: args.strOrNull('context'));
        return r.toJson();
      },
    ),
  ];
}
