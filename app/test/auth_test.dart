import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/settings/settings.dart';

String _jwt(DateTime exp, {String sub = 'u'}) {
  String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'none'})}.${enc({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': sub})}.c2ln';
}

void main() {
  late Directory dir;
  late File file;
  late HttpServer server;
  final requests = <Map<String, Object?>>[];
  var status = 200;
  final now = DateTime.utc(2026, 6, 1, 12);
  late String newAccess;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('woi_auth_');
    file = File('${dir.path}/auth.json');
    requests.clear();
    status = 200;
    newAccess = _jwt(now.add(const Duration(hours: 240)), sub: 'new');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      requests.add({
        'body': jsonDecode(body),
        'ct': req.headers.contentType?.mimeType,
        'originator': req.headers.value('originator'),
      });
      req.response.statusCode = status;
      req.response.write(
        status == 200
            ? jsonEncode({'access_token': newAccess, 'refresh_token': 'rt_rotated_456', 'id_token': 'idt_new_789'})
            : jsonEncode({
                'error': {'code': 'refresh_token_reused', 'message': 'bad rt_old_secret_123'},
              }),
      );
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  Future<void> writeAuth(String access, {String? refresh = 'rt_old_secret_123'}) => file.writeAsString(
    jsonEncode({
      'OPENAI_API_KEY': null,
      'auth_mode': 'chatgpt',
      'tokens': {'id_token': 'idt_old', 'access_token': access, 'refresh_token': ?refresh, 'account_id': 'acct_9'},
      'last_refresh': '2026-05-01T00:00:00Z',
      'extra_key': {'kept': true},
    }),
  );

  CodexAuthManager manager() => CodexAuthManager(
    path: file.path,
    refreshUrl: Uri.parse('http://127.0.0.1:${server.port}/oauth/token'),
    now: () => now,
  );

  test('fresh token: no refresh, Codex headers', () async {
    final access = _jwt(now.add(const Duration(hours: 100)));
    await writeAuth(access);
    final m = manager();
    final c = (await m.credentials())!;
    expect(requests, isEmpty);
    expect(m.refreshCount, 0);
    expect(c.bearerToken, access);
    expect(c.expiresAt, now.add(const Duration(hours: 100)));
    final h = c.headers();
    expect(h['Authorization'], 'Bearer $access');
    expect(h['chatgpt-account-id'], 'acct_9');
    expect(h['originator'], 'codex_cli_rs');
    expect(h['version'], kCodexVersion);
    expect(h['User-Agent'], matches(RegExp(r'^codex_cli_rs/\S+ \(Linux .+; \w+\) woi$')));
    expect(h.containsKey('openai-alpha'), isFalse);
    expect(c.headers(live: true)['openai-alpha'], 'quicksilver=v2');
    expect(c.toString(), isNot(contains(access)));
  });

  test('near expiry: refreshes, persists atomically and keeps other keys', () async {
    await writeAuth(_jwt(now.add(const Duration(minutes: 2))));
    final m = manager();
    final results = await Future.wait([m.credentials(), m.credentials()]);
    expect(requests, hasLength(1), reason: 'single flight');
    expect(requests.single['body'], {
      'client_id': kCodexClientId,
      'grant_type': 'refresh_token',
      'refresh_token': 'rt_old_secret_123',
    });
    expect(requests.single['ct'], 'application/json');
    expect(results.every((c) => c!.bearerToken == newAccess), isTrue);
    expect(m.refreshCount, 1);

    final saved = jsonDecode(await file.readAsString()) as Map;
    final tokens = saved['tokens'] as Map;
    expect(tokens['access_token'], newAccess);
    expect(tokens['refresh_token'], 'rt_rotated_456');
    expect(tokens['id_token'], 'idt_new_789');
    expect(tokens['account_id'], 'acct_9');
    expect(saved['extra_key'], {'kept': true});
    expect(saved['auth_mode'], 'chatgpt');
    expect(DateTime.parse(saved['last_refresh'] as String), now);
    expect((saved['last_refresh'] as String).endsWith('Z'), isTrue);
    final mode = (await file.stat()).mode & 0x1FF;
    expect(mode, 0x180, reason: 'chmod 600');
    expect(dir.listSync().map((e) => e.path.split('/').last), ['auth.json'], reason: 'no tmp left');

    // Next call uses the persisted token without refreshing.
    await m.credentials();
    expect(requests, hasLength(1));
  });

  test('re-reads the file: a token refreshed by Codex meanwhile is used', () async {
    await writeAuth(_jwt(now.add(const Duration(minutes: 1))));
    final m = manager();
    final codexRefreshed = _jwt(now.add(const Duration(hours: 50)), sub: 'codex');
    await writeAuth(codexRefreshed);
    expect((await m.credentials())!.bearerToken, codexRefreshed);
    expect(requests, isEmpty);
  });

  test('refresh failure throws AuthException without leaking tokens', () async {
    await writeAuth(_jwt(now.subtract(const Duration(minutes: 1))));
    status = 401;
    final m = manager();
    await expectLater(
      m.credentials(),
      throwsA(
        isA<AuthException>()
            .having((e) => e.code, 'code', 'refresh_token_reused')
            .having((e) => e.toString(), 'message', isNot(contains('rt_old_secret_123'))),
      ),
    );
  });

  test('missing file → null credentials', () async {
    expect(await manager().credentials(), isNull);
  });

  test('jwtExpiry and redactSecrets', () {
    final t = _jwt(DateTime.utc(2030));
    expect(jwtExpiry(t), DateTime.utc(2030));
    expect(jwtExpiry('not-a-jwt'), isNull);
    final red = redactSecrets('Bearer $t and sk-proj-abcdefghijklmnop1234 and my-secret-value', ['my-secret-value']);
    expect(red, isNot(contains(t)));
    expect(red, isNot(contains('sk-proj-abcdefghijklmnop1234')));
    expect(red, isNot(contains('my-secret-value')));
  });

  test('resolveCredentials: API key mode', () async {
    final c = await resolveCredentials(AuthMode.apiKey, 'sk-test-key-123456');
    expect(c!.headers(), {'Authorization': 'Bearer sk-test-key-123456'});
    if ((Platform.environment['OPENAI_API_KEY'] ?? '').isEmpty) {
      expect(await resolveCredentials(AuthMode.apiKey, ''), isNull);
    }
  });

  test('settings: backend mode round trip and legacy apiKey migration', () {
    const s = AppSettings();
    expect(s.backendMode, BackendMode.gptLive);
    expect(s.realtimeModel, 'gpt-realtime-2');
    final rt = AppSettings.fromJson(s.copyWith(backendMode: BackendMode.direct, realtimeModel: 'x').toJson());
    expect(rt.backendMode, BackendMode.direct);
    expect(rt.realtimeModel, 'x');
    expect(rt.authMode, AuthMode.codex);
    final legacy = AppSettings.fromJson({'authMode': 'apiKey'});
    expect(legacy.backendMode, BackendMode.apiKey);
    expect(legacy.authMode, AuthMode.apiKey);
  });
}
