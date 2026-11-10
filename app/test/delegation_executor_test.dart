import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';

const _tools = [
  ToolSpec(name: 'take_screenshot', description: 'shot', parameters: {'type': 'object'}),
  ToolSpec(name: 'click_screen', description: 'click', parameters: {'type': 'object'}),
  ToolSpec(name: 'type_text', description: 'type', parameters: {'type': 'object'}),
  ToolSpec(name: 'run_bash', description: 'bash', parameters: {'type': 'object'}),
  ToolSpec(name: 'list_dir', description: 'ls', parameters: {'type': 'object'}),
  ToolSpec(name: 'delegate_task', description: 'sol', parameters: {'type': 'object'}),
];

const _showTools = [
  ..._tools,
  ToolSpec(name: 'show_file', description: 'show', parameters: {'type': 'object'}),
];

class _Runner {
  final runs = <(String, String, String)>[];
  DelegationImage? shot;
  String Function(String name, String args) result = (n, a) => '{"ok":true}';

  Future<String> call(String id, String name, String args) async {
    runs.add((id, name, args));
    if (name == 'take_screenshot') {
      shot = DelegationImage(png: Uint8List.fromList([1, 2, 3]), capturedAt: DateTime.now(), note: 'fresh');
    }
    return result(name, args);
  }
}

void main() {
  test('single step: tools from one reply run in order and are summarized', () async {
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now(), note: '1280x720');
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('click_screen', {'x': 640, 'y': 360}),
          call('type_text', {'text': 'hello'}),
        ],
      ),
    ]);
    final ex = DelegationExecutor(model: m, tools: _tools, runTool: r.call, latestScreenshot: () => r.shot);
    final rep = await ex.execute('click the center and type hello', id: 'del_1');

    expect(r.runs.map((x) => x.$2), ['click_screen', 'type_text']);
    expect(rep.ok, isTrue);
    expect(rep.steps, 1);
    expect(rep.freshCapture, isFalse);
    expect(rep.usedScreenshot, isTrue);
    expect(rep.resultText, startsWith('Done. '));
    expect(rep.resultText, contains('click_screen(x=640, y=360)'));
    expect(rep.resultText, contains('type_text(text="hello")'));
    expect(rep.firstToolCall, isNotNull);
    expect(rep.toolsDone, isNotNull);

    // Request: fast model, stream of tool specs, image + text user message.
    final req = m.requests.single;
    expect(req.model, 'gpt-6-luna');
    expect(req.tools.map((t) => t['name']), contains('click_screen'));
    final content = (req.input.single['content'] as List).cast<Map>();
    expect(content.first['type'], 'input_image');
    expect('${content.first['image_url']}', startsWith('data:image/png;base64,'));
    expect(content.last['text'], contains('click the center'));
    expect(content.last['text'], contains('1280x720'));
  });

  test('captures a fresh screenshot when none (or a stale one) is available', () async {
    final r = _Runner();
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('click_screen', {'x': 1, 'y': 2}),
        ],
      ),
    ]);
    final ex = DelegationExecutor(model: m, tools: _tools, runTool: r.call, latestScreenshot: () => r.shot);
    final rep = await ex.execute('click it');
    expect(r.runs.map((x) => x.$2), ['take_screenshot', 'click_screen']);
    expect(rep.freshCapture, isTrue);
    expect(rep.usedScreenshot, isTrue);
    // The capture is not part of the spoken result.
    expect(rep.resultText, isNot(contains('take_screenshot')));

    r.runs.clear();
    r.shot = DelegationImage(png: Uint8List(1), capturedAt: DateTime.now().subtract(const Duration(minutes: 5)));
    m.turns.add(const DelegationModelTurn(text: 'ok', calls: []));
    await ex.execute('again');
    expect(r.runs.first.$2, 'take_screenshot');
  });

  test('plain "type X" types into the focused window without a model call', () async {
    final r = _Runner();
    final m = FakeDelegationModel(const []);
    final rep = await DelegationExecutor(model: m, tools: _tools, runTool: r.call).execute("Type 'hello world");
    expect(m.requests, isEmpty);
    expect(rep.model, 'fast-path');
    expect(rep.tools.single.name, 'type_text');
    expect(jsonDecode(rep.tools.single.argsJson), {'text': 'hello world'});
    expect(rep.resultText, startsWith('Done.'));
  });

  test('phone: no speculative capture for non-visual requests (it would send Woi to the back)', () async {
    final r = _Runner();
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('run_bash', {'command': 'date'}),
        ],
      ),
    ]);
    final ex = DelegationExecutor(
      model: m,
      tools: _tools,
      runTool: r.call,
      latestScreenshot: () => r.shot,
      speculativeCapture: false,
    );
    final rep = await ex.execute('What time is it');
    expect(r.runs.map((x) => x.$2), ['run_bash']);
    expect(rep.freshCapture, isFalse);

    // Visual requests still capture first.
    r.runs.clear();
    m.turns.add(
      DelegationModelTurn(
        text: '',
        calls: [
          call('click_screen', {'x': 1, 'y': 2}),
        ],
      ),
    );
    final rep2 = await ex.execute('Tap the Wi-Fi button');
    expect(r.runs.map((x) => x.$2), ['take_screenshot', 'click_screen']);
    expect(rep2.freshCapture, isTrue);
  });

  test('non-visual requests skip the image and do not wait for a capture', () async {
    // Fresh screenshot available but not needed: text only.
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now());
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('run_bash', {'command': 'ls ~'}),
        ],
      ),
    ]);
    final ex = DelegationExecutor(model: m, tools: _tools, runTool: r.call, latestScreenshot: () => r.shot);
    final rep = await ex.execute('Run the command ls in my home folder');
    expect(rep.usedScreenshot, isFalse);
    expect((m.requests.single.input.single['content'] as List).map((c) => (c as Map)['type']), ['input_text']);
    expect(m.requests.single.tools.map((t) => t['name']), contains('take_screenshot'), reason: 'can still look');

    // No screenshot at all: the capture runs in parallel with the request.
    final slow = Completer<void>();
    final r2 = _Runner();
    Future<String> runner(String id, String name, String args) async {
      if (name == 'take_screenshot') await slow.future;
      return r2.call(id, name, args);
    }

    final m2 = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('type_text', {'text': 'hello world'}),
        ],
      ),
    ]);
    final done = DelegationExecutor(
      model: m2,
      tools: _tools,
      runTool: runner,
      latestScreenshot: () => r2.shot,
    ).execute('Type a short greeting');
    await pumpEventQueue();
    expect(m2.requests, hasLength(1), reason: 'model request started before the capture finished');
    slow.complete();
    final rep2 = await done;
    expect(rep2.freshCapture, isTrue);
    expect(rep2.resultText, contains('type_text'));
    expect(rep2.resultText, isNot(contains('take_screenshot')));
  });

  test('visual requests attach the image and drop take_screenshot from the tools', () async {
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now());
    final m = FakeDelegationModel([const DelegationModelTurn(text: 'A text editor with notes.', calls: [])]);
    final rep = await DelegationExecutor(
      model: m,
      tools: _tools,
      runTool: r.call,
      latestScreenshot: () => r.shot,
    ).execute("What's on my screen right now?");
    expect(rep.usedScreenshot, isTrue);
    expect(m.requests.single.tools.map((t) => t['name']), isNot(contains('take_screenshot')));
    expect(rep.resultText, 'A text editor with notes.');
    expect(DelegationExecutor.needsScreen('Click on the center of the screen'), isTrue);
    expect(DelegationExecutor.needsScreen('Show me the file README.md'), isFalse);
  });

  test('show fast path: spoken file names, no model call; falls back on failure', () async {
    expect(DelegationExecutor.showFastPath('Show me the file README dot md'), 'README.md');
    expect(DelegationExecutor.typeFastPath("Type 'hello world"), 'hello world');
    expect(DelegationExecutor.typeFastPath('Type "Hello, world!"'), 'Hello, world');
    expect(DelegationExecutor.typeFastPath('please type hello world'), 'hello world');
    expect(DelegationExecutor.typeFastPath('Type out the text: foo bar.'), 'foo bar');
    expect(DelegationExecutor.typeFastPath('Type a short email to Bob about the meeting'), isNull);
    expect(DelegationExecutor.typeFastPath('type a summary of this page'), isNull);
    expect(DelegationExecutor.typeFastPath('Click the button and type hello'), isNull);
    expect(DelegationExecutor.showFastPath('Show me the file README.md.'), 'README.md');
    expect(DelegationExecutor.showFastPath('Play the video demo dot mp four'), 'demo.mp4');
    expect(DelegationExecutor.showFastPath('Open ~/Pictures/cat.png'), '~/Pictures/cat.png');
    expect(DelegationExecutor.showFastPath('Play the audio file tone dot wav'), 'tone.wav');
    expect(DelegationExecutor.showFastPath('Show me the image file sample dot png.'), 'sample.png');
    expect(DelegationExecutor.showFastPath('Show me what is on the screen'), isNull);
    expect(DelegationExecutor.showFastPath('Open Firefox'), isNull);

    final r = _Runner();
    final m = FakeDelegationModel([]);
    final ex = DelegationExecutor(model: m, tools: _showTools, runTool: r.call, latestScreenshot: () => r.shot);
    final rep = await ex.execute('Show me the file README dot md');
    expect(m.requests, isEmpty);
    expect(r.runs.single.$2, 'show_file');
    expect(jsonDecode(r.runs.single.$3), {'path': 'README.md'});
    expect(rep.model, 'fast-path');
    expect(rep.resultText, startsWith('Done. show_file(path="README.md")'));

    // Wrong case (speech): found via list_dir, still no model call.
    r.runs.clear();
    r.result = (n, a) => switch (n) {
      'list_dir' => '{"ok":true,"entries":[{"name":"Docs","t":"d"},{"name":"README.md","t":"f"}]}',
      _ => a.contains('"README.md"') ? '{"ok":true}' : '{"ok":false,"error":"no such file"}',
    };
    final rep1 = await ex.execute('Show me the file readme dot md');
    expect(m.requests, isEmpty);
    expect(r.runs.map((x) => x.$2), ['show_file', 'list_dir', 'show_file']);
    expect(rep1.resultText, 'Done. show_file(path="README.md") -> ok');

    // Not found: the model takes over and the failed attempts are not reported.
    r.runs.clear();
    r.result = (n, a) => n == 'list_dir'
        ? '{"ok":true,"entries":[]}'
        : r.runs.length == 1
        ? '{"ok":false,"error":"no such file"}'
        : '{"ok":true}';
    m.turns.add(
      DelegationModelTurn(
        text: '',
        calls: [
          call('show_file', {'path': 'Documents/README.md'}),
        ],
      ),
    );
    final rep2 = await ex.execute('Show me the file README dot md');
    expect(m.requests, hasLength(1));
    expect(rep2.resultText, startsWith('Done. show_file(path="Documents/README.md")'));
  });

  test('lookups (read_file, find) loop back; explicit commands and changes do not', () {
    bool obs(String name, Map<String, Object?> args, String req) =>
        DelegationExecutor.isObservation(call(name, args), req);
    expect(obs('read_file', {'path': 'notes.txt'}, 'add buy milk to notes'), isTrue);
    expect(obs('run_bash', {'command': 'find ~ -name README.md'}, 'show me readme'), isTrue);
    expect(obs('run_bash', {'command': 'ls ~'}, 'Run the command ls in my home folder'), isFalse);
    expect(obs('run_bash', {'command': "printf 'x' >> notes.txt"}, 'add x to notes'), isFalse);
    expect(obs('edit_file', {'path': 'notes.txt'}, 'add x'), isFalse);
  });

  test('observation tools loop back with results; action tools finish fast', () async {
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now());
    r.result = (n, a) => n == 'list_dir' ? '{"ok":true,"entries":["notes.txt"]}' : '{"ok":true}';
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('list_dir', {'path': '~'}),
        ],
      ),
      DelegationModelTurn(text: 'You have notes.txt.', calls: const []),
    ]);
    final ex = DelegationExecutor(model: m, tools: _tools, runTool: r.call, latestScreenshot: () => r.shot);
    final rep = await ex.execute('what files are in my home?');
    expect(m.requests, hasLength(2));
    final second = m.requests[1].input;
    expect(second.map((i) => i['type']), containsAllInOrder(['message', 'function_call', 'function_call_output']));
    expect(second.last['output'], contains('notes.txt'));
    expect(rep.steps, 2);
    expect(rep.resultText, contains('You have notes.txt.'));
  });

  test('declined and failed tools are reported', () async {
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now());
    r.result = (n, a) => '{"ok":false,"denied":true}';
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('run_bash', {'command': 'rm x'}),
        ],
      ),
    ]);
    final rep = await DelegationExecutor(
      model: m,
      tools: _tools,
      runTool: r.call,
      latestScreenshot: () => r.shot,
    ).execute('delete x');
    expect(rep.resultText, startsWith('Not fully done.'));
    expect(rep.resultText, contains('the user declined'));
  });

  test('written answer uses only the terminal model turn after tool output', () async {
    final r = _Runner()..result = (_, _) => '{"ok":true,"stdout":"PRIVATE_TOOL_PAYLOAD"}';
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: 'I will inspect the details.',
        calls: [
          call('list_dir', {'path': '.'}),
        ],
      ),
      const DelegationModelTurn(text: '  The requested item is green.  ', calls: []),
    ]);
    final report = await DelegationExecutor(
      model: model,
      tools: _tools,
      runTool: r.call,
    ).execute('Inspect the details.');
    expect(report.steps, 2);
    expect(report.answerText, 'The requested item is green.');
    expect(report.answerText, isNot(contains('PRIVATE_TOOL_PAYLOAD')));
    expect(report.answerText, isNot(contains('I will')));
  });

  test('written image mode preserves requested file tools without fabricating a final analysis', () async {
    final runner = _Runner()..result = (_, _) => '{"ok":true,"output":"Saved requested description.txt"}';
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('delegate_task', {'task': 'Save the requested description.txt'}),
        ],
      ),
    ]);
    final image = DelegationImage(png: Uint8List.fromList([137, 80, 78, 71]), capturedAt: DateTime(2026));
    final report = await DelegationExecutor(model: model, tools: _tools, runTool: runner.call).execute(
      'Save a description of this image to description.txt.',
      attachedImages: [image],
      writtenImageAnswer: true,
    );
    expect(model.requests.single.tools.map((t) => t['name']), contains('delegate_task'));
    expect(model.receivedInstructions.single, contains('Clearly requested file or tool actions remain available'));
    expect(runner.runs.map((run) => run.$2), ['delegate_task']);
    expect(report.tools.single.ok, isTrue);
    expect(report.answerText, isEmpty, reason: 'A saved-path confirmation is not the complete analysis.');
    expect(report.resultText, contains('Saved requested description.txt'));
  });

  test('written image mode keeps the complete terminal answer after observation results', () async {
    final answer = '${'Complete observation with Unicode 🙂. ' * 180}Final number 913.';
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: 'Interim narration.',
        calls: [
          call('list_dir', {'path': '.'}),
        ],
      ),
      DelegationModelTurn(text: answer, calls: []),
    ]);
    final report =
        await DelegationExecutor(
          model: model,
          tools: _tools,
          runTool: (id, name, args) async => '{"ok":true,"entries":["PRIVATE_TOOL_DATA"]}',
        ).execute(
          'Write a detailed image analysis and check the requested directory.',
          attachedImages: [DelegationImage(png: Uint8List(4), capturedAt: DateTime(2026))],
          writtenImageAnswer: true,
        );
    expect(report.answerText, answer);
    expect(report.answerText.length, greaterThan(4000));
    expect(report.answerText, isNot(contains('Interim narration')));
    expect(report.answerText, isNot(contains('PRIVATE_TOOL_DATA')));
    expect(
      model.receivedInstructions.every((s) => s.contains('Return the complete answer as final response text')),
      isTrue,
    );
  });

  test('written image instructions require both the explicit mode and an image', () async {
    for (final withImage in [false, true]) {
      final model = FakeDelegationModel([const DelegationModelTurn(text: 'Ordinary answer.', calls: [])]);
      await DelegationExecutor(model: model, tools: [], runTool: _Runner().call).execute(
        'Write a long description.',
        attachedImages: withImage ? [DelegationImage(png: Uint8List(4), capturedAt: DateTime(2026))] : [],
        writtenImageAnswer: !withImage,
      );
      expect(model.receivedInstructions.single, DelegationExecutor.instructions);
    }
  });

  test('a tool-only turn does not become a fabricated written final answer', () async {
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: 'I will type it.',
        calls: [
          call('type_text', {'text': 'fixture'}),
        ],
      ),
    ]);
    final report = await DelegationExecutor(
      model: model,
      tools: _tools.where((tool) => tool.name != 'take_screenshot').toList(),
      runTool: _Runner().call,
    ).execute('Type the supplied literal text.');
    expect(report.tools, hasLength(1));
    expect(report.answerText, isEmpty);
  });

  test('model errors become a short failure result', () async {
    final ex = DelegationExecutor(
      model: _Throwing(),
      tools: _tools,
      runTool: _Runner().call,
      latestScreenshot: () => DelegationImage(png: Uint8List(1), capturedAt: DateTime.now()),
    );
    final rep = await ex.execute('anything');
    expect(rep.ok, isFalse);
    expect(rep.resultText, startsWith('Failed:'));
    expect(rep.answerText, isEmpty);
    expect(rep.total, isNotNull);
  });

  test('long results are clipped', () async {
    final r = _Runner()..shot = DelegationImage(png: Uint8List(4), capturedAt: DateTime.now());
    r.result = (n, a) => jsonEncode({'ok': true, 'stdout': 'x' * 10000});
    final m = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('run_bash', {'command': 'yes'}),
        ],
      ),
    ]);
    final rep = await DelegationExecutor(
      model: m,
      tools: _tools,
      runTool: r.call,
      latestScreenshot: () => r.shot,
      maxResultChars: 500,
    ).execute('run yes');
    expect(rep.resultText.length, lessThanOrEqualTo(500));
  });
}

class _Throwing extends DelegationModel {
  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async => throw DelegationModelException('HTTP 500', status: 500);
}
