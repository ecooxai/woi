import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/agents/agent_runs.dart';
import 'package:woi/core/agents/luna_tool_executor.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/usage/model_guard.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/tool_registry.dart';

ResponsesResult completedCall(Map<String, dynamic> request, {Object? arguments}) => ResponsesResult(
  text: '',
  status: 'completed',
  functionCalls: [
    FunctionCallItem(
      callId: 'luna-call',
      name: request['tool'] as String,
      arguments: jsonEncode(arguments ?? request['arguments']),
    ),
  ],
);

class _Client extends ResponsesClient {
  _Client() : super(credentials: () async => null);
  final requests = <Map<String, dynamic>>[];
  Future<ResponsesResult> Function(Map<String, dynamic>)? reply;
  int closes = 0;

  @override
  Future<ResponsesResult> automaticToolAction({
    required List<Map<String, Object?>> input,
    required String instructions,
    required List<Map<String, Object?>> tools,
  }) async {
    final content = input.single['content'] as List;
    final request = (jsonDecode((content.single as Map)['text'] as String) as Map).cast<String, dynamic>();
    expect(tools.single['name'], request['tool']);
    expect(instructions, contains('exact argument object'));
    requests.add(request);
    return await reply?.call(request) ?? completedCall(request);
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

ToolDefinition definition(String name, ToolHandler handler) => ToolDefinition(
  spec: ToolSpec(
    name: name,
    description: 'Synthetic regression tool.',
    parameters: const {
      'type': 'object',
      'properties': {
        'value': {'type': 'string'},
      },
      'required': ['value'],
      'additionalProperties': false,
    },
  ),
  handler: handler,
);

void main() {
  group('automatic Luna tool routing', () {
    late AgentRunStore store;
    late _Client client;
    late LunaToolExecutor executor;
    late ToolRegistry registry;
    var session = 'session-a';

    void configure({int maxConcurrent = 2, Duration timeout = const Duration(seconds: 2)}) {
      executor = LunaToolExecutor(
        store: store,
        clientFactory: () => client,
        conversationId: () => 'conversation',
        sessionIdentity: () => session,
        maxConcurrent: maxConcurrent,
        preparationTimeout: timeout,
      );
      registry = ToolRegistry(interceptor: executor.dispatch);
    }

    setUp(() {
      store = AgentRunStore();
      client = _Client();
      session = 'session-a';
      configure();
    });
    tearDown(() async {
      await executor.shutdown();
      store.dispose();
    });

    test('exact authorized arguments and real output reach parent and history unchanged', () async {
      final arguments = {'value': r"print('a\n'); # literal $HOME and quoted code"};
      final actual = {'ok': true, 'stdout': '42\n', 'stderr': 'diagnostic', 'exit_code': 0, 'ms': 7};
      var executed = 0;
      registry.register(
        definition('python', (args, call) async {
          executed++;
          expect(args, arguments);
          expect(call.automaticallyAuthorized, isTrue);
          return actual;
        }),
      );
      final result = await registry.dispatch('python', jsonEncode(arguments), callId: 'parent-1');
      expect(result.json, jsonEncode(actual));
      expect(result.status, ToolStatus.success);
      expect(executed, 1);
      final run = store.runs.single;
      expect(run.model, kCheapModel);
      expect(run.status, AgentRunStatus.completed);
      expect(run.result, result.json);
      expect(run.steps.single.result, result.json);
      expect(jsonDecode(run.steps.single.arguments), arguments);
      expect(AutomaticToolScope.current, isNull);
    });

    test('tool failure retains stdout stderr exit code and failed status', () async {
      final actual = {'ok': false, 'stdout': 'partial', 'stderr': 'exit failure', 'exit_code': 7, 'ms': 3};
      registry.register(definition('run_bash', (_, _) async => actual));
      final result = await registry.dispatch('run_bash', '{"value":"command"}', callId: 'failure');
      expect(result.json, jsonEncode(actual));
      expect(result.status, ToolStatus.error);
      expect(store.runs.single.status, AgentRunStatus.failed);
      expect(store.runs.single.result, result.json);
    });

    test('same invocation ID executes once but distinct IDs with identical arguments each execute', () async {
      var executions = 0;
      registry.register(definition('read_file', (_, _) async => {'ok': true, 'read': ++executions}));
      final first = registry.dispatch('read_file', '{"value":"same"}', callId: 'original');
      final duplicate = registry.dispatch('read_file', '{"value":"same"}', callId: 'original');
      final results = await Future.wait([first, duplicate]);
      expect(results.first.json, results.last.json);
      expect(executions, 1);
      await registry.dispatch('read_file', '{"value":"same"}', callId: 'second-original');
      expect(executions, 2);
      expect(store.runs, hasLength(2));
      expect(client.requests, hasLength(2));
      final conflict = await registry.dispatch('read_file', '{"value":"changed"}', callId: 'original');
      expect(conflict.ok, isFalse);
      expect(executions, 2);
      session = 'session-b';
      await registry.dispatch('read_file', '{"value":"same"}', callId: 'original');
      expect(executions, 3, reason: 'a new provider session has a new invocation identity');
      await registry.dispatch('read_file', '{"value":"same"}');
      await registry.dispatch('read_file', '{"value":"same"}');
      expect(executions, 5, reason: 'missing provider IDs never deduplicate separate requests');
    });

    test('provider failure never runs local fallback', () async {
      var actions = 0;
      registry.register(definition('python', (_, _) async => {'ok': true, 'n': ++actions}));
      client.reply = (_) async => throw ResponsesException('model unavailable', status: 404);
      final result = await registry.dispatch('python', '{"value":"input"}');
      expect(result.ok, isFalse);
      expect(result.json, contains('404'));
      expect(actions, 0);
      expect(store.runs.single.status, AgentRunStatus.failed);
    });

    test('narration without a call and changed arguments execute nothing', () async {
      var actions = 0;
      registry.register(definition('edit_file', (_, _) async => {'ok': true, 'n': ++actions}));
      client.reply = (_) async => ResponsesResult(text: 'All done', status: 'completed', functionCalls: []);
      expect((await registry.dispatch('edit_file', '{"value":"original"}')).ok, isFalse);
      client.reply = (request) async => completedCall(request, arguments: {'value': 'unauthorized replacement'});
      expect((await registry.dispatch('edit_file', '{"value":"original"}')).ok, isFalse);
      expect(actions, 0);
      expect(store.runs.every((run) => run.status == AgentRunStatus.failed), isTrue);
    });

    test('planning cancellation and late provider completion never execute a tool', () async {
      final gate = Completer<ResponsesResult>();
      var actions = 0;
      registry.register(definition('python', (_, _) async => {'ok': true, 'n': ++actions}));
      client.reply = (_) => gate.future;
      final pending = registry.dispatch('python', '{"value":"late"}', callId: 'cancel');
      await Future<void>.delayed(Duration.zero);
      expect(store.cancel(store.runs.single.id), isTrue);
      final result = await pending;
      expect(jsonDecode(result.json), containsPair('cancelled', true));
      gate.complete(completedCall(client.requests.single));
      await Future<void>.delayed(Duration.zero);
      expect(actions, 0);
      expect(store.runs.single.status, AgentRunStatus.cancelled);
      expect(client.closes, greaterThan(0));
    });

    test('queued cancellation never starts another provider request', () async {
      configure(maxConcurrent: 1);
      final gate = Completer<ResponsesResult>();
      var actions = 0;
      registry.register(definition('read_file', (_, _) async => {'ok': true, 'n': ++actions}));
      client.reply = (_) => gate.future;
      final first = registry.dispatch('read_file', '{"value":"first"}', callId: 'first');
      final second = registry.dispatch('read_file', '{"value":"second"}', callId: 'second');
      await Future<void>.delayed(Duration.zero);
      final queued = store.runs.singleWhere((run) => run.callId == 'second');
      expect(queued.status, AgentRunStatus.queued);
      expect(store.cancel(queued.id), isTrue);
      expect((await second).ok, isFalse);
      expect(client.requests, hasLength(1));
      gate.complete(completedCall(client.requests.single));
      expect((await first).ok, isTrue);
      expect(actions, 1);
    });

    test('preparation timeout prevents late actions and leaves a failed record', () async {
      configure(timeout: const Duration(milliseconds: 5));
      final gate = Completer<ResponsesResult>();
      var actions = 0;
      registry.register(definition('python', (_, _) async => {'ok': true, 'n': ++actions}));
      client.reply = (_) => gate.future;
      final result = await registry.dispatch('python', '{"value":"timeout"}');
      expect(result.ok, isFalse);
      expect(result.json, contains('timed out'));
      gate.complete(completedCall(client.requests.single));
      await Future<void>.delayed(Duration.zero);
      expect(actions, 0);
      expect(store.runs.single.status, AgentRunStatus.failed);
    });

    test('explicit child tools stay in one worker while inherited parent callbacks still route', () async {
      var actions = 0;
      late AutomaticToolScope childScope;
      late Future<ToolOutcome> Function() delayedParent;
      registry.register(
        definition('python', (_, call) async {
          expect(call.automaticallyAuthorized, isTrue);
          return {'ok': true, 'n': ++actions};
        }),
      );
      registry.register(
        definition('delegate_task', (_, _) async {
          childScope = AutomaticToolScope.current!;
          final zone = Zone.current;
          delayedParent = () =>
              zone.run(() => registry.dispatch('python', '{"value":"parent-later"}', callId: 'later'));
          final child = await registry.dispatchFromAgent(
            'python',
            '{"value":"nested"}',
            scope: childScope,
            callId: 'child',
          );
          expect(child.ok, isTrue);
          // This ordinary dispatch deliberately inherits the child Zone while
          // its worker is still active; it must start another tracked Luna run.
          final parent = await registry.dispatch('python', '{"value":"parent-now"}', callId: 'parent');
          return {'ok': parent.ok, 'child': jsonDecode(child.json), 'parent': jsonDecode(parent.json)};
        }),
      );
      expect((await registry.dispatch('delegate_task', '{"value":"work"}', callId: 'delegate')).ok, isTrue);
      expect(client.requests, hasLength(1), reason: 'only the ordinary parent started a planner');
      expect(store.runs, hasLength(2));
      final worker = store.runs.singleWhere((run) => run.toolName == 'delegate_task');
      expect(worker.steps.map((step) => step.toolName), ['delegate_task', 'python']);
      expect((await delayedParent()).ok, isTrue);
      expect(client.requests, hasLength(2));
      expect(store.runs, hasLength(3));
      expect(actions, 3);
      final expired = await registry.dispatchFromAgent('python', '{"value":"expired"}', scope: childScope);
      expect(expired.ok, isFalse);
      expect(actions, 3, reason: 'an expired worker cannot execute another nested action');
    });

    test('pointer worker is tracked without a second planner and app control stays local', () async {
      var pointerCalls = 0;
      registry.register(
        definition('control_pointer', (_, _) async => {'ok': true, 'model': kCheapModel, 'n': ++pointerCalls}),
      );
      registry.register(
        definition('app_control', (_, call) async {
          expect(call.automaticallyAuthorized, isFalse);
          return {'ok': true};
        }),
      );
      expect((await registry.dispatch('control_pointer', '{"value":"click"}')).ok, isTrue);
      expect(pointerCalls, 1);
      expect(client.requests, isEmpty);
      expect(store.runs.single.toolName, 'control_pointer');
      expect((await registry.dispatch('app_control', '{"value":"stop"}')).ok, isTrue);
      expect(store.runs, hasLength(1));
    });
  });

  test('all 121 completed and failed runs survive paging and restart; active work is not replayed', () async {
    final directory = await Directory.systemTemp.createTemp('woi-agents-history-');
    addTearDown(() => directory.delete(recursive: true));
    final first = AgentRunStore(path: directory.path);
    for (var i = 0; i < 121; i++) {
      final run = first.create(task: 'task $i', toolName: 'python', callId: 'call-$i');
      first.markRunning(run);
      first.finish(
        run,
        status: i.isEven ? AgentRunStatus.completed : AgentRunStatus.failed,
        result: jsonEncode({'ok': i.isEven, 'stdout': 'result $i', 'exit_code': i.isEven ? 0 : 1}),
      );
    }
    final interrupted = first.create(task: 'unfinished', toolName: 'run_bash');
    first.markRunning(interrupted);
    interrupted.result = '{"stdout":"partial result"}';
    final completedStep = first.beginStep(interrupted, 'read_file', '{"path":"fixture.txt"}');
    first.finishStep(interrupted, completedStep, '{"ok":true,"text":"completed step"}');
    await first.flush();
    first.dispose();
    final restored = AgentRunStore(path: directory.path, pageSize: 100);
    await restored.restore();
    expect(restored.runs, hasLength(100));
    expect(restored.hasMore, isTrue);
    await restored.loadOlder();
    expect(restored.runs, hasLength(122));
    expect(restored.hasMore, isFalse);
    final recovered = restored.runs.singleWhere((run) => run.id == interrupted.id);
    expect(recovered.status, AgentRunStatus.failed);
    expect(recovered.error, contains('outcome of an already-started action is unknown'));
    expect(recovered.result, '{"stdout":"partial result"}');
    expect(recovered.steps.single.result, '{"ok":true,"text":"completed step"}');
    expect(recovered.canCancel, isFalse);
    expect(restored.activeCount, 0);
    for (var i = 0; i < 121; i++) {
      final run = restored.runs.singleWhere((item) => item.callId == 'call-$i');
      expect(jsonDecode(run.result!)['stdout'], 'result $i');
      expect(run.status, i.isEven ? AgentRunStatus.completed : AgentRunStatus.failed);
    }
    await restored.flush();
    restored.dispose();
  });

  test('real request serialization selects existing Luna model and requires the function', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      received.complete((jsonDecode(await utf8.decodeStream(request)) as Map).cast<String, dynamic>());
      final item = {'type': 'function_call', 'call_id': 'test-call', 'name': 'python', 'arguments': '{"value":"safe"}'};
      final event = {
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': [item],
        },
      };
      final outputEvent = {'type': 'response.output_item.done', 'item': item};
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('event: response.output_item.done\ndata: ${jsonEncode(outputEvent)}\n\n');
      request.response.write('event: response.completed\ndata: ${jsonEncode(event)}\n\n');
      await request.response.close();
    });
    final client = ResponsesClient(
      credentials: () async => const Credentials(mode: AuthMode.apiKey, bearerToken: 'synthetic-local-test-token'),
      apiKeyEndpoint: Uri.parse('http://127.0.0.1:${server.port}/responses'),
    );
    final result = await client.automaticToolAction(
      input: [
        userMessage([inputText('synthetic request')]),
      ],
      instructions: 'Synthetic test only',
      tools: [
        definition('python', (_, _) async => {'ok': true}).spec.toJson(),
      ],
    );
    final body = await received.future;
    expect(body['model'], kCheapModel);
    expect(body['tool_choice'], 'required');
    expect(body['parallel_tool_calls'], isFalse);
    expect(result.functionCalls.single.name, 'python');
    client.close();
  });
}
