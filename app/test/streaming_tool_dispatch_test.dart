import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/tool_registry.dart';

const _keysSpec = ToolSpec(
  name: 'send_keys',
  description: 'Press exact keys',
  parameters: {
    'type': 'object',
    'properties': {
      'keys': {'type': 'string'},
    },
    'required': ['keys'],
  },
);

FunctionCallItem _call(String id, [String keys = 'ctrl+c']) =>
    FunctionCallItem(callId: id, name: 'send_keys', arguments: jsonEncode({'keys': keys}));
ResponsesResult _reply([List<FunctionCallItem> calls = const []]) =>
    ResponsesResult(text: calls.isEmpty ? 'Finished.' : '', functionCalls: calls, status: 'completed');
Future<T> _within<T>(Future<T> future) => future.timeout(const Duration(seconds: 5));

ToolRegistry _registry(Future<Map<String, Object?>> Function(Map<String, Object?> args) handler) =>
    ToolRegistry()..register(ToolDefinition(spec: _keysSpec, handler: (args, _) => handler(args)));

class _HeldClient extends ResponsesClient {
  _HeldClient() : super(credentials: () async => null);
  final started = Completer<void>();
  final finish = Completer<ResponsesResult>();
  final inputs = <List<Map<String, Object?>>>[];
  void Function(FunctionCallItem call)? emit;

  @override
  Future<ResponsesResult> create({
    required String model,
    required List<Map<String, Object?>> input,
    String? instructions,
    List<Map<String, Object?>>? tools,
    Map<String, Object?>? reasoning,
    void Function(String delta)? onTextDelta,
    void Function(FunctionCallItem call)? onFunctionCall,
    bool parallelToolCalls = false,
  }) {
    inputs.add((jsonDecode(jsonEncode(input)) as List).cast<Map>().map((e) => e.cast<String, Object?>()).toList());
    if (inputs.length > 1) return Future.value(_reply());
    emit = onFunctionCall;
    started.complete();
    return finish.future;
  }
}

class _HeldModel extends DelegationModel {
  final started = Completer<void>();
  final finish = Completer<DelegationModelTurn>();
  void Function(DelegationToolCall call)? emit;
  int requests = 0;

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) {
    requests++;
    if (requests > 1) return Future.value(DelegationModelTurn(text: 'Finished.', calls: const []));
    emit = onToolCall;
    started.complete();
    return finish.future;
  }
}

class _ObservedResponsesModel extends ResponsesDelegationModel {
  _ObservedResponsesModel(Uri endpoint)
    : super(
        () async => const Credentials(mode: AuthMode.codex, bearerToken: 'fixture-only'),
        endpoint: endpoint,
      );
  final failed = Completer<Object>();

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    try {
      return await super.respond(
        model: model,
        instructions: instructions,
        input: input,
        tools: tools,
        reasoningEffort: reasoningEffort,
        onToolCall: onToolCall,
      );
    } catch (error) {
      failed.complete(error);
      rethrow;
    }
  }
}

DelegationToolCall _liveCall(String id, [String keys = 'ctrl+c']) {
  final c = _call(id, keys);
  return DelegationToolCall(callId: c.callId, name: c.name, arguments: c.arguments);
}

void main() {
  for (final ending in ['incomplete', 'EOF']) {
    test('live $ending stream never runs input queued behind a blocked first call', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final executions = <String>[];
      server.listen((request) async {
        await utf8.decodeStream(request);
        final response = request.response..bufferOutput = false;
        response.headers.contentType = ContentType('text', 'event-stream');
        void event(Map<String, Object?> value) => response.write('data: ${jsonEncode(value)}\n\n');
        for (final call in [_call('first'), _call('queued', 'ctrl+v')]) {
          event({'type': 'response.output_item.done', 'item': call.toInput()});
        }
        await response.flush();
        await firstStarted.future;
        if (ending == 'incomplete') {
          event({
            'type': 'response.incomplete',
            'response': {'status': 'incomplete', 'output': []},
          });
        }
        await response.close();
      });
      final model = _ObservedResponsesModel(Uri.parse('http://127.0.0.1:${server.port}/responses'));
      addTearDown(() async {
        if (!releaseFirst.isCompleted) releaseFirst.complete();
        model.close();
        await server.close(force: true);
      });
      final executor = DelegationExecutor(
        model: model,
        tools: const [_keysSpec],
        runTool: (id, name, args) async {
          executions.add(id);
          firstStarted.complete();
          await releaseFirst.future;
          return '{"ok":true,"delivery":"dispatched"}';
        },
      );
      final result = executor.execute('Perform the requested keyboard task');
      await _within(firstStarted.future);
      expect(await _within(model.failed.future), isA<DelegationModelException>());
      releaseFirst.complete();
      final report = await _within(result);
      expect(report.ok, isFalse);
      expect(report.resultText, contains('incomplete'));
      expect(executions, ['first']);
    });
  }

  test('real SSE starts a complete tool before response end, never from partial arguments', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final partialSent = Completer<void>();
    final sendCompleteCall = Completer<void>();
    final sendFinal = Completer<void>();
    final toolRan = Completer<void>();
    final executions = <String>[];
    final requests = <Map<String, Object?>>[];
    final call = _call('wire-keys', 'ctrl+alt+shift+a');
    final item = {'type': 'function_call', 'id': 'fc_wire', ...call.toInput()};
    void event(HttpResponse response, Map<String, Object?> value) {
      response.write('event: ${value['type']}\ndata: ${jsonEncode(value)}\n\n');
    }

    server.listen((request) async {
      requests.add((jsonDecode(await utf8.decodeStream(request)) as Map).cast<String, Object?>());
      final response = request.response..bufferOutput = false;
      response.headers.contentType = ContentType('text', 'event-stream');
      if (requests.length == 1) {
        event(response, {
          'type': 'response.output_item.added',
          'item': {...item, 'arguments': ''},
        });
        event(response, {'type': 'response.function_call_arguments.delta', 'item_id': 'fc_wire', 'delta': '{"keys":'});
        await response.flush();
        partialSent.complete();
        await sendCompleteCall.future;
        event(response, {'type': 'response.output_item.done', 'item': item});
        await response.flush();
        await sendFinal.future;
        event(response, {
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'output': [item],
          },
        });
      } else {
        event(response, {'type': 'response.output_text.delta', 'delta': 'Keys dispatched.'});
        event(response, {
          'type': 'response.completed',
          'response': {'status': 'completed', 'output': []},
        });
      }
      await response.close();
    });
    final client = ResponsesClient(
      credentials: () async => const Credentials(mode: AuthMode.codex, bearerToken: 'fixture-only'),
      codexEndpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
    );
    addTearDown(() async {
      if (!sendCompleteCall.isCompleted) sendCompleteCall.complete();
      if (!sendFinal.isCompleted) sendFinal.complete();
      client.close();
      await server.close(force: true);
    });
    final registry = _registry((args) async {
      executions.add(args['keys']! as String);
      toolRan.complete();
      return {'ok': true, 'delivery': 'dispatched'};
    });
    final delegate = ResponsesDelegate(client, tools: () => registry);
    var finished = false;
    final result = delegate.runTask('Use the requested shortcut', model: 'fixture').then((result) {
      finished = true;
      return result;
    });
    await _within(partialSent.future);
    expect(executions, isEmpty);
    sendCompleteCall.complete();
    await _within(toolRan.future);
    expect(finished, isFalse);
    expect(sendFinal.isCompleted, isFalse);
    expect(executions, ['ctrl+alt+shift+a']);
    sendFinal.complete();
    expect((await _within(result)).success, isTrue);
    expect(executions, hasLength(1));
    expect(requests, hasLength(2));
    final outputs = (requests.last['input'] as List).where((item) => item['type'] == 'function_call_output');
    expect(outputs, hasLength(1));
    expect(outputs.single['call_id'], 'wire-keys');
  });

  test('generic delegate deduplicates streamed and final-only call IDs and runs serially', () async {
    final client = _HeldClient();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final executions = <String>[];
    final registry = _registry((args) async {
      final keys = args['keys']! as String;
      executions.add(keys);
      if (keys == 'ctrl+c') {
        firstStarted.complete();
        await finishFirst.future;
      }
      return {'ok': true};
    });
    final delegate = ResponsesDelegate(client, tools: () => registry);
    final result = delegate.runTask('Two keyboard actions', model: 'fixture');
    await _within(client.started.future);
    client.emit!(_call('first'));
    client.emit!(_call('first'));
    await _within(firstStarted.future);
    expect(executions, ['ctrl+c']);
    // The second call only appears in the final response, after the first
    // has already started. It must wait until that input operation ends.
    client.finish.complete(_reply([_call('first'), _call('second', 'ctrl+v')]));
    expect(executions, ['ctrl+c']);
    finishFirst.complete();
    expect((await _within(result)).success, isTrue);
    expect(executions, ['ctrl+c', 'ctrl+v']);
    final outputs = client.inputs.last.where((item) => item['type'] == 'function_call_output');
    expect(outputs.map((item) => item['call_id']), ['first', 'second']);
  });

  test('generic cancellation prevents queued and late calls without cancelling completed input twice', () async {
    final client = _HeldClient();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    var epoch = 0;
    final executions = <String>[];
    final registry = _registry((args) async {
      executions.add(args['keys']! as String);
      firstStarted.complete();
      await finishFirst.future;
      return {'ok': true};
    });
    final delegate = ResponsesDelegate(client, tools: () => registry, cancellationEpoch: () => epoch);
    final result = delegate.runTask('Multiple keyboard actions', model: 'fixture');
    await _within(client.started.future);
    client.emit!(_call('first'));
    client.emit!(_call('queued', 'ctrl+v'));
    await _within(firstStarted.future);
    epoch++;
    client.emit!(_call('late', 'ctrl+x'));
    finishFirst.complete();
    client.finish.complete(_reply([_call('first'), _call('queued', 'ctrl+v'), _call('late', 'ctrl+x')]));
    final outcome = await _within(result);
    expect(outcome.success, isFalse);
    expect(outcome.output, contains('cancelled'));
    expect(executions, ['ctrl+c']);
    expect(client.inputs, hasLength(1));
    client.emit!(_call('after-completion', 'ctrl+a'));
    expect(executions, ['ctrl+c']);
  });

  test('generic stream error reports known input and never retries or starts late calls', () async {
    final client = _HeldClient();
    final toolRan = Completer<void>();
    final executions = <String>[];
    final registry = _registry((args) async {
      executions.add(args['keys']! as String);
      toolRan.complete();
      return {'ok': true, 'delivery': 'dispatched'};
    });
    final delegate = ResponsesDelegate(client, tools: () => registry);
    final result = delegate.runTask('A keyboard action', model: 'fixture');
    await _within(client.started.future);
    client.emit!(_call('first'));
    await _within(toolRan.future);
    client.finish.completeError(ResponsesException('stream disconnected'));
    final outcome = await _within(result);
    expect(outcome.success, isFalse);
    expect(outcome.output, contains('Do not repeat'));
    expect(outcome.output, contains('dispatched'));
    client.emit!(_call('late', 'ctrl+v'));
    expect(executions, ['ctrl+c']);
    expect(client.inputs, hasLength(1));
  });

  test('a completed item with invalid JSON cannot reach a tool handler', () async {
    final client = _HeldClient();
    final executions = <String>[];
    final registry = _registry((args) async {
      executions.add(args['keys']! as String);
      return {'ok': true};
    });
    final delegate = ResponsesDelegate(client, tools: () => registry);
    final result = delegate.runTask('A keyboard action', model: 'fixture');
    await _within(client.started.future);
    const malformed = FunctionCallItem(callId: 'bad-json', name: 'send_keys', arguments: '{"keys":');
    client.emit!(malformed);
    client.finish.complete(_reply([malformed]));
    await _within(result);
    expect(executions, isEmpty);
    final output = client.inputs.last.singleWhere((item) => item['type'] == 'function_call_output');
    expect(jsonDecode(output['output']! as String)['ok'], isFalse);
  });

  test('live delegation executes before final response and deduplicates stream/final calls', () async {
    final model = _HeldModel();
    final toolRan = Completer<void>();
    final executions = <String>[];
    final executor = DelegationExecutor(
      model: model,
      tools: const [_keysSpec],
      runTool: (id, name, args) async {
        executions.add(id);
        toolRan.complete();
        return '{"ok":true}';
      },
    );
    final result = executor.execute('Perform the shortcut task');
    await _within(model.started.future);
    model.emit!(_liveCall('first'));
    model.emit!(_liveCall('first'));
    await _within(toolRan.future);
    expect(model.finish.isCompleted, isFalse);
    model.finish.complete(DelegationModelTurn(text: '', calls: [_liveCall('first')]));
    final report = await _within(result);
    expect(report.ok, isTrue);
    expect(executions, ['first']);
    expect(report.tools, hasLength(1));
    expect(model.requests, 2);
    expect(report.answerText, 'Finished.');
  });

  test('live cancellation drops queued calls and ignores late results', () async {
    final model = _HeldModel();
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final executions = <String>[];
    final executor = DelegationExecutor(
      model: model,
      tools: const [_keysSpec],
      runTool: (id, name, args) async {
        executions.add(id);
        firstStarted.complete();
        await finishFirst.future;
        return '{"ok":true}';
      },
    );
    final result = executor.execute('Perform several shortcut tasks');
    await _within(model.started.future);
    model.emit!(_liveCall('first'));
    model.emit!(_liveCall('queued', 'ctrl+v'));
    await _within(firstStarted.future);
    executor.cancelPending();
    model.emit!(_liveCall('late', 'ctrl+x'));
    finishFirst.complete();
    model.finish.complete(DelegationModelTurn(text: '', calls: [_liveCall('first'), _liveCall('queued', 'ctrl+v')]));
    final report = await _within(result);
    expect(report.ok, isFalse);
    expect(report.resultText, contains('cancelled'));
    expect(executions, ['first']);
    model.emit!(_liveCall('after-completion', 'ctrl+a'));
    expect(executions, ['first']);
  });

  test('live stream failure after dispatched input never starts another call', () async {
    final model = _HeldModel();
    final toolRan = Completer<void>();
    final executions = <String>[];
    final executor = DelegationExecutor(
      model: model,
      tools: const [_keysSpec],
      runTool: (id, name, args) async {
        executions.add(id);
        toolRan.complete();
        return '{"ok":true,"delivery":"dispatched"}';
      },
    );
    final result = executor.execute('Perform the shortcut task');
    await _within(model.started.future);
    model.emit!(_liveCall('first'));
    await _within(toolRan.future);
    model.finish.completeError(DelegationModelException('stream disconnected'));
    final report = await _within(result);
    expect(report.ok, isFalse);
    expect(report.resultText, contains('Do not repeat'));
    model.emit!(_liveCall('late', 'ctrl+v'));
    expect(executions, ['first']);
    expect(model.requests, 1);
  });
}
