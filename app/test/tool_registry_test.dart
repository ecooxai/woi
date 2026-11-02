import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/media_viewer.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

class _RecordingDelegate implements DelegateBackend {
  String? task, model;
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    this.task = task;
    this.model = model;
    return DelegateResult(output: 'done: $task', success: true, model: model);
  }
}

void main() {
  late FakePlatform fp;
  late FakeConfirmations confirm;
  late ToolEnvironment env;
  late ToolRegistry registry;
  late _RecordingDelegate delegate;
  var settings = const AppSettings();
  final screenshots = <(Screenshot, String)>[];

  Map<String, Object?> decode(ToolOutcome o) => (jsonDecode(o.json) as Map).cast<String, Object?>();

  setUp(() async {
    fp = await FakePlatform.create();
    confirm = FakeConfirmations();
    delegate = _RecordingDelegate();
    settings = const AppSettings();
    screenshots.clear();
    env = ToolEnvironment(
      platform: fp.services,
      confirmations: confirm,
      delegate: delegate,
      settings: () => settings,
      onScreenshot: (s, note) async => screenshots.add((s, note)),
    );
    registry = ToolRegistry()..registerAll(builtinTools(env));
  });

  tearDown(() => fp.dispose());

  group('registry', () {
    test('exposes all built-in tools with JSON-schema parameters', () {
      expect(registry.names.toSet(), {
        'take_screenshot',
        'click_screen',
        'type_text',
        'key_combo',
        'run_bash',
        'read_file',
        'list_dir',
        'write_file',
        'edit_file',
        'show_file',
        'delegate_task',
      });
      for (final s in registry.specs) {
        final j = s.toJson();
        expect(j['type'], 'function');
        expect((j['parameters'] as Map)['type'], 'object');
        expect(s.description, isNotEmpty);
      }
    });

    test('unknown tool, bad JSON and schema violations become error results', () async {
      final unknown = await registry.dispatch('nope', '{}');
      expect(unknown.status, ToolStatus.error);
      expect(decode(unknown)['error'], contains('unknown tool'));

      final bad = await registry.dispatch('type_text', '{not json');
      expect(bad.status, ToolStatus.error);
      expect(decode(bad)['error'], contains('invalid JSON'));

      final missing = await registry.dispatch('type_text', '{}');
      expect(decode(missing)['error'], 'missing required argument "text"');

      final wrongType = await registry.dispatch('click_screen', '{"x":"a","y":1}');
      expect(decode(wrongType)['error'], contains('must be of type integer'));

      final badEnum = await registry.dispatch('click_screen', '{"x":1,"y":1,"button":"thumb"}');
      expect(decode(badEnum)['error'], contains('must be one of'));
    });

    test('handler exceptions never escape and large results are truncated', () async {
      final r = ToolRegistry(maxResultChars: 500)
        ..register(
          ToolDefinition(
            spec: const ToolSpec(name: 'boom', description: 'd', parameters: {'type': 'object'}),
            handler: (a, c) async => throw StateError('kaput'),
          ),
        )
        ..register(
          ToolDefinition(
            spec: const ToolSpec(name: 'big', description: 'd', parameters: {'type': 'object'}),
            handler: (a, c) async => {'data': 'x' * 5000},
          ),
        );
      final boom = await r.dispatch('boom', '');
      expect(boom.status, ToolStatus.error);
      expect(decode(boom)['error'], contains('kaput'));
      final big = await r.dispatch('big', '');
      expect(big.ok, isTrue);
      expect(big.json.length, lessThan(600));
      expect(decode(big)['truncated'], isTrue);
    });

    test('reports running status through onStatus', () async {
      final statuses = <ToolStatus>[];
      await registry.dispatch('key_combo', '{"keys":"ctrl+c"}', onStatus: statuses.add);
      expect(statuses, [ToolStatus.running]);
    });
  });

  group('input and screen tools', () {
    test('click_screen maps screenshot coordinates to the real screen', () async {
      // FakeScreen: 1280x720 image of a 2560x1440 screen.
      await registry.dispatch('take_screenshot', '{}');
      expect(screenshots, hasLength(1));
      final o = await registry.dispatch('click_screen', '{"x":100,"y":50,"double":true}');
      expect(o.ok, isTrue);
      expect(fp.input.log.last, 'dblclick 200 100 left');
      expect(decode(o)['screen_xy'], [200, 100]);
    });

    test('type_text and key_combo drive InputControl', () async {
      await registry.dispatch('type_text', '{"text":"hello"}');
      await registry.dispatch('key_combo', '{"keys":"ctrl+shift+t"}');
      expect(fp.input.log, ['type hello', 'key ctrl+shift+t']);
    });

    test('take_screenshot returns compact JSON with sizes', () async {
      final o = await registry.dispatch('take_screenshot', '{}');
      expect(decode(o), {'ok': true, 'image': '1280x720', 'screen': '2560x1440'});
      expect(env.lastScreenshot, isNotNull);
    });
  });

  group('run_bash', () {
    test('asks for confirmation by default and runs when approved', () async {
      final o = await registry.dispatch('run_bash', '{"command":"echo hi"}');
      expect(confirm.commandRequests, ['echo hi']);
      expect(o.ok, isTrue);
      expect(decode(o)['stdout'], 'hi\n');
      expect(decode(o)['exit_code'], 0);
    });

    test('denied command is not executed', () async {
      confirm.approveCommands = false;
      final statuses = <ToolStatus>[];
      final o = await registry.dispatch('run_bash', '{"command":"echo hi"}', onStatus: statuses.add);
      expect(o.status, ToolStatus.denied);
      expect(fp.shell.commands, isEmpty);
      expect(statuses, contains(ToolStatus.awaitingApproval));
    });

    test('skips confirmation when disabled in settings', () async {
      settings = settings.copyWith(confirmBeforeBash: false);
      await registry.dispatch('run_bash', '{"command":"echo hi"}');
      expect(confirm.commandRequests, isEmpty);
      expect(fp.shell.commands, ['echo hi']);
    });
  });

  group('files', () {
    test('read_file and list_dir', () async {
      await File('${fp.root.path}/notes.txt').writeAsString('one\ntwo\n');
      await Directory('${fp.root.path}/sub').create();
      final r = await registry.dispatch('read_file', '{"path":"~/notes.txt"}');
      expect(decode(r)['content'], contains('two'));
      final l = await registry.dispatch('list_dir', '{"path":"~"}');
      final entries = (decode(l)['entries'] as List).cast<Map>();
      expect(entries.first['name'], 'sub');
      expect(entries.first['t'], 'd');
      expect(entries.any((e) => e['name'] == 'notes.txt'), isTrue);
      final missing = await registry.dispatch('read_file', '{"path":"~/nope.txt"}');
      expect(decode(missing)['error'], contains('no such file'));
    });

    test('write_file shows a diff and writes only after approval', () async {
      final statuses = <ToolStatus>[];
      final o = await registry.dispatch(
        'write_file',
        '{"path":"~/new.txt","content":"a\\nb\\n"}',
        onStatus: statuses.add,
      );
      expect(o.ok, isTrue);
      expect(confirm.writeRequests.single.isNewFile, isTrue);
      expect(confirm.writeRequests.single.diff.added, 2);
      expect(statuses, containsAllInOrder([ToolStatus.running, ToolStatus.awaitingApproval, ToolStatus.running]));
      expect(await File('${fp.root.path}/new.txt').readAsString(), 'a\nb\n');
    });

    test('rejected write leaves the file untouched', () async {
      final f = File('${fp.root.path}/keep.txt');
      await f.writeAsString('original\n');
      confirm.approveWrites = false;
      final o = await registry.dispatch('write_file', '{"path":"~/keep.txt","content":"changed\\n"}');
      expect(o.status, ToolStatus.denied);
      expect(decode(o)['denied'], isTrue);
      expect(await f.readAsString(), 'original\n');
    });

    test('edit_file replaces a unique match with a diff preview', () async {
      final f = File('${fp.root.path}/code.dart');
      await f.writeAsString('void main() {\n  print("hi");\n}\n');
      final o = await registry.dispatch(
        'edit_file',
        jsonEncode({'path': '~/code.dart', 'old_string': '"hi"', 'new_string': '"hello"'}),
      );
      expect(o.ok, isTrue, reason: o.json);
      final d = confirm.writeRequests.single.diff;
      expect((d.added, d.removed), (1, 1));
      expect(await f.readAsString(), contains('"hello"'));
    });

    test('edit_file refuses ambiguous or missing matches without asking', () async {
      await File('${fp.root.path}/dup.txt').writeAsString('x x x');
      final amb = await registry.dispatch('edit_file', '{"path":"~/dup.txt","old_string":"x","new_string":"y"}');
      expect(decode(amb)['error'], contains('matches 3 times'));
      final none = await registry.dispatch('edit_file', '{"path":"~/dup.txt","old_string":"z","new_string":"y"}');
      expect(decode(none)['error'], contains('not found'));
      expect(confirm.writeRequests, isEmpty);
      final all = await registry.dispatch(
        'edit_file',
        '{"path":"~/dup.txt","old_string":"x","new_string":"y","replace_all":true}',
      );
      expect(decode(all)['replacements'], 3);
    });
  });

  test('show_file opens the viewer with the detected kind', () async {
    await File('${fp.root.path}/pic.png').writeAsBytes(tinyPng(2, 2));
    final o = await registry.dispatch('show_file', '{"path":"~/pic.png"}');
    expect(decode(o), {'ok': true, 'shown_in': 'overlay', 'kind': 'image'});
    expect(fp.viewer.shown.single.kind, MediaKind.image);
  });

  test('delegate_task uses the delegate model from settings', () async {
    final o = await registry.dispatch('delegate_task', '{"task":"refactor"}');
    expect(delegate.model, 'gpt-6.1-sol');
    expect(decode(o)['output'], 'done: refactor');
  });
}
