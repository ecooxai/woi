import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/auth/pkce_login.dart';

String _jwt(Map<String, Object?> claims) {
  String seg(Object o) => base64UrlNoPad(utf8.encode(jsonEncode(o)));
  return '${seg({'alg': 'none'})}.${seg(claims)}.sig';
}

class _FakeOpener implements PlatformUrlOpener {
  final opened = <Uri>[];
  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

/// Fake https://auth.openai.com/oauth/token.
class _FakeTokenServer {
  late HttpServer server;
  final requests = <Map<String, String>>[];
  int status = 200;
  bool apiKeyFails = false;
  final idToken = _jwt({
    'email': 'user@example.com',
    'exp': 4102444800,
    'https://api.openai.com/auth': {'chatgpt_account_id': 'acct-123', 'chatgpt_plan_type': 'plus'},
  });
  final access = _jwt({'exp': 4102444800});

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/oauth/token');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final form = Uri.splitQueryString(await utf8.decodeStream(req));
      requests.add({...form, '_contentType': req.headers.contentType?.mimeType ?? ''});
      final res = req.response..headers.contentType = ContentType.json;
      if (status != 200) {
        res.statusCode = status;
        res.write('{"error":"invalid_grant"}');
      } else if (form['grant_type'] == 'authorization_code') {
        res.write(jsonEncode({'id_token': idToken, 'access_token': access, 'refresh_token': 'rt-1'}));
      } else if (apiKeyFails) {
        res.statusCode = 400;
        res.write('{}');
      } else {
        res.write(jsonEncode({'access_token': 'sk-from-exchange'}));
      }
      await res.close();
    });
  }
}

void main() {
  late Directory tmp;
  late String authPath;
  late _FakeTokenServer tokens;
  late _FakeOpener opener;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('woi-login-test-');
    authPath = '${tmp.path}/codex-home/auth.json';
    tokens = _FakeTokenServer();
    await tokens.start();
    opener = _FakeOpener();
  });

  tearDown(() async {
    await tokens.server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  PkceLoginFlow flow({List<int> ports = const [0], Duration timeout = const Duration(seconds: 20), bool replace = false}) =>
      PkceLoginFlow(
        authPath: authPath,
        opener: opener,
        tokenUrl: tokens.url,
        ports: ports,
        timeout: timeout,
        replaceExisting: replace,
      );

  Future<(int, String)> get(Uri u) async {
    final c = HttpClient();
    try {
      final req = await c.getUrl(u);
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } finally {
      c.close(force: true);
    }
  }

  Uri cb(PkceLoginFlow f, Map<String, String> q) =>
      Uri.parse('http://127.0.0.1:${f.port}/auth/callback').replace(queryParameters: q);

  group('PKCE', () {
    test('RFC 7636 appendix B challenge', () {
      expect(PkceCodes.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('verifier is 64 random bytes base64url (no padding), unique each time', () {
      final a = PkceCodes.generate(), b = PkceCodes.generate();
      expect(a.verifier, hasLength(86));
      expect(RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(a.verifier), isTrue);
      expect(a.challenge, hasLength(43));
      expect(a.challenge, PkceCodes.challengeFor(a.verifier));
      expect(a.verifier, isNot(b.verifier));
      expect(generateOAuthState(), hasLength(43));
    });
  });

  test('authorize URL is byte-identical to codex 0.166.0', () {
    const pkce = PkceCodes('v', 'CHALLENGE');
    final url = buildAuthorizeUrl(redirectUri: loginRedirectUri(1455), pkce: pkce, state: 'STATE');
    // Captured from `codex login` 0.166.0 (temp CODEX_HOME), random parts replaced.
    expect(
      url.toString(),
      'https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann'
      '&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&code_challenge=CHALLENGE'
      '&code_challenge_method=S256&state=STATE'
      '&scope=openid+profile+email+offline_access+api.connectors.read+api.connectors.invoke'
      '&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=codex_cli_rs',
    );
  });

  test('full flow: bad state is rejected, then the code is exchanged and auth.json written', () async {
    final f = flow();
    final url = await f.start();
    expect(opener.opened, [url]);
    expect(url.queryParameters['redirect_uri'], 'http://127.0.0.1:${f.port}/auth/callback');
    expect(url.queryParameters['state'], f.state);
    expect(url.queryParameters['code_challenge'], f.pkce.challenge);

    final (badStatus, badBody) = await get(cb(f, {'code': 'c', 'state': 'forged'}));
    expect(badStatus, 400);
    expect(badBody, 'State mismatch');
    expect(f.isDone, isFalse);
    expect(tokens.requests, isEmpty);

    final (status, page) = await get(cb(f, {'code': 'the-code', 'state': f.state}));
    expect(status, 200);
    expect(page, contains('Signed in'));
    final r = await f.result;
    expect(r.accountId, 'acct-123');
    expect(r.email, 'user@example.com');
    expect(r.apiKeySaved, isTrue);

    final ex = tokens.requests.first;
    expect(ex['_contentType'], 'application/x-www-form-urlencoded');
    expect(ex['grant_type'], 'authorization_code');
    expect(ex['code'], 'the-code');
    expect(ex['code_verifier'], f.pkce.verifier);
    expect(ex['redirect_uri'], f.redirectUri);
    expect(ex['client_id'], kCodexClientId);
    expect(tokens.requests[1]['grant_type'], 'urn:ietf:params:oauth:grant-type:token-exchange');
    expect(tokens.requests[1]['requested_token'], 'openai-api-key');
    expect(tokens.requests[1]['subject_token'], tokens.idToken);

    final json = jsonDecode(File(authPath).readAsStringSync()) as Map<String, Object?>;
    expect(json['auth_mode'], 'chatgpt');
    expect(json['OPENAI_API_KEY'], 'sk-from-exchange');
    expect(json['tokens'], {
      'id_token': tokens.idToken,
      'access_token': tokens.access,
      'refresh_token': 'rt-1',
      'account_id': 'acct-123',
    });
    expect(DateTime.parse(json['last_refresh']! as String).isUtc, isTrue);
    expect((File(authPath).statSync().mode & 0x1ff).toRadixString(8), '600');
    expect(tmp.listSync(recursive: true).where((e) => e.path.endsWith('.tmp')), isEmpty);

    // The existing auth code reads what we wrote.
    final creds = await CodexAuthManager(path: authPath).credentials();
    expect(creds!.bearerToken, tokens.access);
    expect(creds.accountId, 'acct-123');
    expect(await hasValidCodexAuth(authPath), isTrue);
  });

  test('the API key exchange is optional', () async {
    tokens.apiKeyFails = true;
    final f = flow();
    await f.start(openBrowser: false);
    await get(cb(f, {'code': 'x', 'state': f.state}));
    final r = await f.result;
    expect(r.apiKeySaved, isFalse);
    final json = jsonDecode(File(authPath).readAsStringSync()) as Map;
    expect(json.containsKey('OPENAI_API_KEY'), isTrue);
    expect(json['OPENAI_API_KEY'], isNull);
  });

  test('a failed token exchange shows an error page and writes nothing', () async {
    tokens.status = 400;
    final f = flow();
    await f.start(openBrowser: false);
    final (status, page) = await get(cb(f, {'code': 'x', 'state': f.state}));
    expect(status, 200);
    expect(page, contains('Token exchange failed'));
    await expectLater(f.result, throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.exchangeFailed)));
    expect(File(authPath).existsSync(), isFalse);
  });

  test('provider error (user denied) fails the flow', () async {
    final f = flow();
    await f.start(openBrowser: false);
    final (_, page) = await get(cb(f, {'error': 'access_denied', 'error_description': 'User said no', 'state': f.state}));
    expect(page, contains('User said no'));
    await expectLater(f.result, throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.denied)));
  });

  test('cancel(), /cancel and timeout end the flow and free the port', () async {
    final a = flow();
    await a.start(openBrowser: false);
    final port = a.port!;
    a.cancel();
    await expectLater(a.result, throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.cancelled)));

    final b = flow();
    await b.start(openBrowser: false);
    final (status, body) = await get(Uri.parse('http://127.0.0.1:${b.port}/cancel'));
    expect((status, body), (200, 'Login cancelled'));
    await expectLater(b.result, throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.cancelled)));

    final c = flow(timeout: const Duration(milliseconds: 200));
    await c.start(openBrowser: false);
    await expectLater(c.result, throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.timedOut)));

    await Future<void>.delayed(const Duration(milliseconds: 400));
    final again = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await again.close();
  });

  test('falls back to the next registered port when the first is busy', () async {
    final busy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final free = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final freePort = free.port;
    await free.close();
    final f = flow(ports: [busy.port, freePort]);
    final url = await f.start(openBrowser: false);
    expect(f.port, freePort);
    expect(url.queryParameters['redirect_uri'], 'http://127.0.0.1:$freePort/auth/callback');
    f.cancel();
    await expectLater(f.result, throwsA(isA<LoginException>()));

    final g = flow(ports: [busy.port]);
    await expectLater(g.start(), throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.portsBusy)));
    await busy.close();
  });

  test('never replaces a valid auth.json unless asked', () async {
    await writeAuthJsonAtomic(authPath, {
      'tokens': {'access_token': 'a', 'refresh_token': 'keep-me'},
    });
    await expectLater(
      flow().start(openBrowser: false),
      throwsA(isA<LoginException>().having((e) => e.kind, 'kind', LoginFailure.alreadySignedIn)),
    );
    expect(opener.opened, isEmpty);

    final f = flow(replace: true);
    await f.start(openBrowser: false);
    await get(cb(f, {'code': 'x', 'state': f.state}));
    await f.result;
    expect(File(authPath).readAsStringSync(), contains('rt-1'));
  });

  test('hasValidCodexAuth', () async {
    expect(await hasValidCodexAuth('${tmp.path}/missing.json'), isFalse);
    final file = File('${tmp.path}/a.json');
    file.writeAsStringSync('not json');
    expect(await hasValidCodexAuth(file.path), isFalse);
    file.writeAsStringSync(jsonEncode({'OPENAI_API_KEY': 'sk', 'tokens': null}));
    expect(await hasValidCodexAuth(file.path), isFalse);
    file.writeAsStringSync(jsonEncode({'tokens': {'access_token': _jwt({'exp': 1000})}}));
    expect(await hasValidCodexAuth(file.path), isFalse, reason: 'expired, no refresh token');
    file.writeAsStringSync(jsonEncode({'tokens': {'access_token': _jwt({'exp': 4102444800})}}));
    expect(await hasValidCodexAuth(file.path), isTrue);
    file.writeAsStringSync(jsonEncode({'tokens': {'access_token': _jwt({'exp': 1000}), 'refresh_token': 'r'}}));
    expect(await hasValidCodexAuth(file.path), isTrue);
  });
}
