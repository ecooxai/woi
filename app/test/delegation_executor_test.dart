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
