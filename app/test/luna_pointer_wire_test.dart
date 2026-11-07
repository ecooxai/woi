import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/pointer/luna_pointer_delegate.dart';
import 'package:woi/core/responses/responses_client.dart';

import 'fakes/fakes.dart';

void main() {
  for (final mode in AuthMode.values) {
    test('$mode uses exact Luna, no reasoning, one image, and pointer tools only', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/responses');
      Map<String, Object?>? body;
      server.listen((req) async {
        body = (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, Object?>();
        expect(req.headers.value('authorization'), 'Bearer fixture-token');
        expect(req.headers.value('chatgpt-account-id'), mode == AuthMode.codex ? 'fixture-account' : isNull);
        req.response.headers.contentType = ContentType('text', 'event-stream');
        final call = {
          'type': 'function_call',
          'id': 'fc1',
          'call_id': 'c1',
          'name': 'click_screen',
          'arguments': jsonEncode({'target_found': true, 'x': 80, 'y': 50, 'button': 'left', 'double': false}),
        };
        req.response.write('data: ${jsonEncode({'type': 'response.output_item.done', 'item': call})}\n\n');
        req.response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [call],
            },
          })}\n\n',
        );
        await req.response.close();
      });
      final client = ResponsesClient(
        credentials: () async => Credentials(
          mode: mode,
          bearerToken: 'fixture-token',
          accountId: mode == AuthMode.codex ? 'fixture-account' : null,
        ),
        codexEndpoint: mode == AuthMode.codex ? url : Uri.parse('http://127.0.0.1:1/unused'),
        apiKeyEndpoint: mode == AuthMode.apiKey ? url : Uri.parse('http://127.0.0.1:1/unused'),
      );
      final input = FakeInput();
      final screen = FakeScreen(width: 200, height: 100, originalWidth: 400, originalHeight: 200);
      final pointer = LunaPointerDelegate(
        client: client,
        capture: () => screen.capture(),
        input: input,
        enabled: () => true,
      );
      addTearDown(pointer.close);
      await pointer.control(action: 'click', request: 'Click the test button');
      expect(input.log, ['click 160 100 left']);
      expect(body?['model'], 'gpt-6-luna');
      expect(body?['reasoning'], {'effort': 'none'});
      expect(body?['tool_choice'], 'required');
      expect(body?['parallel_tool_calls'], isFalse);
      expect(body?['store'], isFalse);
      expect(body?['stream'], isTrue);
      expect((body?['tools'] as List).map((t) => t['name']), ['click_screen']);
      expect(body?['input'], hasLength(1));
      final item = (body?['input'] as List).single as Map;
      expect(item['role'], 'user');
      expect((item['content'] as List).where((c) => c['type'] == 'input_image'), hasLength(1));
      expect(body?['instructions'], contains('NO explanation'));
    });
  }
}
