import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/tools/clipboard_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _Clipboard implements ClipboardAccess {
  String? value;
  int reads = 0;
  final writes = <String>[];
  bool failWrite = false;
  @override
  Future<String?> readText() async {
    reads++;
    return value;
  }

  @override
  Future<void> writeText(String text) async {
    if (failWrite) throw StateError('clipboard unavailable');
    writes.add(text);
    value = text;
  }
}

class _BlockingClipboard extends _Clipboard {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> writeText(String text) async {
    started.complete();
    await release.future;
    await super.writeText(text);
  }
}

class _RefusingInput extends FakeInput {
  @override
  Future<SendKeysResult> sendKeys({String? keys, KeyAction? action, KeyTarget target = const KeyTarget()}) async {
    throw StateError('No editable target');
  }
}

void main() {
  late _Clipboard clipboard;
  late FakeInput input;
  late ToolRegistry tools;
  Future<Map<String, dynamic>> run(Map<String, Object?> args) async =>
      jsonDecode((await tools.dispatch('clipboard', jsonEncode(args))).json) as Map<String, dynamic>;
  setUp(() {
    clipboard = _Clipboard();
    input = FakeInput();
    tools = ToolRegistry()..register(clipboardTool(clipboard, input));
  });

  test('keyboard refusal is an error while requested-but-hidden stays explicit', () async {
    tools = ToolRegistry()
      ..register(showKeyboardTool(() async => {'requested': false, 'visible': false, 'focus_changed': false}));
    final denied = jsonDecode((await tools.dispatch('show_keyboard', '{}')).json) as Map;
    expect(denied['ok'], false);
    expect(denied['error'], contains('did not become visible'));
    final executor = DelegationExecutor(
      model: FakeDelegationModel(const []),
      tools: const [
        ToolSpec(name: 'show_keyboard', description: '', parameters: {'type': 'object'}),
      ],
      runTool: (_, name, data) async => '{"ok":true,"requested":true,"visible":false}',
    );
    final report = await executor.execute('show the keyboard');
    expect(report.resultText, startsWith('Keyboard requested; Android has not shown it.'));
  });

  test('request acceptance without visibility cannot satisfy show_keyboard', () async {
    tools = ToolRegistry()
      ..register(showKeyboardTool(() async => {'requested': true, 'visible': false, 'focus_changed': false}));
    final result = await tools.dispatch('show_keyboard', '{}');
    expect(result.ok, isFalse);
  });

  test('visible touch keyboard can truthfully report no text receiver', () async {
    tools = ToolRegistry()
      ..register(
        showKeyboardTool(
          () async => {
            'requested': true,
            'visible': true,
            'focus_changed': false,
            'backend': 'woi_touch_keyboard',
            'text_target': false,
            'text_input_available': false,
            'input_connection': false,
          },
        ),
      );
    final result = await tools.dispatch('show_keyboard', '{}');
    expect(result.ok, isTrue);
    final receipt = jsonDecode(result.json) as Map;
    expect(receipt['text_input_available'], isFalse);
    expect(receipt['visible'], isTrue);
  });

  test('Stop during a pending clipboard write prevents a stale follow-up paste', () async {
    var epoch = 0;
    final blocked = _BlockingClipboard();
    clipboard = blocked;
    tools = ToolRegistry()..register(clipboardTool(clipboard, input, cancellationEpoch: () => epoch));
    final pending = run({'action': 'paste', 'text': 'new text'});
    await blocked.started.future;
    epoch++;
    blocked.release.complete();
    final result = await pending;
    expect(result['ok'], false);
    expect(result['error'], contains('Clipboard updated, but paste cancelled'));
    expect(input.log, isEmpty);
    expect(clipboard.value, 'new text');
  });

  test('explicit empty write and paste clear old text instead of reusing it', () async {
    clipboard.value = 'stale clipboard text';
    final written = await run({'action': 'write', 'text': ''});
    expect(written['ok'], true, reason: written.toString());
    expect(clipboard.value, '');
    clipboard.value = 'stale clipboard text';
    final pasted = await run({'action': 'paste', 'text': ''});
    expect(pasted['ok'], true);
    expect(pasted['clipboard_written'], true);
    expect(clipboard.value, '');
    expect(clipboard.writes, ['', '']);
    expect(input.log.length, 1);
    expect(clipboard.reads, 0);
  });

  test('show keyboard uses a direct Android request without choosing a field', () async {
    final model = FakeDelegationModel(const []);
    final calls = <(String, String)>[];
    final executor = DelegationExecutor(
      model: model,
      tools: const [
        ToolSpec(name: 'show_keyboard', description: '', parameters: {'type': 'object'}),
      ],
      runTool: (_, name, data) async {
        calls.add((name, data));
        return '{"ok":true,"requested":true,"visible":false}';
      },
    );
    await executor.execute('show the keyboard');
    expect(model.requests, isEmpty);
    expect(calls.single.$1, 'show_keyboard');
    expect(jsonDecode(calls.single.$2), isEmpty);
  });

  test('clipboard reads are explicit, preserve Unicode, and do not type or copy', () async {
    clipboard.value = 'line 1\n雪🙂';
    final result = await run({'action': 'read'});
    expect(result['text'], clipboard.value);
    expect(result['available'], true);
    expect(clipboard.reads, 1);
    expect(clipboard.writes, isEmpty);
    expect(input.log, isEmpty);
  });

  test('empty clipboard, empty text, and truncated Unicode are distinct', () async {
    expect((await run({'action': 'read'}))['available'], false);
    clipboard.value = '';
    final empty = await run({'action': 'read'});
    expect(empty['available'], true);
    expect(empty['text'], '');
    clipboard.value = 'A🙂B';
    final clipped = await run({'action': 'read', 'max_chars': 2});
    expect(clipped['text'], 'A');
    expect(clipped['chars'], 4);
    expect(clipped['truncated'], true);
  });

  test('write keeps exact whitespace without reading or typing', () async {
    const text = '  A + B\n雪🙂  ';
    expect((await run({'action': 'write', 'text': text}))['written'], true);
    expect(clipboard.value, text);
    expect(clipboard.reads, 0);
    expect(input.log, isEmpty);
  });

  test('existing clipboard paste uses target edit action without a clipboard read', () async {
    input.windowClass = 'xterm XTerm';
    final result = await run({'action': 'paste', 'window': 'xterm'});
    expect(result['ok'], true);
    expect(result['clipboard_written'], false);
    expect(input.log, ['keys ctrl+shift+v @xterm']);
    expect(clipboard.reads, 0);
    expect(clipboard.writes, isEmpty);
  });

  test('copy and paste writes once then sends one paste with truthful delivery', () async {
    final result = await run({'action': 'paste', 'text': 'literal 雪'});
    expect(result['ok'], true);
    expect(result['clipboard_written'], true);
    expect(clipboard.writes, ['literal 雪']);
    expect(clipboard.reads, 0);
    expect(input.log.length, 1);
  });

  test('failed clipboard write never pastes and failed paste reports partial write', () async {
    clipboard.failWrite = true;
    expect((await run({'action': 'paste', 'text': 'x'}))['ok'], false);
    expect(input.log, isEmpty);
    clipboard.failWrite = false;
    tools = ToolRegistry()..register(clipboardTool(clipboard, _RefusingInput()));
    final failedPaste = await run({'action': 'paste', 'text': 'x'});
    expect(failedPaste['ok'], false);
    expect(failedPaste['error'], contains('Clipboard updated, but paste failed'));
    expect(clipboard.writes, ['x']);
  });

  test('invalid combinations fail before reading, writing, or pasting', () async {
    for (final args in <Map<String, Object?>>[
      {'action': 'read', 'text': 'x'},
      {'action': 'write'},
      {'action': 'write', 'text': 'x', 'window': 'editor'},
      {'action': 'paste', 'text': 'x', 'max_chars': 5},
      {'action': 'read', 'max_chars': 0},
      {'action': 'read', 'max_chars': 12001},
      {'action': 'write', 'text': 'x' * 100001},
    ]) {
      expect((await run(args))['ok'], false, reason: args['action'] as String);
    }
    expect(clipboard.reads, 0);
    expect(clipboard.writes, isEmpty);
    expect(input.log, isEmpty);
  });

  final fast = <(String, Map<String, Object?>)>[
    ('read my clipboard', {'action': 'read'}),
    ("What's on my clipboard?", {'action': 'read'}),
    ('Please copy "  Hello 雪  " to the clipboard.', {'action': 'write', 'text': '  Hello 雪  '}),
    ('set clipboard to “A + B”', {'action': 'write', 'text': 'A + B'}),
    ('paste "line 1\nline 2" here', {'action': 'paste', 'text': 'line 1\nline 2'}),
    ('write "" to clipboard', {'action': 'write', 'text': ''}),
  ];
  for (final (request, args) in fast) {
    test('clipboard fast path executes once without a model: $request', () async {
      final model = FakeDelegationModel(const []);
      final calls = <(String, String)>[];
      final executor = DelegationExecutor(
        model: model,
        tools: const [
          ToolSpec(name: 'clipboard', description: '', parameters: {'type': 'object'}),
        ],
        runTool: (_, name, data) async {
          calls.add((name, data));
          return '{"ok":true}';
        },
      );
      final report = await executor.execute(request);
      expect(model.requests, isEmpty);
      expect(report.model, 'fast-path');
      expect(calls.single.$1, 'clipboard');
      expect(jsonDecode(calls.single.$2), args);
      expect(looksLikeAction(request), true);
    });
  }

  for (final request in [
    'How do I read the clipboard?',
    'do not read my clipboard',
    'copy it to clipboard',
    'paste a short summary',
    'paste "x" and click Save',
    'read clipboard and summarize it',
    'copy "x" then "y" to clipboard',
    'explain how to write "x" to clipboard',
  ]) {
    test('ambiguous or compound clipboard command keeps model interpretation: $request', () {
      expect(DelegationExecutor.clipboardFastPath(request), isNull);
    });
  }
}
