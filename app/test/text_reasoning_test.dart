import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/delegate/responses_delegate.dart';
import 'package:woi/core/responses/reasoning.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

class _Server {
  late HttpServer server;
  final requests = <({String path, Map<String, Object?> body})>[];

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add((path: req.uri.path, body: (jsonDecode(await utf8.decodeStream(req)) as Map).cast()));
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write('data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'Finished.'})}\n\n');
      req.response.write(
        'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {'status': 'completed', 'output': []},
        })}\n\n',
      );
      await req.response.close();
    });
  }
}

void main() {
  for (final authMode in AuthMode.values) {
    test('$authMode text requests use medium by default and the saved effort on subsequent tasks', () async {
      final server = _Server();
      await server.start();
      addTearDown(() => server.server.close(force: true));
      var settings = const AppSettings();
      final client = ResponsesClient(
        credentials: () async => Credentials(mode: authMode, bearerToken: 'fixture-token'),
        codexEndpoint: server.uri('codex'),
        apiKeyEndpoint: server.uri('api'),
      );
      final delegate = ResponsesDelegate(
        client,
        tools: ToolRegistry.new,
        reasoningEffortProvider: () => settings.textReasoningEffort,
      );
      await delegate.runTask('Explain the fixture result.', model: settings.delegateModel);
      expect(server.requests.single.path, authMode == AuthMode.codex ? '/codex' : '/api');
      expect(server.requests.single.body['model'], 'gpt-6-luna');
      expect(server.requests.single.body['reasoning'], {'effort': 'medium'});
      settings = AppSettings.fromJson(settings.copyWith(textReasoningEffort: 'high').toJson());
      await delegate.runTask('Explain the next result.', model: 'gpt-6.1-sol');
      expect(server.requests.last.body['reasoning'], {'effort': 'high'});
      expect(server.requests.last.body['model'], 'gpt-6.1-sol');
      await client.pointerAction(input: [], instructions: 'fixture pointer', tools: const []);
      expect(server.requests.last.body['model'], 'gpt-6-luna');
      expect(server.requests.last.body['reasoning'], {'effort': 'none'}, reason: 'pointer ignores text thinking');
      for (final model in ['gpt-4.1', 'tenant-custom-text-model']) {
        await delegate.runTask('Explain the result.', model: model);
        expect(server.requests.last.body['model'], model);
        expect(
          server.requests.last.body.containsKey('reasoning'),
          isFalse,
          reason: 'unsupported or unverified reasoning must not make this model unusable',
        );
      }
    });
  }

  test('live Responses delegation serializes selected effort at the Codex endpoint', () async {
    final server = _Server();
    await server.start();
    addTearDown(() => server.server.close(force: true));
    final model = ResponsesDelegationModel(
      () async => const Credentials(mode: AuthMode.codex, bearerToken: 'fixture-token'),
      endpoint: server.uri('live-delegation'),
    );
    addTearDown(model.close);
    for (final effort in ['medium', 'low', 'high']) {
      await model.respond(model: 'gpt-6-luna', instructions: 'fixture', input: [], reasoningEffort: effort);
      expect(server.requests.last.path, '/live-delegation');
      expect(server.requests.last.body['reasoning'], {'effort': effort});
    }
    await model.respond(model: 'gpt-4.1', instructions: 'fixture', input: [], reasoningEffort: 'medium');
    expect(server.requests.last.body.containsKey('reasoning'), isFalse);
  });

  test('live delegation reads a changed text thinking preference without restarting voice', () async {
    var settings = const AppSettings();
    final server = FakeLiveServer();
    final rtc = FakeLiveTransport();
    final model = FakeDelegationModel([]);
    final backend = LiveWebRtcBackend(
      transportFactory: () => rtc,
      sideband: server.connect,
      createCall: server.createCall,
      delegationModelFactory: (_) => model,
      delegationReasoningEffortProvider: () => settings.textReasoningEffort,
    )..settleAfterResult = const Duration(milliseconds: 10);
    addTearDown(backend.close);
    await backend.connect(
      const SessionConfig(
        model: 'gpt-live-1.1',
        voice: 'cove',
        instructions: 'fixture',
        credentials: Credentials(mode: AuthMode.codex, bearerToken: 'fixture-token'),
      ),
    );
    server.socket.delegation('task-one', 'Think through the first fixture question.');
    await waitFor(() => model.reasoningEfforts.length == 1);
    expect(model.reasoningEfforts.single, 'medium');
    settings = settings.copyWith(textReasoningEffort: 'high');
    server.socket.delegation('task-two', 'Think through the second fixture question.');
    await waitFor(() => model.reasoningEfforts.length == 2);
    expect(model.reasoningEfforts.last, 'high');
    expect(server.calls, hasLength(1));
  });

  test('unsupported effort fails before sending, while dated model aliases retain capabilities', () {
    expect(textReasoning('gpt-6-luna-2026-08-01', 'none'), {'effort': 'none'});
    expect(textReasoning('gpt-6.1-sol', 'medium'), {'effort': 'medium'});
    expect(() => textReasoning('gpt-6.1-sol', 'none'), throwsArgumentError);
    expect(() => textReasoning('gpt-6-luna', 'minimal'), throwsArgumentError);
    expect(textReasoning('gpt-4.1', 'medium'), isNull);
    expect(textReasoning('gpt-6-luna', null), isNull);
  });
}
