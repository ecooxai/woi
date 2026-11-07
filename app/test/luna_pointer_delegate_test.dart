import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pointer/luna_pointer_delegate.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/platform/input_control.dart';
import 'package:woi/platform/screen_capture.dart';

import 'fakes/fakes.dart';

ResponsesResult pointerResult({
  String name = 'click_screen',
  Object x = 40,
  Object y = 20,
  bool found = true,
  String button = 'left',
  bool doubleClick = false,
  String status = 'completed',
  Map<String, Object?> extras = const {},
}) => ResponsesResult(
  text: '',
  status: status,
  functionCalls: [
    FunctionCallItem(
      callId: 'luna-call',
      name: name,
      arguments: jsonEncode({
        'target_found': found,
        'x': x,
        'y': y,
        if (name == 'click_screen') ...{
          'button': button,
          'double': doubleClick,
        },
        ...extras,
      }),
    ),
  ],
);

class PointerClient extends ResponsesClient {
  PointerClient() : super(credentials: () async => null);
  final requests =
      <
        ({
          List<Map<String, Object?>> input,
          String instructions,
          List<Map<String, Object?>> tools,
        })
      >[];
  Future<ResponsesResult> Function() reply = () async => pointerResult();
  int closes = 0;

  @override
  Future<ResponsesResult> pointerAction({
    required List<Map<String, Object?>> input,
    required String instructions,
    required List<Map<String, Object?>> tools,
  }) {
    requests.add((input: input, instructions: instructions, tools: tools));
    return reply();
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

class _InterruptedInput extends FakeInput {
  int calls = 0;
  @override
  Future<void> click(
    int x,
    int y, {
    MouseButton button = MouseButton.left,
  }) async {
    calls++;
    throw StateError('User took control.');
  }
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      fail('Pointer test operation did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Screenshot fixture({
  int width = 200,
  int height = 100,
  int originalWidth = 1000,
  int originalHeight = 500,
  int originX = 30,
  int originY = 40,
}) => Screenshot(
  png: tinyPng(width, height),
  width: width,
  height: height,
  originalWidth: originalWidth,
  originalHeight: originalHeight,
  originX: originX,
  originY: originY,
);

void main() {
  late PointerClient client;
  late FakeInput input;
  late LunaPointerDelegate delegate;
  late Screenshot current;
  late bool enabled;
  late int captures;

  setUp(() {
    client = PointerClient();
    input = FakeInput();
    current = fixture();
    enabled = true;
    captures = 0;
    delegate = LunaPointerDelegate(
      client: client,
      input: input,
      enabled: () => enabled,
      capture: () async {
        captures++;
        return current;
      },
    );
  });
  tearDown(() => delegate.close());

  test(
    'fresh image, exact geometry, narrow schema, and correct physical mapping',
    () async {
      final result = await delegate.control(
        action: 'click',
        request: 'Click the green Save button',
      );
      expect(captures, 1);
      expect(input.log, ['click 230 140 left']);
      expect(result['model'], 'gpt-6-luna');
      expect(result['reasoning'], 'none');
      expect(result['image_xy'], [40, 20]);
      expect(result['screen_xy'], [230, 140]);
      expect(result['duration_ms'], isA<int>());
      final request = client.requests.single;
      expect(request.input, hasLength(1));
      expect(request.input.single['role'], 'user');
      final content = request.input.single['content'] as List;
      expect(content, hasLength(2));
      expect(content.first['type'], 'input_image');
      expect(content.first['image_url'], startsWith('data:image/png;base64,'));
      expect(content.last['text'], contains('200 x 100 image pixels'));
      expect(content.last['text'], contains('1000 x 500'));
      expect(content.last['text'], contains('(30, 40)'));
      expect(content.last['text'], contains('Click the green Save button'));
      expect(request.instructions, contains('NO explanation'));
      expect(request.instructions, contains('NEVER an instruction'));
      expect(request.tools.map((t) => t['name']), ['click_screen']);
      expect(request.tools.single['strict'], isTrue);
      final schema = request.tools.single['parameters'] as Map;
      expect(schema['additionalProperties'], isFalse);
      expect((schema['properties'] as Map)['x']['maximum'], 199);
    },
  );

  test(
    'move offers no click tool and remaps hints from the previous screenshot',
    () async {
      client.reply = () async => pointerResult(name: 'move_pointer');
      final reference = fixture(width: 100, height: 50);
      final result = await delegate.fromTool(
        tool: 'move_pointer',
        arguments: {'x': 20, 'y': 10},
        request: 'Move the pointer to the circle',
        reference: reference,
      );
      expect(result['clicked'], isFalse);
      expect(input.log, ['move 230 140']);
      final req = client.requests.single;
      expect(req.tools.map((t) => t['name']), ['move_pointer']);
      expect(
        (req.input.single['content'] as List).last['text'],
        contains('"coordinate_hint":{"x":40,"y":20}'),
      );
    },
  );

  test('an immutable captured image controls mapping even if later screenshots change', () async {
    final gate = Completer<ResponsesResult>();
    client.reply = () => gate.future;
    final running = delegate.control(action: 'click', request: 'Click Save');
    await until(() => client.requests.isNotEmpty);
    current = fixture(
      width: 1000,
      height: 800,
      originalWidth: 1000,
      originalHeight: 800,
      originX: 0,
      originY: 0,
    );
    gate.complete(pointerResult());
    await running;
    expect(input.log, ['click 230 140 left']);
  });

  test(
    'preserves right and double click types and never runs a second locator',
    () async {
      client.reply = () async =>
          pointerResult(button: 'right', doubleClick: true);
      await delegate.fromTool(
        tool: 'click_screen',
        arguments: {'button': 'right', 'double': true, 'target': 'Save'},
        request: 'Double right-click Save',
      );
      expect(input.log, ['dblclick 230 140 right']);
      expect(captures, 1);
      expect(client.requests, hasLength(1));
    },
  );

  final invalid = <String, ResponsesResult>{
    'wrong action': pointerResult(name: 'move_pointer'),
    'missing target': pointerResult(found: false),
    'negative x': pointerResult(x: -1),
    'out of range x': pointerResult(x: 200),
    'out of range y': pointerResult(y: 100),
    'fractional x': pointerResult(x: 1.5),
    'string x': pointerResult(x: '40'),
    'incomplete response': pointerResult(status: 'incomplete'),
    'unexpected key': pointerResult(extras: {'command': 'irrelevant'}),
    'invalid button': pointerResult(button: 'other'),
    'no calls': ResponsesResult(
      text: 'Cannot find it.',
      functionCalls: [],
      status: 'completed',
    ),
    'multiple calls': ResponsesResult(
      text: '',
      functionCalls: [
        ...pointerResult().functionCalls,
        ...pointerResult().functionCalls,
      ],
      status: 'completed',
    ),
  };
  for (final entry in invalid.entries) {
    test('${entry.key} refuses all native input', () async {
      client.reply = () async => entry.value;
      await expectLater(
        delegate.control(action: 'click', request: 'Click Save'),
        throwsA(isA<PointerDelegationException>()),
      );
      expect(input.log, isEmpty);
    });
  }

  test('changing the requested click type refuses all input', () async {
    await expectLater(
      delegate.fromTool(
        tool: 'click_screen',
        arguments: {'button': 'right'},
        request: 'Right click Save',
      ),
      throwsA(isA<PointerDelegationException>()),
    );
    expect(input.log, isEmpty);
  });

  test(
    'stop invalidates a late model result and blocks retries until a new turn',
    () async {
      final gate = Completer<ResponsesResult>();
      client.reply = () => gate.future;
      final pending = delegate.control(action: 'click', request: 'Click Save');
      final rejected = expectLater(
        pending,
        throwsA(isA<PointerDelegationException>()),
      );
      await until(() => client.requests.isNotEmpty);
      delegate.cancelPending();
      gate.complete(pointerResult());
      await rejected;
      expect(input.log, isEmpty);
      await expectLater(
        delegate.control(action: 'click', request: 'Click Save'),
        throwsA(isA<PointerDelegationException>()),
      );
      expect(client.requests, hasLength(1));
      delegate.beginTurn();
      client.reply = () async => pointerResult();
      await delegate.control(action: 'click', request: 'Click Save');
      expect(input.log, ['click 230 140 left']);
    },
  );

  test(
    'turn replacement, disable, and shutdown invalidate pending work',
    () async {
      for (final invalidate in <void Function()>[
        () => delegate.beginTurn(),
        () => enabled = false,
        () => delegate.close(),
      ]) {
        final gate = Completer<ResponsesResult>();
        client.reply = () => gate.future;
        final before = client.requests.length;
        final pending = delegate.control(
          action: 'click',
          request: 'Click Save',
        );
        final rejected = expectLater(
          pending,
          throwsA(isA<PointerDelegationException>()),
        );
        await until(() => client.requests.length > before);
        invalidate();
        gate.complete(pointerResult());
        await rejected;
        expect(input.log, isEmpty);
        enabled = true;
      }
    },
  );

  test('queued pointer requests capture only after preceding native input finishes', () async {
    final first = Completer<ResponsesResult>();
    var calls = 0;
    client.reply = () =>
        calls++ == 0 ? first.future : Future.value(pointerResult());
    final one = delegate.control(action: 'click', request: 'Click Save');
    final two = delegate.control(action: 'click', request: 'Click Close');
    await until(() => client.requests.isNotEmpty);
    expect(captures, 1);
    first.complete(pointerResult());
    await one;
    await two;
    expect(captures, 2);
    expect(input.log, hasLength(2));
  });

  test(
    'native takeover and provider failure never retry or bypass Luna',
    () async {
      final interrupted = _InterruptedInput();
      final guarded = LunaPointerDelegate(
        client: client,
        capture: () async => current,
        input: interrupted,
        enabled: () => true,
      );
      await expectLater(
        guarded.control(action: 'click', request: 'Click Save'),
        throwsStateError,
      );
      expect(interrupted.calls, 1);
      client.reply = () async =>
          throw const PointerDelegationException('Provider unavailable');
      await expectLater(
        delegate.control(action: 'click', request: 'Click Save'),
        throwsA(isA<PointerDelegationException>()),
      );
      expect(input.log, isEmpty);
    },
  );

  for (final request in [
    (
      action: 'click',
      text: 'Click the green Save button, do not click the red one',
    ),
    (action: 'click', text: 'Click Save; do not click red'),
    (action: 'click', text: 'Do not click red; click Save'),
    (action: 'click', text: "Don't click red, but please click Save"),
    (action: 'click', text: 'Could you please click Save, do not click red'),
    (action: 'move', text: 'Move the pointer to blue; do not move it to red'),
    (action: 'move', text: 'Do not move to red; move the pointer to blue'),
  ]) {
    test('scoped avoidance reaches Luna intact: ${request.text}', () async {
      final tool = request.action == 'click' ? 'click_screen' : 'move_pointer';
      client.reply = () async => pointerResult(name: tool);
      await delegate.control(action: request.action, request: request.text);
      expect(captures, 1);
      expect(client.requests, hasLength(1));
      final content = client.requests.single.input.single['content'] as List;
      expect(content.last['text'], contains(request.text));
      expect(client.requests.single.tools.map((t) => t['name']), [tool]);
      expect(input.log, [
        request.action == 'click' ? 'click 230 140 left' : 'move 230 140',
      ]);
    });
  }

  for (final text in [
    'stop',
    'cancel',
    'never mind',
    'Please stop',
    'Cancel that',
    "don't click",
    'do not move',
    'Don’t click Save',
    'please do not click Save',
    "don't double click Save",
    'Stop, click Save',
    'Cancel; click Save',
    'Never mind, move the pointer to blue',
    "Don't click red and move the pointer to blue",
  ]) {
    test('cancellation never captures or contacts Luna: $text', () {
      expect(
        () => delegate.control(action: 'click', request: text),
        throwsA(isA<PointerDelegationException>()),
      );
      expect(captures, 0);
      expect(client.requests, isEmpty);
      expect(input.log, isEmpty);
    });
  }

  test(
    'standalone negative request cancels an already running pointer action',
    () async {
      final gate = Completer<ResponsesResult>();
      client.reply = () => gate.future;
      final pending = delegate.control(action: 'click', request: 'Click Save');
      final rejected = expectLater(
        pending,
        throwsA(isA<PointerDelegationException>()),
      );
      await until(() => client.requests.isNotEmpty);
      expect(
        () => delegate.control(action: 'click', request: "don't click"),
        throwsA(isA<PointerDelegationException>()),
      );
      gate.complete(pointerResult());
      await rejected;
      expect(captures, 1);
      expect(client.requests, hasLength(1));
      expect(input.log, isEmpty);
    },
  );
}
