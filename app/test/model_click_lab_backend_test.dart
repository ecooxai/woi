import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/lab/model_click_lab.dart';
import 'package:woi/core/lab/model_click_lab_backend.dart';
import 'package:woi/core/settings/settings.dart';

const _model = 'gpt-direct-test';
const _secret = 'lab-private-account-secret';
const _otherSecret = 'lab-new-account-secret';
const _action = {
  'type': 'function_call',
  'name': 'screen_action',
  'arguments': '{"action":"click","x":8,"y":9}',
};

void main() {
  late _Provider provider;
  late AppModelClickLabBackend backend;
  late Directory evidence;
  late String currentToken;
  late int credentialLoads;
  final png =
      'data:image/png;base64,${base64Encode(image.encodePng(image.Image(width: 16, height: 16)))}';
  Map<String, Object?> trial({
    String model = _model,
    String tier = 'normal',
    String id = 'test-1',
  }) => {
    'model': model,
    'instruction': 'Click the Amber button.',
    'request_id': id,
    'screenshot': png,
    'width': 16,
    'height': 16,
    'screen': {'width': 800, 'height': 600, 'devicePixelRatio': 2},
    'speed_tier': tier,
  };

  setUp(() async {
    provider = await _Provider.start();
    evidence = await Directory.systemTemp.createTemp('woi-lab-backend-');
    currentToken = _secret;
    credentialLoads = 0;
    backend = AppModelClickLabBackend(
      credentials: (mode) async {
        credentialLoads++;
        return Credentials(mode: mode, bearerToken: currentToken);
      },
      settings: () => const AppSettings(
        backendMode: BackendMode.apiKey,
        delegateModel: _model,
      ),
      evidenceDirectory: evidence,
      apiModelsEndpoint: provider.uri('/models'),
      codexModelsEndpoint: provider.uri('/models'),
      apiResponsesEndpoint: provider.uri('/responses'),
      codexResponsesEndpoint: provider.uri('/responses'),
      realtimeEndpoint: provider.uri('/realtime').replace(scheme: 'ws'),
      trialTimeout: const Duration(seconds: 3),
      flexTimeout: const Duration(seconds: 4),
      catalogTimeout: const Duration(seconds: 2),
    );
  });
  tearDown(() async {
    await backend.close();
    await provider.close();
    if (await evidence.exists()) await evidence.delete(recursive: true);
  });

  test('selected Responses model receives only one screenshot and instruction, preserving tier', () async {
    final result = await backend.trial(trial(tier: 'fast'));
    expect(result['error'], isNull);
    expect(result['model'], _model);
    expect(result['resolved_model'], 'gpt-direct-test-resolved');
    expect(result['x'], 8);
    expect(result['y'], 9);
    expect(result['actual_service_tier'], 'priority');
    expect(result['tier_status'], 'reported');
    final body = provider.responseBodies.single;
    expect(body['model'], _model);
    expect(body['service_tier'], 'priority');
    expect(body['store'], false);
    expect(body['parallel_tool_calls'], false);
    expect(body['tool_choice'], 'required');
    expect(body.keys, isNot(contains('previous_response_id')));
    expect(body.keys, isNot(contains('conversation')));
    expect((body['tools'] as List).single['name'], 'screen_action');
    final input = (body['input'] as List).single;
    final parts = input['content'] as List;
    expect(parts[0]['image_url'], png);
    expect(parts[0]['detail'], 'original');
    expect(parts[1]['text'], contains('Click the Amber button.'));
    expect(body['reasoning'], {'effort': 'low'});
    final timing = result['timing']! as Map;
    expect(timing['upload_measurement'], 'dart_io.request_flush_returned');
    expect(timing['upload_complete_ms'], isA<num>());
    expect(timing['first_token_ms'], isA<num>());
    expect(timing['first_output_source'], 'stream_delta');
    expect(timing['finish_ms'], greaterThanOrEqualTo(timing['first_token_ms']));
    expect(result['request_payload_bytes'], provider.bodyBytes.single);
    expect(
      credentialLoads,
      1,
      reason: 'Catalog and trial share one credential snapshot.',
    );
    final records = await File('${evidence.path}/trials.jsonl').readAsString();
    expect(records, isNot(contains(_secret)));
    expect(records, isNot(contains('data:image')));
    expect(await Directory('${evidence.path}/screenshots').list().length, 1);
  });

  test(
    'setup and empty deltas do not invent a first token for final-only output',
    () async {
      provider.sendDelta = false;
      final result = await backend.trial(trial());
      expect(result['error'], isNull);
      final timing = result['timing']! as Map;
      expect(timing['first_token_ms'], isNull);
      expect(timing['first_output_ms'], isA<num>());
      expect(timing['first_output_source'], 'final_only');
    },
  );

  test(
    'native GPT-Live remains disabled and cannot silently call another model',
    () async {
      final catalog = await backend.models();
      final live = (catalog['models'] as List).singleWhere(
        (m) => m['id'] == 'gpt-live-1.1',
      );
      expect(live['available'], false);
      expect(live['reason'], contains('delegated tools'));
      expect(live['reason'], contains('does not substitute Luna'));
      final result = await backend.trial(trial(model: 'gpt-live-1.1'));
      expect(result['error_code'], 'unsupported_capability');
      expect(result['model'], 'gpt-live-1.1');
      expect(result['resolved_model'], isNull);
      expect(provider.responseBodies, isEmpty);
      expect(provider.sockets, isEmpty);
      expect((result['timing'] as Map)['status'], 'not_started');
    },
  );

  test(
    'unsupported Realtime speed tier is recorded without a provider request',
    () async {
      final result = await backend.trial(
        trial(model: 'gpt-realtime', tier: 'ultrafast'),
      );
      expect(result['error_code'], 'tier_unsupported_transport');
      expect(result['requested_service_tier'], isNull);
      expect(result['tier_status'], 'unsupported');
      expect(provider.responseBodies, isEmpty);
      expect(provider.sockets, isEmpty);
    },
  );

  test('Realtime creates a fresh text-only connection per trial with no history or tier', () async {
    final first = await backend.trial(trial(model: 'gpt-realtime', id: 'ws-1'));
    final second = await backend.trial(
      trial(model: 'gpt-realtime', id: 'ws-2'),
    );
    expect(first['error'], isNull);
    expect(second['error'], isNull);
    expect(provider.sockets.length, 2);
    expect(provider.wsModels, ['gpt-realtime', 'gpt-realtime']);
    for (final events in provider.wsMessages) {
      expect(events.map((e) => e['type']), [
        'session.update',
        'response.create',
      ]);
      final request = events.last['response'] as Map;
      expect(request['conversation'], 'none');
      expect(request['output_modalities'], ['text']);
      expect(request.containsKey('service_tier'), false);
      expect((request['input'] as List).length, 1);
      expect((request['tools'] as List).single['name'], 'screen_action');
    }
    final timing = first['timing'] as Map;
    expect(timing['upload_complete_ms'], isNull);
    expect(timing['upload_duration_ms'], isNull);
    expect(timing['upload_enqueued_ms'], isA<num>());
    expect(timing['upload_measurement'], 'dart_io.websocket_add_enqueued');
    expect(timing['first_token_ms'], isNull);
    expect(timing['first_output_source'], 'final_only');
  });

  test(
    'account settings changes cannot swap in-flight trial credentials',
    () async {
      provider.gate = Completer<void>();
      final running = backend.trial(trial());
      await provider.requestArrived.future.timeout(const Duration(seconds: 5));
      currentToken = _otherSecret;
      await expectLater(
        backend.configureConnection({
          'auth_mode': 'api',
          'api_key': 'temporary-key',
        }),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'connection_busy',
          ),
        ),
      );
      provider.gate!.complete();
      final result = await running;
      expect(result['error'], isNull);
      expect(provider.responseAuth.single, 'Bearer $_secret');
      expect(credentialLoads, 1);
      final next = await backend.trial(trial(id: 'new-account'));
      expect(next['error'], isNull);
      expect(provider.responseAuth.last, 'Bearer $_otherSecret');
      expect(credentialLoads, 2);
    },
  );

  test(
    'temporary key is memory-only, explicit revisions fail stale requests',
    () async {
      final connection = await backend.configureConnection({
        'auth_mode': 'api',
        'api_key': 'temporary-private-key',
      });
      expect(connection['session_key'], true);
      expect(jsonEncode(connection), isNot(contains('temporary-private-key')));
      await expectLater(
        backend.trial({...trial(), 'connection_revision': 0}),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'connection_changed',
          ),
        ),
      );
      final result = await backend.trial({
        ...trial(),
        'connection_revision': connection['revision'],
      });
      expect(result['error'], isNull);
      expect(provider.responseAuth.single, 'Bearer temporary-private-key');
      expect(credentialLoads, 0);
      await backend.configureConnection({'auth_mode': 'api', 'api_key': ''});
      await backend.trial(trial(id: 'stored-key'));
      expect(provider.responseAuth.last, 'Bearer $_secret');
    },
  );

  test(
    'tier rejection is explicit and does not disable normal model use or retry',
    () async {
      provider.rejectTier = true;
      final result = await backend.trial(trial(tier: 'ultrafast'));
      expect(result['error_code'], 'tier_rejected');
      expect(result['tier_status'], 'rejected');
      expect(provider.responseBodies.length, 1);
      final catalog = await backend.models();
      final model = (catalog['models'] as List).singleWhere(
        (m) => m['id'] == _model,
      );
      expect(model['available'], true);
      expect(model['test_status'], 'untested');
      expect(
        model['tier_results']['ultrafast']['test_status'],
        'tier_rejected',
      );
      expect(jsonEncode(result), isNot(contains(_secret)));
    },
  );

  test('validation rejects hidden target/history, malformed PNG and mismatched bounds before auth', () async {
    for (final extra in ['targets', 'history', 'previous_response_id']) {
      await expectLater(
        backend.trial({...trial(), extra: []}),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'unexpected_fields',
          ),
        ),
      );
    }
    await expectLater(
      backend.trial({...trial(), 'width': 17}),
      throwsA(
        isA<ModelClickLabException>().having(
          (e) => e.code,
          'code',
          'dimension_mismatch',
        ),
      ),
    );
    final bytes = base64Decode(png.split(',').last)..[20] ^= 1;
    await expectLater(
      backend.trial({
        ...trial(),
        'screenshot': 'data:image/png;base64,${base64Encode(bytes)}',
      }),
      throwsA(
        isA<ModelClickLabException>().having(
          (e) => e.code,
          'code',
          'invalid_screenshot',
        ),
      ),
    );
    expect(credentialLoads, 0);
    expect(provider.responseBodies, isEmpty);
  });

  test('out of bounds action is not clamped or executed', () async {
    provider.action = {
      ..._action,
      'arguments': '{"action":"click","x":16,"y":9}',
    };
    final result = await backend.trial(trial());
    expect(result['error_code'], 'out_of_bounds');
    expect(result['action'], isNull);
    expect(result['x'], isNull);
  });

  test(
    'close cancels pending provider work and prevents another request',
    () async {
      provider.gate = Completer<void>();
      final running = backend.trial(trial());
      final asserted = expectLater(
        running,
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await provider.requestArrived.future.timeout(const Duration(seconds: 5));
      await backend.close();
      await asserted;
      provider.gate!.complete();
      await expectLater(
        backend.models(),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(await File('${evidence.path}/trials.jsonl').exists(), false);
    },
  );

  test(
    'retained temporary API key never labels or authenticates Codex mode',
    () async {
      await backend.configureConnection({
        'auth_mode': 'api',
        'api_key': 'temporary-private-key',
      });
      final codex = await backend.configureConnection({'auth_mode': 'codex'});
      expect(codex['source'], 'Woi Codex login');
      expect(codex['session_key'], false);
      await backend.trial(trial(id: 'codex-key'));
      expect(provider.responseAuth.single, 'Bearer $_secret');
      final api = await backend.configureConnection({'auth_mode': 'api'});
      expect(api['source'], 'Temporary lab API key');
      expect(api['session_key'], true);
      await backend.trial(trial(id: 'temporary-key-again'));
      expect(provider.responseAuth.last, 'Bearer temporary-private-key');
    },
  );

  test(
    'authentication rejection is sanitized and never retried as another model',
    () async {
      provider.rejectStatus = 401;
      provider.rejectMessage = 'Invalid bearer $_secret';
      final result = await backend.trial(trial());
      expect(result['error_code'], 'authentication_error');
      expect(jsonEncode(result), isNot(contains(_secret)));
      expect(provider.responseBodies.length, 1);
      expect(provider.responseBodies.single['model'], _model);
      expect((result['timing'] as Map)['status'], 'error');
      expect((result['timing'] as Map)['first_token_ms'], isNull);
    },
  );

  test(
    'a stalled provider times out without a retry or fabricated output',
    () async {
      provider.gate = Completer<void>();
      final result = await backend.trial(trial());
      expect(result['error_code'], 'timeout');
      expect(result['action'], isNull);
      expect(provider.responseBodies.length, 1);
      expect((result['timing'] as Map)['status'], 'error');
      expect((result['timing'] as Map)['finish_ms'], isA<num>());
      provider.gate!.complete();
    },
  );

  test(
    'saved scoring evidence strips credentials, histories and image data',
    () async {
      await backend.connection();
      await backend.saveResult({
        'request_id': 'score-1',
        'authorization': _secret,
        'nested': {
          'history': ['private'],
          'api_key': _secret,
          'note': 'echo $_secret',
        },
        'screenshot': png,
      });
      final text = await File('${evidence.path}/results.jsonl').readAsString();
      expect(text, isNot(contains(_secret)));
      expect(text, isNot(contains('private')));
      expect(text, isNot(contains('data:image')));
      expect(provider.responseBodies, isEmpty);
    },
  );
}

class _Provider {
  _Provider(this.server);
  final HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  final responseBodies = <Map<String, Object?>>[];
  final responseAuth = <String?>[];
  final bodyBytes = <int>[];
  final sockets = <WebSocket>[];
  final wsModels = <String?>[];
  final wsMessages = <List<Map<String, Object?>>>[];
  final requestArrived = Completer<void>();
  Completer<void>? gate;
  var sendDelta = true, rejectTier = false;
  int? rejectStatus;
  String? rejectMessage;
  Map<String, Object?> action = {..._action};
  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
  static Future<_Provider> start() async {
    final value = _Provider(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    value.subscription = value.server.listen((request) async {
      await value.handle(request);
    });
    return value;
  }

  Future<void> handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/models') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {
                'id': _model,
                'input_modalities': ['text', 'image'],
                'supports_image_detail_original': true,
                'supported_reasoning_levels': [
                  {'effort': 'low'},
                ],
              },
              {
                'id': 'gpt-realtime',
                'input_modalities': ['text', 'image', 'audio'],
              },
              {
                'id': 'gpt-live-1.1',
                'input_modalities': ['text', 'image'],
                'transport': 'responses',
              },
            ],
          }),
        );
        await request.response.close();
      } else if (request.uri.path == '/realtime') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        wsModels.add(request.uri.queryParameters['model']);
        final events = <Map<String, Object?>>[];
        wsMessages.add(events);
        socket.add(
          jsonEncode({
            'type': 'session.created',
            'session': {'model': 'gpt-realtime'},
          }),
        );
        socket.listen((raw) {
          final event = Map<String, Object?>.from(
            jsonDecode(raw as String) as Map,
          );
          events.add(event);
          if (event['type'] == 'session.update') {
            socket.add(jsonEncode({'type': 'session.updated'}));
          }
          if (event['type'] == 'response.create') {
            socket.add(
              jsonEncode({
                'type': 'response.done',
                'response': {
                  'status': 'completed',
                  'output': [action],
                },
              }),
            );
          }
        });
      } else if (request.uri.path == '/responses') {
        final bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        bodyBytes.add(bytes.length);
        responseBodies.add(
          Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map),
        );
        responseAuth.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
        if (!requestArrived.isCompleted) requestArrived.complete();
        if (gate != null) await gate!.future;
        if (rejectTier || rejectStatus != null) {
          request.response.statusCode = rejectStatus ?? 400;
          request.response.write(
            jsonEncode({
              'error': {
                'message':
                    rejectMessage ??
                    'service_tier ultrafast is unsupported; $_secret',
              },
            }),
          );
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          void emit(Map<String, Object?> event) =>
              request.response.write('data: ${jsonEncode(event)}\n\n');
          emit({
            'type': 'response.created',
            'response': {'model': 'gpt-direct-test-resolved'},
          });
          emit({'type': 'response.function_call_arguments.delta', 'delta': ''});
          if (sendDelta) {
            emit({
              'type': 'response.function_call_arguments.delta',
              'delta': '{',
            });
          }
          emit({
            'type': 'response.completed',
            'response': {
              'model': 'gpt-direct-test-resolved',
              'status': 'completed',
              'service_tier': responseBodies.last['service_tier'],
              'output': [action],
            },
          });
        }
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } on SocketException {
      /* expected when a test closes the backend */
    } on HttpException {
      /* expected when a test closes the backend */
    }
  }

  Future<void> close() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    await subscription.cancel();
    await server.close(force: true);
  }
}
