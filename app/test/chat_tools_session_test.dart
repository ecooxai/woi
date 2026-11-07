import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/tools/image_tools.dart';
import 'package:woi/tools/tool_registry.dart';
import 'package:woi/tools/web_tools.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

void main() {
  for (final mode in BackendMode.values) {
    test('$mode session exposes image and search tools and refreshes on toggle', () async {
      final platform = await FakePlatform.create();
      final backends = <ScriptedBackend>[];
      final controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () {
          final backend = ScriptedBackend();
          backends.add(backend);
          return backend;
        },
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      addTearDown(() async {
        await controller.shutdown();
        await platform.dispose();
      });
      await controller.init();
      expect(controller.settings.webSearchEnabled, isTrue);
      await controller.updateSettings(controller.settings.copyWith(backendMode: mode, autoScreenshot: false));
      if (backends.isEmpty) await controller.pipeline.connect();
      final enabled = backends.last.config!;
      expect(enabled.tools.map((t) => t.name), containsAll(['web_search', 'generate_image']));
      expect(enabled.instructions, contains('generate_image'));
      expect(enabled.instructions, contains('web_search'));
      if (mode == BackendMode.gptLive) {
        expect(enabled.instructions, contains('image generation also go to delegation'));
      }

      final realtime = RealtimeWsBackend();
      addTearDown(realtime.close);
      final wire = realtime.sessionUpdate(enabled)['session'] as Map;
      expect((wire['tools'] as List).map((t) => t['name']), containsAll(['web_search', 'generate_image']));
      final previous = backends.last;
      await controller.updateSettings(controller.settings.copyWith(webSearchEnabled: false));
      expect(backends.last, isNot(same(previous)));
      final disabled = backends.last.config!;
      expect(disabled.tools.map((t) => t.name), isNot(contains('web_search')));
      expect(disabled.tools.map((t) => t.name), contains('generate_image'));
      expect((await controller.tools.dispatch('web_search', '{"query":"test"}')).ok, isFalse);
      await controller.updateSettings(controller.settings.copyWith(webSearchEnabled: true));
      expect(backends.last.config!.tools.map((t) => t.name), contains('web_search'));
    });
  }

  test('typed image requests and changing facts route to live delegation', () {
    for (final request in [
      'Generate an image of a leaf',
      'Can you draw a cat?',
      'gen image of a green tree',
      'Please illustrate a sunset',
      'Search the internet for Dart documentation',
    ]) {
      expect(looksLikeAction(request), isTrue, reason: request);
    }
    expect(needsWebLookup('What is the latest news?'), isTrue);
    expect(needsWebLookup('What is the weather today?'), isTrue);
    expect(needsWebLookup('Explain a Dart Future'), isFalse);
  });

  test('live delegation sees web results before answering and keeps source URLs', () async {
    final registry = ToolRegistry()
      ..register(
        webSearchTool(
          enabled: () => true,
          search: (q) async => {
            'ok': true,
            'answer': 'A Future holds an asynchronous result.',
            'sources': [
              {'title': 'Dart Future', 'url': 'https://api.dart.dev/dart-async/Future-class.html'},
            ],
          },
        ),
      );
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('web_search', {'query': 'Dart Future docs'}),
        ],
      ),
      const DelegationModelTurn(text: 'The official Dart docs describe Future as an asynchronous result.', calls: []),
    ]);
    final executor = DelegationExecutor(
      model: model,
      tools: registry.specs,
      runTool: (id, name, args) async => (await registry.dispatch(name, args)).json,
      speculativeCapture: false,
    );
    final report = await executor.execute('Search the web for Dart Future documentation', id: 'search-test');
    expect(report.ok, isTrue);
    expect(model.requests, hasLength(2));
    expect(model.requests.first.tools.map((t) => t['name']), contains('web_search'));
    final output = model.requests.last.input.where((item) => item['type'] == 'function_call_output').single;
    expect(output['output'], contains('https://api.dart.dev/dart-async/Future-class.html'));
    expect(report.resultText, contains('official Dart docs'));
  });

  test('live image delegation queues once and does not call it completed', () async {
    var requests = 0;
    final registry = ToolRegistry()
      ..register(
        imageGenerationTool(
          generate: (prompt, size) async {
            requests++;
            return {'ok': true, 'status': 'queued', 'note': 'The image is being generated.'};
          },
        ),
      );
    final model = FakeDelegationModel([
      DelegationModelTurn(
        text: '',
        calls: [
          call('generate_image', {'prompt': 'A green leaf'}),
        ],
      ),
    ]);
    final executor = DelegationExecutor(
      model: model,
      tools: registry.specs,
      runTool: (id, name, args) async => (await registry.dispatch(name, args)).json,
      speculativeCapture: false,
    );
    final report = await executor.execute('Generate an image of a green leaf', id: 'image-test');
    expect(report.ok, isTrue);
    expect(requests, 1);
    expect(report.steps, 1);
    expect(report.resultText, startsWith('Image generation is running in the background.'));
    expect(report.resultText, contains(jsonEncode('queued')));
  });
}
