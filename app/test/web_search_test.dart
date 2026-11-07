import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/search/web_search.dart';
import 'package:woi/tools/tool_registry.dart';
import 'package:woi/tools/web_tools.dart';

void main() {
  for (final mode in AuthMode.values) {
    test('hosted search uses selected $mode endpoint and preserves citations', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = Uri.parse('http://127.0.0.1:${server.port}/responses');
      Map<String, Object?>? body;
      final search = {
        'type': 'web_search_call',
        'id': 'search-1',
        'status': 'completed',
        'action': {
          'type': 'search',
          'query': 'Dart Future',
          'sources': [
            {'type': 'url', 'url': 'https://dart.dev/libraries/async/async-await', 'title': 'Asynchronous programming'},
          ],
        },
      };
      server.listen((req) async {
        body = Map<String, Object?>.from(jsonDecode(await utf8.decodeStream(req)) as Map);
        expect(req.headers.value('authorization'), 'Bearer test-secret');
        expect(req.headers.value('chatgpt-account-id'), mode == AuthMode.codex ? 'test-account' : isNull);
        final events = [
          {'type': 'response.output_text.delta', 'delta': 'A Future represents a result.'},
          {'type': 'response.output_item.done', 'item': search},
          {
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [
                search,
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': 'A Future represents a result.',
                      'annotations': [
                        {
                          'type': 'url_citation',
                          'url': 'https://dart.dev/libraries/async/async-await',
                          'title': 'Dart Futures',
                          'start_index': 0,
                          'end_index': 8,
                        },
                        {'type': 'url_citation', 'url': 'javascript:alert(1)', 'title': 'invalid'},
                      ],
                    },
                  ],
                },
              ],
            },
          },
        ];
        req.response.headers.contentType = ContentType('text', 'event-stream');
        for (final e in events) {
          req.response.write('data: ${jsonEncode(e)}\n\n');
        }
        await req.response.close();
      });
      final client = ResponsesClient(
        credentials: () async => Credentials(
          mode: mode,
          bearerToken: 'test-secret',
          accountId: mode == AuthMode.codex ? 'test-account' : null,
        ),
        codexEndpoint: mode == AuthMode.codex ? url : Uri.parse('http://127.0.0.1:1/unused'),
        apiKeyEndpoint: mode == AuthMode.apiKey ? url : Uri.parse('http://127.0.0.1:1/unused'),
      );
      final result = await WebSearchService(client: client, model: () => 'selected-text-model').search('Dart Future');
      expect(result['ok'], isTrue);
      expect(result['sources'], [
        {'url': 'https://dart.dev/libraries/async/async-await', 'title': 'Dart Futures'},
      ]);
      expect(result['search_count'], 1);
      expect(body?['model'], 'selected-text-model');
      expect(body?['tools'], [
        {'type': 'web_search', 'external_web_access': true},
      ]);
      expect(body?['tool_choice'], 'required');
      expect(body?['include'], ['web_search_call.action.sources']);
      expect(body?['store'], isFalse);
      expect(body?['input'], hasLength(1));
    });
  }

  test('disabled web search is removed from advertised tools and blocks stale calls', () async {
    var enabled = true;
    var searches = 0;
    final registry = ToolRegistry()
      ..register(
        webSearchTool(
          enabled: () => enabled,
          search: (q) async {
            searches++;
            return {'ok': true, 'answer': q};
          },
        ),
      );
    expect(registry.specs.single.name, 'web_search');
    enabled = false;
    expect(registry.specs, isEmpty);
    expect(registry.has('web_search'), isFalse);
    expect(registry.names, isEmpty);
    expect((await registry.dispatch('web_search', '{"query":"test"}')).ok, isFalse);
    expect(searches, 0);
    enabled = true;
    expect((await registry.dispatch('web_search', '{"query":"test"}')).ok, isTrue);
    expect(searches, 1);
  });

  test('search refuses an unverified answer without a completed native lookup', () async {
    final service = WebSearchService(client: _NoSearchClient(), model: () => 'model');
    await expectLater(service.search('latest news'), throwsStateError);
    await expectLater(service.search('  '), throwsArgumentError);
  });
}

class _NoSearchClient extends ResponsesClient {
  _NoSearchClient() : super(credentials: () async => null);
  @override
  Future<ResponsesResult> searchWeb({required String model, required String query}) async =>
      ResponsesResult(text: 'Unverified answer', functionCalls: const [], status: 'completed');
}
