import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/responses_compressor.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/backend_factory.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

String _sse(List<Map<String, Object?>> events) =>
    [for (final e in events) 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n'].join();

Map<String, Object?> _completed({List<Object?> output = const [], int total = 42}) => {
  'type': 'response.completed',
  'response': {
    'status': 'completed',
    'output': output,
    'usage': {'input_tokens': total - 2, 'output_tokens': 2, 'total_tokens': total},
  },
};

List<Map<String, Object?>> _textReply(String text) => [
  {'type': 'response.created', 'response': {}},
  for (final w in text.split(' ')) {'type': 'response.output_text.delta', 'delta': '$w '},
  _completed(),
];

List<Map<String, Object?>> _callReply(String callId, String name, Map<String, Object?> args) {
  final item = {
    'type': 'function_call',
    'id': 'fc_$callId',
    'call_id': callId,
    'name': name,
    'arguments': jsonEncode(args),
  };
  return [
    {'type': 'response.created', 'response': {}},
    {'type': 'response.output_item.done', 'item': item},
    _completed(output: [item]),
  ];
}

/// Local Responses endpoint: no Content-Type, SSE sent in small odd chunks.
class _Server {
  late HttpServer http;
  final requests = <Map<String, Object?>>[];
  final headers = <HttpHeaders>[];
  final replies = <List<Map<String, Object?>>>[];
  int status = 200;
  String errorBody = '';

  /// Pause between the last event and the end of the body (the real server
  /// sends the chunked terminator a little after `response.completed`).
  Duration tailDelay = Duration.zero;
  final clientPorts = <int>[];

  Uri get url => Uri.parse('http://127.0.0.1:${http.port}/responses');

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      requests.add((jsonDecode(await utf8.decodeStream(req)) as Map).cast());
      headers.add(req.headers);
      clientPorts.add(req.connectionInfo!.remotePort);
      final res = req.response..bufferOutput = false; // flush() really sends each chunk
      res.headers.removeAll(HttpHeaders.contentTypeHeader); // like chatgpt.com: no Content-Type
      res.statusCode = status;
      res.headers.set('x-codex-primary-used-percent', '12');
      res.headers.set('x-codex-turn-state', 'secret-state');
      if (status != 200) {
        res.write(errorBody);
      } else {
        final body = utf8.encode(_sse(replies.isEmpty ? _textReply('ok') : replies.removeAt(0)));
        for (var i = 0; i < body.length; i += 37) {
          res.add(body.sublist(i, i + 37 > body.length ? body.length : i + 37));
          await res.flush();
        }
        await Future<void>.delayed(tailDelay);
      }
      await res.close();
    });
  }
}

void main() {
  group('SseParser', () {
    test('handles CRLF, comments, multi-line data and split chunks', () async {
      const raw = ': ping\r\nevent: a\r\ndata: {"x":\r\ndata: 1}\r\n\r\ndata: last';
      final bytes = utf8.encode(raw);
      final chunks = Stream<List<int>>.fromIterable([
        for (var i = 0; i < bytes.length; i += 3) bytes.sublist(i, (i + 3).clamp(0, bytes.length)),
      ]);
      final events = await chunks.transform(const SseParser()).toList();
      expect(events.map((e) => e.event), ['a', null]);
      expect(events.map((e) => e.data), ['{"x":\n1}', 'last']);
    });
  });

  group('ResponsesClient', () {
    late _Server server;
    late ResponsesClient client;
    Credentials creds = const Credentials(mode: AuthMode.codex, bearerToken: 'tok_abc', accountId: 'acct');

    setUp(() async {
      server = _Server();
      await server.start();
      creds = const Credentials(mode: AuthMode.codex, bearerToken: 'tok_abc', accountId: 'acct');
      client = ResponsesClient(credentials: () async => creds, codexEndpoint: server.url, apiKeyEndpoint: server.url);
    });
    tearDown(() => server.http.close(force: true));

    test('streams text without a Content-Type; stream=true, store=false; Codex headers', () async {
      server.replies.add(_textReply('Hello there friend'));
      final deltas = <String>[];
      final r = await client.create(
        model: 'gpt-6-luna',
        input: [
          userMessage([inputText('hi')]),
        ],
        instructions: 'x',
        onTextDelta: deltas.add,
      );
      expect(r.text.trim(), 'Hello there friend');
      expect(deltas, hasLength(3));
      expect(r.status, 'completed');
      expect(r.totalTokens, 42);
      expect(r.timeToFirstToken, isNotNull);
      expect(r.quota, {'x-codex-primary-used-percent': '12'});
      final body = server.requests.single;
      expect(body['stream'], isTrue);
      expect(body['store'], isFalse);
      expect(body['model'], 'gpt-6-luna');
      expect(body.containsKey('previous_response_id'), isFalse);
      final h = server.headers.single;
      expect(h.value('authorization'), 'Bearer tok_abc');
      expect(h.value('chatgpt-account-id'), 'acct');
      expect(h.value('originator'), 'codex_cli_rs');
    });

    test('reuseConnections: returns at response.completed and keeps the connection alive', () async {
      server.tailDelay = const Duration(milliseconds: 300);
      final reuse = ResponsesClient(credentials: () async => creds, codexEndpoint: server.url, reuseConnections: true);
      addTearDown(reuse.close);
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        final r = await reuse.create(
          model: 'gpt-6-luna',
          input: [
            userMessage([inputText('hi $i')]),
          ],
        );
        expect(r.status, 'completed');
        expect(sw.elapsed, lessThan(const Duration(milliseconds: 280)), reason: 'no wait for the body end');
        // Let the background drain finish so the socket goes back to the pool.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      expect(server.clientPorts.toSet(), hasLength(1), reason: 'one kept-alive connection');
    });

    test('collects function calls and outputAsInput replays them without ids', () async {
      server.replies.add(_callReply('c1', 'read_file', {'path': '~/a.txt'}));
      final r = await client.create(
        model: 'm',
        input: [],
        tools: [
          {'type': 'function', 'name': 'read_file'},
        ],
      );
      expect(r.functionCalls.single.name, 'read_file');
      expect(r.outputAsInput.single, {
        'type': 'function_call',
        'call_id': 'c1',
        'name': 'read_file',
        'arguments': '{"path":"~/a.txt"}',
      });
      expect(server.requests.single['tool_choice'], 'auto');
      expect(server.requests.single['parallel_tool_calls'], isFalse);
    });

    test('HTTP errors become ResponsesException with code, tokens redacted', () async {
      server.status = 400;
      server.errorBody = jsonEncode({
        'error': {'code': 'model_not_found', 'message': 'bad model for tok_abc_long_secret'},
      });
      creds = const Credentials(mode: AuthMode.codex, bearerToken: 'tok_abc_long_secret');
      await expectLater(
        client.create(model: 'nope', input: []),
        throwsA(
          isA<ResponsesException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.code, 'code', 'model_not_found'),
        ),
      );
    });

    test('response.failed throws', () async {
      server.replies.add([
        {
          'type': 'response.failed',
          'response': {
            'status': 'failed',
            'error': {'code': 'server_error', 'message': 'boom'},
          },
        },
      ]);
      await expectLater(client.create(model: 'm', input: []), throwsA(isA<ResponsesException>()));
    });

    test('no credentials → error', () async {
      final c = ResponsesClient(credentials: () async => null);
      await expectLater(c.create(model: 'm', input: []), throwsA(isA<ResponsesException>()));
    });

    test('ResponsesDelegate runs the tool loop through the registry (confirmations apply)', () async {
      final fp = await FakePlatform.create();
      addTearDown(fp.dispose);
      final confirm = FakeConfirmations();
      late ToolRegistry registry;
      final delegate = ResponsesDelegate(client, tools: () => registry, reasoningEffort: null);
      registry = ToolRegistry()
        ..registerAll(
          builtinTools(
            ToolEnvironment(
              platform: fp.services,
              confirmations: confirm,
              delegate: delegate,
              settings: () => const AppSettings(),
              onScreenshot: (s, n) async {},
            ),
          ),
        );
      server.replies
        ..add(_callReply('c1', 'write_file', {'path': '~/notes.txt', 'content': 'buy milk\n'}))
        ..add(_callReply('c2', 'run_bash', {'command': 'wc -l ~/notes.txt'}))
        ..add(_textReply('Created notes.txt with one line.'));
      final r = await delegate.runTask('make a notes file', model: 'gpt-6.1-sol', context: 'user said so');
      expect(r.success, isTrue);
      expect(r.output, 'Created notes.txt with one line.');
      expect(r.model, 'gpt-6.1-sol');
      expect(r.tokensUsed, 126);
      expect(confirm.writeRequests, hasLength(1));
      expect(await File('${fp.root.path}/notes.txt').readAsString(), 'buy milk\n');
      expect(fp.shell.commands.single, contains('wc -l'));
      // Second request carries the first call and its output; delegate_task is not offered.
      final second = server.requests[1];
      final input = second['input'] as List;
      expect(input.map((i) => (i as Map)['type']), ['message', 'function_call', 'function_call_output']);
      expect((second['tools'] as List).map((t) => (t as Map)['name']), isNot(contains('delegate_task')));
      expect(jsonEncode(server.requests.first['input']), contains('user said so'));
    });

    test('ResponsesDelegate: denied write is reported back to the model', () async {
      final fp = await FakePlatform.create();
      addTearDown(fp.dispose);
      final confirm = FakeConfirmations(approveWrites: false);
      late ToolRegistry registry;
      final delegate = ResponsesDelegate(client, tools: () => registry, reasoningEffort: null);
      registry = ToolRegistry()
        ..registerAll(
          builtinTools(
            ToolEnvironment(
              platform: fp.services,
              confirmations: confirm,
              delegate: delegate,
              settings: () => const AppSettings(),
              onScreenshot: (s, n) async {},
            ),
          ),
        );
      server.replies
        ..add(_callReply('c1', 'write_file', {'path': '~/x.txt', 'content': 'x'}))
        ..add(_textReply('The user declined.'));
      final r = await delegate.runTask('write x', model: 'm');
      expect(r.output, 'The user declined.');
      expect(File('${fp.root.path}/x.txt').existsSync(), isFalse);
      final out = (server.requests[1]['input'] as List).last as Map;
      expect(out['type'], 'function_call_output');
      expect(out['output'], contains('denied'));
    });

    test('ResponsesCompressor sends transcript + latest screenshots and returns the summary', () async {
      final dir = await Directory.systemTemp.createTemp('woi_comp_');
      addTearDown(() => dir.delete(recursive: true));
      final png = File('${dir.path}/s.png')..writeAsBytesSync(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 1]));
      server.replies.add(_textReply('Facts: user is Bob.'));
      final comp = ResponsesCompressor(client);
      final res = await comp.compress(
        [
          Message(kind: MessageKind.user, text: 'I am Bob, open ~/notes.txt'),
          Message(
            kind: MessageKind.user,
            image: ImageAttachment(path: png.path, width: 2, height: 2, originalWidth: 2, originalHeight: 2),
          ),
          Message(kind: MessageKind.assistant, text: 'Opened it.'),
        ],
        model: 'gpt-6-luna',
        previousSummary: 'Earlier: hello.',
      );
      expect(res.summary.trim(), 'Facts: user is Bob.');
      expect(res.tokensAfter, greaterThan(0));
      final req = server.requests.single;
      expect(req['model'], 'gpt-6-luna');
      final text = jsonEncode(req['input']);
      expect(text, contains('I am Bob'));
      expect(text, contains('Earlier: hello.'));
      expect(text, contains('input_image'));
    });

    test('API key credentials use the API endpoint and only Authorization', () async {
      final other = _Server();
      await other.start();
      addTearDown(() => other.http.close(force: true));
      final c = ResponsesClient(
        credentials: () async => const Credentials(mode: AuthMode.apiKey, bearerToken: 'sk-xyz'),
        codexEndpoint: server.url,
        apiKeyEndpoint: other.url,
      );
      await c.create(model: 'm', input: []);
      expect(server.requests, isEmpty);
      expect(other.headers.single.value('authorization'), 'Bearer sk-xyz');
      expect(other.headers.single.value('chatgpt-account-id'), isNull);
    });
  });

  group('backend factory', () {
    BackendContext ctx(BackendMode mode) => BackendContext(
      settings: const AppSettings().copyWith(backendMode: mode),
      credentials: () async => null,
    );

    tearDown(GptLiveHook.unregister);

    test('gpt-live without a registered hook falls back to direct with a notice', () {
      final s = createVoiceBackend(ctx(BackendMode.gptLive));
      expect(s.backend, isA<RealtimeWsBackend>());
      expect(s.mode, BackendMode.direct);
      expect(s.model, 'gpt-realtime-2');
      expect(s.notice, contains('gpt-live'));
    });

    test('gpt-live uses the registered hook', () {
      final fake = ScriptedBackend();
      GptLiveHook.register((c) => fake);
      final s = createVoiceBackend(ctx(BackendMode.gptLive));
      expect(s.backend, same(fake));
      expect(s.mode, BackendMode.gptLive);
      expect(s.model, const AppSettings().voiceModel);
      expect(s.notice, isNull);
    });

    test('direct and API key modes use the realtime backend', () {
      for (final m in [BackendMode.direct, BackendMode.apiKey]) {
        final s = createVoiceBackend(ctx(m));
        expect(s.backend, isA<RealtimeWsBackend>());
        expect(s.mode, m);
        expect(s.notice, isNull);
      }
    });
  });
}
