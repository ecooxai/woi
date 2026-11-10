import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';

const _credentials = Credentials(mode: AuthMode.codex, bearerToken: 'synthetic-token', accountId: 'synthetic-account');
const _search = ToolSpec(name: 'web_search', description: 'lookup', parameters: {'type': 'object'});

String _body(Map<String, Object?> event) => ((event['content']! as List).single as Map)['text'] as String;

List<Map<String, Object?>> _appends(FakeSideband socket) =>
    socket.sent.where((event) => event['type'].toString().endsWith('context.append')).toList();

String _source(FakeSideband socket) => _appends(socket).where((event) => event['channel'] == 'developer').map((event) {
  final body = _body(event);
  return body.substring(body.indexOf('\n') + 1);
}).join();

Future<void> _wait(bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('expected live event did not arrive');
}

class _Rig {
  _Rig({
    List<DelegationModelTurn> turns = const [],
    bool autoAck = true,
    Future<String> Function(String name)? tool,
    this.specs = const [_search],
    this.phone = true,
  }) : model = FakeDelegationModel(List.of(turns)) {
    server.autoAcknowledgeContext = autoAck;
    backend = LiveWebRtcBackend(
      transportFactory: () => FakeLiveTransport(),
      sideband: server.connect,
      createCall: server.createCall,
      delegationModelFactory: (_) => model,
      toolRunner: (id, name, args) async {
        tools.add(name);
        return tool == null ? '{"ok":true}' : await tool(name);
      },
    );
    sub = backend.events.listen(events.add);
  }
  final List<ToolSpec> specs;
  final bool phone;
  final server = FakeLiveServer();
  final FakeDelegationModel model;
  final tools = <String>[];
  final events = <BackendEvent>[];
  late final LiveWebRtcBackend backend;
  late final StreamSubscription<BackendEvent> sub;
  FakeSideband get socket => server.socket;

  Future<void> connect() => backend.connect(
    SessionConfig(
      model: 'gpt-live-1.1',
      voice: 'cove',
      instructions: 'Be brief.',
      tools: specs,
      credentials: _credentials,
      phone: phone,
    ),
  );

  Future<void> dispose() async {
    await backend.close();
    await sub.cancel();
  }
}

void main() {
  test('a long typed message preserves all text and has one response cue', () async {
    final rig = _Rig();
    await rig.connect();
    final text = ['Synthetic user message: ', '東京 👩🏽‍💻 source facts. ' * 50, 'LAST-CHARLIE'].join();
    rig.backend.sendText(text);
    await _wait(() => _appends(rig.socket).any((event) => event['channel'] == null));
    expect(_source(rig.socket), 'The user typed (instead of speaking): $text');
    expect(_appends(rig.socket).where((event) => event['channel'] == null), hasLength(1));
    expect(_appends(rig.socket).every((event) => utf8.encode(_body(event)).length <= 500), isTrue);
    expect(rig.tools, isEmpty);
    await rig.dispose();
  });

  test('typed web search sends its generated result once through the same chunk queue', () async {
    final answer = ['A17=ALPHA. ', 'Synthetic evidence 東京 👩🏽‍💻. ' * 20, ' B29=BRAVO. C43=CHARLIE.'].join();
    final rig = _Rig(
      turns: [
        DelegationModelTurn(
          text: '',
          calls: [
            call('web_search', {'query': 'synthetic marker facts'}),
          ],
        ),
        const DelegationModelTurn(text: 'A17 ALPHA; B29 BRAVO; C43 CHARLIE.', calls: []),
      ],
      tool: (_) async => jsonEncode({
        'ok': true,
        'answer': answer,
        'sources': [
          {'url': 'https://example.test/ALPHA'},
          {'url': 'https://example.test/CHARLIE'},
        ],
      }),
    );
    await rig.connect();
    rig.backend.sendText('Search the web for the synthetic marker facts.');
    await _wait(() => _appends(rig.socket).any((event) => event['channel'] == null));
    expect(rig.tools, ['web_search']);
    final source = _source(rig.socket);
    expect(source, contains(answer));
    expect(source, contains('https://example.test/ALPHA'));
    expect(source, contains('https://example.test/CHARLIE'));
    expect(source, contains('processed the request'));
    expect(_appends(rig.socket).where((event) => event['channel'] == null), hasLength(1));
    expect(rig.socket.ofType('delegation.context.append'), isEmpty);
    await rig.dispose();
  });

  test('image-only input invokes vision once with exact attachments instead of stale screen or camera', () async {
    final rig = _Rig(
      phone: false,
      specs: const [
        ToolSpec(name: 'take_screenshot', description: 'screen', parameters: {'type': 'object'}),
        ToolSpec(name: 'inspect_media', description: 'viewer', parameters: {'type': 'object'}),
      ],
      turns: [const DelegationModelTurn(text: 'The attached image contains the synthetic shapes.', calls: [])],
    );
    final image = Uint8List.fromList([137, 80, 78, 71, 19, 23, 29]);
    rig.backend.setContextImage(
      'attachment:qa-image',
      DelegationImage(png: image, capturedAt: DateTime.now(), note: 'Explicit user attachment: synthetic.png'),
    );
    rig.backend.sendText('The user explicitly attached one file.');
    expect(rig.model.requests, isEmpty, reason: 'No automatic replay before connection.');
    await rig.connect();
    rig.backend.sendImage(Uint8List.fromList([137, 80, 78, 71, 31, 37, 41]), note: 'Unrelated earlier screen');
    rig.backend.setContextImage(
      'camera',
      DelegationImage(
        png: Uint8List.fromList([137, 80, 78, 71, 43, 47]),
        capturedAt: DateTime.now(),
        note: 'Unrelated camera',
      ),
    );
    rig.backend.sendText('The user explicitly attached one file.');
    await _wait(() => _appends(rig.socket).isNotEmpty);
    final input = rig.model.requests.single.input.single['content'] as List;
    final images = input.whereType<Map>().where((c) => c['type'] == 'input_image').toList();
    expect(images, hasLength(1));
    expect(images.single['image_url'], 'data:image/png;base64,${base64Encode(image)}');
    expect(jsonEncode(input), isNot(contains('Unrelated')));
    expect(rig.tools, isEmpty, reason: 'No automatic media inspect or screenshot.');
    rig.backend.sendText('An unrelated ordinary question?');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.model.requests, hasLength(1), reason: 'The attachment trigger is consumed exactly once.');
    await rig.dispose();
  });

  test('explicit image question preserves its web-search intent without substituting the screen', () async {
    final rig = _Rig(
      phone: false,
      specs: const [
        _search,
        ToolSpec(name: 'take_screenshot', description: 'screen', parameters: {'type': 'object'}),
        ToolSpec(name: 'inspect_media', description: 'viewer', parameters: {'type': 'object'}),
      ],
      turns: [
        DelegationModelTurn(
          text: '',
          calls: [
            call('web_search', {'query': 'the depicted subject'}),
          ],
        ),
        const DelegationModelTurn(text: 'The subject and its search result are described.', calls: []),
      ],
    );
    await rig.connect();
    final image = Uint8List.fromList([137, 80, 78, 71, 53, 59, 61]);
    rig.backend.setContextImage(
      'attachment:explicit',
      DelegationImage(png: image, capturedAt: DateTime.now(), note: 'Explicit user attachment'),
    );
    const prompt = 'What is in this image? Search official sources about its subject.';
    rig.backend.sendText(prompt);
    await _wait(() => _appends(rig.socket).isNotEmpty);
    final input = rig.model.requests.first.input.first['content'] as List;
    expect(jsonEncode(input), contains(prompt));
    expect(
      input.whereType<Map>().where((c) => c['type'] == 'input_image').single['image_url'],
      'data:image/png;base64,${base64Encode(image)}',
    );
    expect(rig.tools, ['web_search']);
    expect(rig.model.requests.first.tools.any((t) => t['name'] == 'web_search'), isTrue);
    await rig.dispose();
  });

  test('cancel or cleared draft removes only the pending attachment trigger', () async {
    for (final cancel in [true, false]) {
      final rig = _Rig();
      await rig.connect();
      rig.backend.setContextImage('attachment:pending', DelegationImage(png: Uint8List(4), capturedAt: DateTime.now()));
      if (cancel) {
        rig.backend.cancelPendingTools();
      } else {
        rig.backend.setContextImage('attachment:pending', null);
      }
      rig.backend.sendText('An unrelated ordinary question?');
      await _wait(() => _appends(rig.socket).isNotEmpty);
      expect(rig.model.requests, isEmpty);
      expect(_body(_appends(rig.socket).single), contains('An unrelated ordinary question?'));
      await rig.dispose();
    }
  });

  test('duplicate delegation events never rerun the tool or complete twice', () async {
    final release = Completer<String>();
    final rig = _Rig(
      turns: [
        DelegationModelTurn(
          text: '',
          calls: [
            call('web_search', {'query': 'synthetic source lookup'}),
          ],
        ),
      ],
      tool: (_) => release.future,
    );
    await rig.connect();
    rig.socket.delegation('del_same', 'Search the web for the synthetic source lookup.');
    rig.socket.delegation('del_same', 'Search the web for the synthetic source lookup.');
    await _wait(() => rig.tools.isNotEmpty);
    expect(rig.tools, ['web_search']);
    release.complete(
      jsonEncode({
        'ok': true,
        'answer': ['Evidence ' * 90, 'FINAL_MARKER'].join(),
      }),
    );
    await _wait(() => rig.socket.ofType('delegation.context.append').isNotEmpty);
    rig.socket.delegation('del_same', 'Search the web for the synthetic source lookup.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.tools, ['web_search']);
    expect(rig.socket.ofType('delegation.context.append'), hasLength(1));
    expect(rig.socket.ofType('delegation.context.append').single['delegation_item_id'], 'del_same');
    expect(_source(rig.socket), contains('FINAL_MARKER'));
    await rig.dispose();
  });

  for (final origin in ['typed', 'voice']) {
    test('$origin late cancelled delegation never narrates into a new typed turn', () async {
      final release = Completer<String>();
      final rig = _Rig(
        turns: [
          DelegationModelTurn(
            text: '',
            calls: [
              call('web_search', {'query': 'old cancelled request'}),
            ],
          ),
        ],
        tool: (_) => release.future,
      );
      addTearDown(rig.dispose);
      await rig.connect();
      if (origin == 'typed') {
        rig.backend.sendText('Search the web for the old cancelled request.');
      } else {
        rig.socket.delegation('del_cancelled', 'Search the web for the old cancelled request.');
      }
      await _wait(() => rig.tools.isNotEmpty);
      rig.backend.cancelPendingTools();
      rig.backend.sendText('What is two plus two?');
      expect(_appends(rig.socket), hasLength(1));
      release.complete('{"ok":true,"answer":"OLD_CANCELLED_RESULT_MUST_NOT_NARRATE"}');
      // A zero-duration event turn drains the completed tool's microtasks.
      // No timeout extension or provider receipt is needed to retire it.
      await Future<void>.delayed(Duration.zero);
      expect(_appends(rig.socket), hasLength(1), reason: 'Stop retires the result before it reaches context delivery.');
      expect(_body(_appends(rig.socket).single), contains('What is two plus two?'));
      expect(jsonEncode(rig.socket.sent), isNot(contains('OLD_CANCELLED_RESULT_MUST_NOT_NARRATE')));
      expect(rig.backend.pendingDelegations, 0);
      expect(rig.tools, ['web_search'], reason: 'Already dispatched tools are never replayed.');
    });
  }

  test('explicit cancellation suppresses remaining parts and drains a late receipt', () async {
    final rig = _Rig(autoAck: false);
    await rig.connect();
    rig.backend.sendText(['Synthetic data: ', 'long source data ' * 100].join());
    expect(_appends(rig.socket), hasLength(1));
    rig.backend.cancelPendingTools();
    rig.backend.sendText('A new ordinary question?');
    expect(_appends(rig.socket), hasLength(1));
    rig.socket.push({'type': 'session.context.appended'});
    expect(_appends(rig.socket), hasLength(2));
    expect(_body(_appends(rig.socket).last), contains('A new ordinary question?'));
    rig.socket.push({'type': 'session.context.appended'});
    await Future<void>.delayed(Duration.zero);
    expect(_appends(rig.socket).where((event) => event['channel'] == null), hasLength(1));
    await rig.dispose();
  });

  test('provider rejection is visible and does not send the long result completion', () async {
    final rig = _Rig(autoAck: false);
    await rig.connect();
    rig.backend.sendText(['Synthetic data: ', 'long source data ' * 100].join());
    final event = _appends(rig.socket).single;
    rig.socket.push({
      'type': 'error',
      'error': {
        'event_id': event['event_id'],
        'code': 'invalid_value',
        'param': 'content',
        'message': 'synthetic append rejected',
      },
    });
    await _wait(() => rig.events.whereType<BackendError>().isNotEmpty);
    expect(rig.events.whereType<BackendError>().single.message, contains('synthetic append rejected'));
    expect(_appends(rig.socket), hasLength(1));
    expect(event['channel'], 'developer');
    await rig.dispose();
  });

  test('a late tool result from a lost session is never appended to its replacement', () async {
    final release = Completer<String>();
    final rig = _Rig(
      turns: [
        DelegationModelTurn(
          text: '',
          calls: [
            call('web_search', {'query': 'old request'}),
          ],
        ),
      ],
      tool: (_) => release.future,
    );
    await rig.connect();
    final old = rig.socket;
    old.delegation('del_old', 'Search the web for old request.');
    await _wait(() => rig.tools.isNotEmpty);
    await old.close(1006);
    await rig.connect();
    final fresh = rig.socket;
    release.complete('{"ok":true,"answer":"OLD_SESSION_MUST_NOT_LEAK"}');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(_appends(old), isEmpty);
    expect(_appends(fresh), isEmpty);
    rig.backend.sendText('A fresh ordinary question?');
    await _wait(() => _appends(fresh).isNotEmpty);
    expect(_appends(fresh), hasLength(1));
    expect(_body(_appends(fresh).single), contains('A fresh ordinary question?'));
    expect(jsonEncode(fresh.sent), isNot(contains('OLD_SESSION_MUST_NOT_LEAK')));
    await rig.dispose();
  });
}
