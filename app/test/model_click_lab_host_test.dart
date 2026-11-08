import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/pkce_login.dart';
import 'package:woi/core/lab/model_click_lab.dart';

class _Backend implements ModelClickLabBackend {
  final calls = <String>[];
  final trials = <Map<String, Object?>>[];
  final entered = StreamController<int>.broadcast(sync: true);
  Future<Map<String, Object?>> Function(Map<String, Object?>)? onTrial;
  int closes = 0;

  @override
  Future<Map<String, Object?>> connection() async {
    calls.add('connection');
    return {'backend': 'fake'};
  }

  @override
  Future<Map<String, Object?>> configureConnection(
    Map<String, Object?> input,
  ) async {
    calls.add('configure:${input['backend']}');
    return {'backend': input['backend']};
  }

  @override
  Future<Map<String, Object?>> models({bool refresh = false}) async {
    calls.add('models:$refresh');
    return {'models': <Object?>[], 'refreshed': refresh};
  }

  @override
  Future<Map<String, Object?>> trial(Map<String, Object?> input) async {
    calls.add('trial:${input['request_id']}');
    trials.add(input);
    entered.add(trials.length);
    return await onTrial?.call(input) ??
        {'request_id': input['request_id'], 'ok': true};
  }

  Future<void> waitForTrials(int count) async {
    if (trials.length >= count) return;
    await entered.stream
        .firstWhere((n) => n >= count)
        .timeout(const Duration(seconds: 5));
  }

  @override
  Future<Map<String, Object?>> saveResult(Map<String, Object?> input) async {
    calls.add('result:${input['request_id']}');
    return {'saved': true};
  }

  @override
  Future<void> close() async {
    closes++;
    await entered.close();
  }
}

class _Opener implements PlatformUrlOpener {
  final calls = <({Uri uri, bool keepAlive})>[];
  Future<bool> Function(Uri)? onOpen;

  @override
  Future<bool> open(Uri url, {bool keepAlive = false}) async {
    calls.add((uri: url, keepAlive: keepAlive));
    return await onOpen?.call(url) ?? true;
  }
}

class _Reply {
  _Reply(this.status, this.text, this.headers);
  final int status;
  final String text;
  final HttpHeaders headers;
  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
}

class _Harness {
  _Harness({ModelClickLabAssetLoader? loadAsset}) {
    host = ModelClickLab(
      backend: backend,
      opener: opener,
      loadAsset:
          loadAsset ??
          (name) async => Uint8List.fromList(utf8.encode('bundled $name')),
    );
  }

  final backend = _Backend();
  final opener = _Opener();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  late final ModelClickLab host;
  late Uri launch;
  String get token => Uri.splitQueryString(launch.fragment)['woi_lab_token']!;
  String get origin => 'http://${launch.authority}';

  Future<void> start() async {
    launch = await host.open();
  }

  Future<_Reply> request(
    String path, {
    String method = 'GET',
    bool authorized = true,
    Map<String, String> headers = const {},
    Object? json,
    List<int>? bytes,
    bool chunked = false,
  }) async {
    final request = await client.openUrl(method, launch.resolve(path));
    if (authorized) request.headers.set('X-Woi-Lab-Token', token);
    headers.forEach(request.headers.set);
    final body = bytes ?? (json == null ? null : utf8.encode(jsonEncode(json)));
    if (body != null) {
      if (!headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
        request.headers.contentType = ContentType.json;
      }
      if (chunked) {
        request.headers.chunkedTransferEncoding = true;
      } else {
        request.contentLength = body.length;
      }
      request.add(body);
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Reply(response.statusCode, text, response.headers);
  }

  Future<void> close() async {
    client.close(force: true);
    await host.close();
  }
}

void main() {
  test('loads the packaged UI before launch, coalesces launches, and reuses its loopback host', () async {
    final assets = <String>[];
    final gate = Completer<void>();
    final harness = _Harness(
      loadAsset: (name) async {
        assets.add(name);
        await gate.future;
        return Uint8List.fromList(utf8.encode('bundled $name'));
      },
    );
    addTearDown(harness.close);
    final first = harness.host.open();
    final simultaneous = harness.host.open();
    expect(identical(first, simultaneous), isTrue);
    expect(harness.opener.calls, isEmpty);
    expect(assets, unorderedEquals(['index.html', 'app.js', 'app.css']));
    gate.complete();
    harness.launch = await first;
    expect(await simultaneous, harness.launch);
    expect(harness.launch.host, InternetAddress.loopbackIPv4.address);
    expect(harness.launch.port, isPositive);
    expect(harness.launch.query, isEmpty);
    expect(harness.token.length, greaterThanOrEqualTo(43));
    expect(harness.opener.calls.single.keepAlive, isFalse);
    expect(
      harness.backend.calls,
      isEmpty,
      reason: 'Starting the host does not spend a provider request.',
    );

    final html = await harness.request('/', authorized: false);
    expect(html.status, 200);
    expect(html.text, 'bundled index.html');
    expect(html.text, isNot(contains(harness.token)));
    expect(html.headers.value('cache-control'), 'no-store');
    expect(html.headers.value('referrer-policy'), 'no-referrer');
    expect(
      html.headers.value('content-security-policy'),
      contains("frame-ancestors 'none'"),
    );
    expect((await harness.request('/app.js', authorized: false)).status, 200);
    expect((await harness.request('/app.css', authorized: false)).status, 200);
    expect((await harness.request('/missing', authorized: false)).status, 404);
    expect(await harness.host.open(), harness.launch);
    expect(harness.opener.calls, hasLength(2));
    expect(assets, hasLength(3));

    await harness.host.close();
    await harness.host.close();
    expect(harness.backend.closes, 1);
    await expectLater(
      harness.host.open(),
      throwsA(isA<ModelClickLabException>()),
    );
    await expectLater(
      harness.request('/'),
      throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
    );
  });

  test(
    'reports missing assets and browser failure safely and permits retry',
    () async {
      var missing = true;
      final harness = _Harness(
        loadAsset: (name) async {
          if (missing) throw StateError('private installation path');
          return Uint8List.fromList(utf8.encode(name));
        },
      );
      addTearDown(harness.close);
      await expectLater(
        harness.host.open(),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'assets_unavailable',
          ),
        ),
      );
      expect(harness.opener.calls, isEmpty);
      missing = false;
      harness.opener.onOpen = (_) async => false;
      await expectLater(
        harness.host.open(),
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'browser_unavailable',
          ),
        ),
      );
      final readyUrl = harness.opener.calls.single.uri;
      harness.opener.onOpen = (_) async => true;
      await harness.start();
      expect(harness.launch, readyUrl);
      expect((await harness.request('/api/health')).json['ok'], isTrue);
    },
  );

  test(
    'shutdown during asset loading prevents a late browser launch',
    () async {
      final gate = Completer<void>();
      final harness = _Harness(
        loadAsset: (name) async {
          await gate.future;
          return Uint8List.fromList(utf8.encode(name));
        },
      );
      addTearDown(harness.close);
      final opening = harness.host.open();
      final rejected = expectLater(
        opening,
        throwsA(
          isA<ModelClickLabException>().having(
            (e) => e.code,
            'code',
            'lab_closed',
          ),
        ),
      );
      await harness.host.close();
      gate.complete();
      await rejected;
      expect(harness.opener.calls, isEmpty);
      expect(harness.backend.closes, 1);
    },
  );

  test('Android app navigation may load only the public entry document', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.start();
    const androidNavigation = {
      'Origin': 'android-app://dev.woi.woi',
      'Sec-Fetch-Site': 'cross-site',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Dest': 'document',
    };
    for (final path in ['/', '/index.html']) {
      final response = await harness.request(
        path,
        authorized: false,
        headers: androidNavigation,
      );
      expect(response.status, 200);
      expect(response.text, 'bundled index.html');
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(
        response.headers.value('content-security-policy'),
        contains("frame-ancestors 'none'"),
      );
      expect(response.text, isNot(contains(harness.token)));
    }
    final navigationWithoutOrigin = {...androidNavigation}..remove('Origin');
    expect(
      (await harness.request(
        '/',
        authorized: false,
        headers: navigationWithoutOrigin,
      )).status,
      200,
    );
    final wrongHost = await harness.request(
      '/',
      authorized: false,
      headers: {...androidNavigation, 'Host': 'outside.example'},
    );
    expect(wrongHost.status, 403);
    expect(wrongHost.json['error_code'], 'invalid_host');

    // The external document exception cannot authorize assets, frames, fetches,
    // writes, or API requests, even when a valid runtime token is supplied.
    final missingMode = {...androidNavigation}..remove('Sec-Fetch-Mode');
    final missingDestination = {...androidNavigation}..remove('Sec-Fetch-Dest');
    for (final request in [
      (path: '/', method: 'GET', headers: missingMode),
      (path: '/', method: 'GET', headers: missingDestination),
      (path: '/app.js', method: 'GET', headers: androidNavigation),
      (path: '/app.css', method: 'GET', headers: androidNavigation),
      (path: '/other', method: 'GET', headers: androidNavigation),
      (path: '/api/health', method: 'GET', headers: androidNavigation),
      (path: '/api/connection', method: 'POST', headers: androidNavigation),
      (path: '/', method: 'POST', headers: androidNavigation),
      (
        path: '/index.html',
        method: 'GET',
        headers: {...androidNavigation, 'Sec-Fetch-Mode': 'cors'},
      ),
      (
        path: '/',
        method: 'GET',
        headers: {...androidNavigation, 'Sec-Fetch-Dest': 'iframe'},
      ),
    ]) {
      final response = await harness.request(
        request.path,
        method: request.method,
        headers: request.headers,
      );
      expect(response.status, 403, reason: '${request.method} ${request.path}');
      expect(response.json['error_code'], 'cross_origin');
    }
    final noToken = await harness.request(
      '/api/health',
      authorized: false,
      headers: {'Origin': harness.origin, 'Sec-Fetch-Site': 'same-origin'},
    );
    expect(noToken.status, 403);
    expect(noToken.json['error_code'], 'lab_authorization');
    expect(
      (await harness.request(
        '/api/health',
        headers: {'Origin': harness.origin},
      )).status,
      200,
    );
    expect(harness.backend.calls, isEmpty);
  });

  test('requires launch authorization and local request provenance before any backend call', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.start();
    for (final headers in [
      <String, String>{},
      {'X-Woi-Lab-Token': 'wrong-token'},
      {'X-Woi-Lab-Token': harness.token, 'Origin': 'https://outside.example'},
      {'X-Woi-Lab-Token': harness.token, 'Origin': 'null'},
      {'X-Woi-Lab-Token': harness.token, 'Sec-Fetch-Site': 'cross-site'},
      {'X-Woi-Lab-Token': harness.token, 'Sec-Fetch-Site': 'same-site'},
      {'X-Woi-Lab-Token': harness.token, 'Host': 'outside.example'},
    ]) {
      final response = await harness.request(
        '/api/connection',
        authorized: false,
        headers: headers,
      );
      expect(response.status, 403);
      expect(response.headers.value('access-control-allow-origin'), isNull);
    }
    expect(harness.backend.calls, isEmpty);
    final connection = await harness.request(
      '/api/connection',
      headers: {'Origin': harness.origin, 'Sec-Fetch-Site': 'same-origin'},
    );
    expect(connection.status, 200);
    expect(connection.json['backend'], 'fake');
    expect((await harness.request('/api/models')).json['refreshed'], isFalse);
    expect(
      (await harness.request('/api/models?refresh=1')).json['refreshed'],
      isTrue,
    );
    expect(
      (await harness.request('/api/health')).json['fresh_context'],
      isTrue,
    );
    expect(
      (await harness.request(
        '/api/connection',
        method: 'POST',
        json: {'backend': 'api'},
      )).status,
      200,
    );
    expect(
      (await harness.request(
        '/api/result',
        method: 'POST',
        json: {'request_id': 'result:1'},
      )).status,
      200,
    );
    expect((await harness.request('/api/models', method: 'PUT')).status, 405);
    expect(harness.backend.calls, [
      'connection',
      'models:false',
      'models:true',
      'configure:api',
      'result:result:1',
    ]);
  });

  test('bounds JSON bodies including chunked uploads and validates attempt identity', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.start();
    final wrongType = await harness.request(
      '/api/trial',
      method: 'POST',
      headers: {'Content-Type': 'text/plain'},
      json: {'request_id': 'plain'},
    );
    expect(wrongType.status, 415);
    expect(
      (await harness.request(
        '/api/trial',
        method: 'POST',
        bytes: utf8.encode('{'),
      )).json['error_code'],
      'invalid_json',
    );
    expect(
      (await harness.request(
        '/api/trial',
        method: 'POST',
        json: [1, 2],
      )).json['error_code'],
      'invalid_json',
    );
    for (final id in [null, '', 'with space', '../traversal', 'x' * 129, 7]) {
      final reply = await harness.request(
        '/api/trial',
        method: 'POST',
        json: {'request_id': id},
      );
      expect(reply.json['error_code'], 'invalid_request_id');
    }
    final oversizedResult = {
      'request_id': 'result-too-large',
      'padding': 'a' * (128 * 1024),
    };
    expect(
      (await harness.request(
        '/api/result',
        method: 'POST',
        json: oversizedResult,
      )).status,
      413,
    );
    expect(
      (await harness.request(
        '/api/result',
        method: 'POST',
        json: oversizedResult,
        chunked: true,
      )).status,
      413,
    );
    expect(harness.backend.calls, isEmpty);
    // Screenshots may be larger than result metadata, up to the separate 9 MiB limit.
    expect(
      (await harness.request(
        '/api/trial',
        method: 'POST',
        json: oversizedResult,
        chunked: true,
      )).status,
      200,
    );
    final oversizedTrial = {
      'request_id': 'trial-too-large',
      'padding': 'a' * (9 * 1024 * 1024),
    };
    expect(
      (await harness.request(
        '/api/trial',
        method: 'POST',
        json: oversizedTrial,
      )).status,
      413,
    );
    expect(harness.backend.trials, hasLength(1));
  });

  test('limits concurrent trials, rejects duplicate attempts, and releases a failed trial slot', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.start();
    final gates = List.generate(3, (_) => Completer<Map<String, Object?>>());
    harness.backend.onTrial = (input) =>
        gates[int.parse(input['request_id'] as String)].future;
    final requests = [
      for (var i = 0; i < 3; i++)
        harness.request(
          '/api/trial',
          method: 'POST',
          json: {'request_id': '$i'},
        ),
    ];
    await harness.backend.waitForTrials(3);
    final busy = await harness.request(
      '/api/trial',
      method: 'POST',
      json: {'request_id': 'later'},
    );
    expect(busy.status, 429);
    expect(busy.json['error_code'], 'lab_busy');
    gates[0].completeError(
      StateError('private transport detail must not escape'),
    );
    gates[1].complete({'ok': true});
    gates[2].complete({'ok': true});
    final results = await Future.wait(requests);
    expect(results.map((result) => result.status), [500, 200, 200]);
    expect(results.first.text, isNot(contains('private transport')));
    final duplicate = await harness.request(
      '/api/trial',
      method: 'POST',
      json: {'request_id': '0'},
    );
    expect(duplicate.status, 409);
    expect(duplicate.json['error_code'], 'duplicate_request');
    harness.backend.onTrial = (_) async => {'ok': true};
    expect(
      (await harness.request(
        '/api/trial',
        method: 'POST',
        json: {'request_id': 'later'},
      )).status,
      200,
    );
    expect(harness.backend.trials, hasLength(4));
  });
}
