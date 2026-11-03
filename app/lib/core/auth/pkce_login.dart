import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'auth.dart';

/// Native "Sign in with ChatGPT" (OAuth 2.0 authorization code + PKCE), the
/// same flow and auth.json format as `codex login` 0.166.0
/// (codex-rs/login/src/server.rs), in Dart so Android can reuse it.

const kCodexIssuer = 'https://auth.openai.com';
const kCodexTokenUrl = '$kCodexIssuer/oauth/token';

/// The two callback ports registered for the Codex client id: the redirect
/// URI must match one of them exactly, so "any free port" is not an option.
const kLoginPorts = [1455, 1457];
const kCodexScopes = 'openid profile email offline_access api.connectors.read api.connectors.invoke';

/// Codex has no login timeout; ten minutes covers a slow sign-in with 2FA.
const kLoginTimeout = Duration(minutes: 10);

String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _randomBytes(int n, Random r) => List<int>.generate(n, (_) => r.nextInt(256));

/// PKCE pair (RFC 7636): 64 random bytes as the verifier (86 chars), S256
/// challenge. Same sizes as codex.
class PkceCodes {
  const PkceCodes(this.verifier, this.challenge);

  factory PkceCodes.generate({Random? random}) {
    final v = base64UrlNoPad(_randomBytes(64, random ?? Random.secure()));
    return PkceCodes(v, challengeFor(v));
  }

  static String challengeFor(String verifier) => base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

  final String verifier;
  final String challenge;
}

/// OAuth `state`: 32 random bytes, base64url.
String generateOAuthState({Random? random}) => base64UrlNoPad(_randomBytes(32, random ?? Random.secure()));

String loginRedirectUri(int port) => 'http://127.0.0.1:$port/auth/callback';

/// Authorize URL with the exact parameters and order `codex login` uses.
Uri buildAuthorizeUrl({
  required String redirectUri,
  required PkceCodes pkce,
  required String state,
  String issuer = kCodexIssuer,
  String clientId = kCodexClientId,
  String originator = kCodexOriginator,
}) {
  final q = [
    ('response_type', 'code'),
    ('client_id', clientId),
    ('redirect_uri', redirectUri),
    ('code_challenge', pkce.challenge),
    ('code_challenge_method', 'S256'),
    ('state', state),
    ('scope', kCodexScopes),
    ('id_token_add_organizations', 'true'),
    ('codex_cli_simplified_flow', 'true'),
    ('originator', originator),
  ].map((e) => '${Uri.encodeQueryComponent(e.$1)}=${Uri.encodeQueryComponent(e.$2)}').join('&');
  return Uri.parse('$issuer/oauth/authorize?$q');
}

/// Opens a URL in the user's browser. Linux: xdg-open. Android will use a
/// Custom Tab behind the same interface.
abstract class PlatformUrlOpener {
  Future<bool> open(Uri url);
}

class XdgUrlOpener implements PlatformUrlOpener {
  const XdgUrlOpener();
  @override
  Future<bool> open(Uri url) async {
    try {
      await Process.start('xdg-open', [url.toString()], mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }
}

PlatformUrlOpener defaultUrlOpener() => const XdgUrlOpener();

enum LoginFailure { cancelled, timedOut, denied, stateMismatch, exchangeFailed, persistFailed, portsBusy, alreadySignedIn }

class LoginException implements Exception {
  const LoginException(this.kind, this.message);
  final LoginFailure kind;
  final String message;
  @override
  String toString() => message;
}

class LoginResult {
  const LoginResult({required this.path, this.accountId, this.email, this.apiKeySaved = false});
  final String path;
  final String? accountId;
  final String? email;
  final bool apiKeySaved;
}

/// True when [path] holds Codex ChatGPT tokens we can use: an access token
/// that has not expired, or a refresh token to get a new one.
Future<bool> hasValidCodexAuth(String path, {DateTime? now}) async {
  try {
    final f = File(path);
    if (!await f.exists()) return false;
    final j = jsonDecode(await f.readAsString());
    if (j is! Map) return false;
    final t = j['tokens'];
    if (t is! Map) return false;
    final access = t['access_token'];
    final refresh = t['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) return true;
    if (access is! String || access.isEmpty) return false;
    final exp = jwtExpiry(access);
    return exp != null && exp.isAfter(now ?? DateTime.now().toUtc());
  } catch (_) {
    return false;
  }
}

/// One sign-in attempt: a loopback server on 127.0.0.1:1455 (or 1457) waits
/// for the browser redirect, exchanges the code and writes auth.json.
///
///     final flow = PkceLoginFlow(authPath: path);
///     await flow.start();            // opens the browser
///     final r = await flow.result;   // LoginResult or LoginException
///     flow.cancel();                 // from the UI
class PkceLoginFlow {
  PkceLoginFlow({
    required this.authPath,
    PlatformUrlOpener? opener,
    this.issuer = kCodexIssuer,
    Uri? tokenUrl,
    this.clientId = kCodexClientId,
    this.ports = kLoginPorts,
    this.timeout = kLoginTimeout,
    this.replaceExisting = false,
    this.obtainApiKey = true,
    HttpClient Function()? httpClient,
    PkceCodes? pkce,
    String? state,
  }) : opener = opener ?? defaultUrlOpener(),
       tokenUrl = tokenUrl ?? Uri.parse('$issuer/oauth/token'),
       _httpClient = httpClient ?? HttpClient.new,
       pkce = pkce ?? PkceCodes.generate(),
       state = state ?? generateOAuthState();

  final String authPath;
  final PlatformUrlOpener opener;
  final String issuer;
  final Uri tokenUrl;
  final String clientId;
  final List<int> ports;
  final Duration timeout;

  /// Overwrite a valid existing auth.json (off: never clobber a login).
  final bool replaceExisting;

  /// Also trade the id token for an API key (OPENAI_API_KEY), like codex.
  final bool obtainApiKey;
  final HttpClient Function() _httpClient;
  final PkceCodes pkce;
  final String state;

  HttpServer? _server;
  Timer? _timer;
  final _done = Completer<LoginResult>();
  bool _exchanging = false;

  int? _port;

  /// The bound callback port (kept after the server closes).
  int? get port => _port;
  String get redirectUri => loginRedirectUri(port ?? ports.first);
  Uri get authorizeUrl =>
      buildAuthorizeUrl(redirectUri: redirectUri, pkce: pkce, state: state, issuer: issuer, clientId: clientId);

  /// Completes with the saved login, or a [LoginException].
  Future<LoginResult> get result => _done.future;
  bool get isDone => _done.isCompleted;

  /// Binds the callback server and opens the browser (unless [openBrowser]
  /// is false). Returns the authorize URL (show it as a fallback link).
  Future<Uri> start({bool openBrowser = true}) async {
    if (!replaceExisting && await hasValidCodexAuth(authPath)) {
      throw const LoginException(LoginFailure.alreadySignedIn, 'Already signed in (a valid auth.json exists).');
    }
    // Callers may only await [result] later; never surface it as unhandled.
    unawaited(_done.future.then((_) {}, onError: (Object _) {}));
    _server = await _bind();
    _port = _server!.port;
    _server!.listen(_handle, onError: (Object _) {});
    _timer = Timer(timeout, () => _fail(LoginFailure.timedOut, 'Sign-in timed out after ${timeout.inMinutes} min.'));
    final url = authorizeUrl;
    if (openBrowser) await opener.open(url);
    return url;
  }

  void cancel() => _fail(LoginFailure.cancelled, 'Sign-in cancelled.');

  Future<HttpServer> _bind() async {
    for (final port in ports) {
      try {
        // IPv4 loopback only, like codex (the redirect URI says 127.0.0.1).
        return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        continue;
      }
    }
    throw LoginException(
      LoginFailure.portsBusy,
      'Ports ${ports.join(' and ')} are in use (another sign-in running?). Close it and retry.',
    );
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/auth/callback':
          await _callback(req.uri.queryParameters, res);
        case '/cancel':
          _send(res, 200, 'Login cancelled', type: ContentType.text);
          cancel();
        default:
          _send(res, 404, 'Not Found', type: ContentType.text);
      }
    } catch (e) {
      _send(res, 500, 'Internal error', type: ContentType.text);
    }
  }

  Future<void> _callback(Map<String, String> q, HttpResponse res) async {
    if (_done.isCompleted || _exchanging) {
      _send(res, 409, 'Sign-in is no longer pending.', type: ContentType.text);
      return;
    }
    // A wrong state is someone else's request: reject it and keep waiting.
    if (q['state'] != state) {
      _send(res, 400, 'State mismatch', type: ContentType.text);
      return;
    }
    final error = q['error'];
    if (error != null && error.isNotEmpty) {
      final desc = q['error_description'];
      final msg = 'Sign-in failed: ${desc != null && desc.trim().isNotEmpty ? desc : error}';
      _send(res, 200, _page('Sign-in failed', msg, ok: false));
      _fail(LoginFailure.denied, msg);
      return;
    }
    final code = q['code'];
    if (code == null || code.isEmpty) {
      const msg = 'Missing authorization code. Sign-in could not be completed.';
      _send(res, 400, _page('Sign-in failed', msg, ok: false));
      _fail(LoginFailure.denied, msg);
      return;
    }
    _exchanging = true;
    final Map<String, Object?> tokens;
    try {
      tokens = await _exchange(code);
    } catch (e) {
      final msg = 'Token exchange failed: ${redactSecrets('$e', [code])}';
      _send(res, 200, _page('Sign-in failed', msg, ok: false));
      _fail(LoginFailure.exchangeFailed, msg);
      return;
    }
    String? apiKey;
    if (obtainApiKey) {
      try {
        apiKey = await _apiKeyFor(tokens['id_token']! as String);
      } catch (_) {
        // Optional in codex too: ChatGPT tokens alone are enough.
      }
    }
    final LoginResult saved;
    try {
      saved = await _persist(tokens, apiKey);
    } catch (e) {
      final msg = 'Signed in, but the credentials could not be saved: $e';
      _send(res, 200, _page('Sign-in failed', msg, ok: false));
      _fail(LoginFailure.persistFailed, msg);
      return;
    }
    _send(res, 200, _page('Signed in to Woi', 'You can close this tab and return to Woi.', ok: true));
    _finish(saved);
  }

  Future<Map<String, Object?>> _exchange(String code) async {
    final body = _form({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': clientId,
      'code_verifier': pkce.verifier,
    });
    final j = await _postForm(body);
    final id = j['id_token'], access = j['access_token'], refresh = j['refresh_token'];
    if (id is! String || access is! String || refresh is! String || id.isEmpty || access.isEmpty) {
      throw const FormatException('token response is missing id_token / access_token / refresh_token');
    }
    return {'id_token': id, 'access_token': access, 'refresh_token': refresh};
  }

  Future<String> _apiKeyFor(String idToken) async {
    final j = await _postForm(
      _form({
        'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
        'client_id': clientId,
        'requested_token': 'openai-api-key',
        'subject_token': idToken,
        'subject_token_type': 'urn:ietf:params:oauth:token-type:id_token',
      }),
    );
    final key = j['access_token'];
    if (key is! String || key.isEmpty) throw const FormatException('no api key in token-exchange response');
    return key;
  }

  static String _form(Map<String, String> m) =>
      m.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  Future<Map<String, Object?>> _postForm(String body) async {
    final client = _httpClient();
    try {
      final req = await client.postUrl(tokenUrl).timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.headers.set('Accept', 'application/json');
      req.headers.set('User-Agent', codexUserAgent());
      req.headers.set('originator', kCodexOriginator);
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 60));
      final text = await utf8.decodeStream(res);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: ${text.length > 300 ? text.substring(0, 300) : text}');
      }
      final j = jsonDecode(text);
      if (j is! Map) throw const FormatException('token endpoint returned a non-object');
      return j.cast<String, Object?>();
    } finally {
      client.close(force: true);
    }
  }

  /// auth.json in the codex schema, written atomically with mode 0600.
  Future<LoginResult> _persist(Map<String, Object?> tokens, String? apiKey) async {
    if (!replaceExisting && await hasValidCodexAuth(authPath)) {
      throw const LoginException(LoginFailure.alreadySignedIn, 'a valid auth.json appeared meanwhile');
    }
    final idToken = tokens['id_token']! as String;
    final claims = jwtClaims(idToken) ?? const {};
    final auth = claims['https://api.openai.com/auth'];
    final accountId = auth is Map ? auth['chatgpt_account_id'] as String? : null;
    final json = <String, Object?>{
      'auth_mode': 'chatgpt',
      'OPENAI_API_KEY': apiKey,
      'tokens': {...tokens, 'account_id': accountId},
      'last_refresh': DateTime.now().toUtc().toIso8601String(),
    };
    await writeAuthJsonAtomic(authPath, json);
    return LoginResult(
      path: authPath,
      accountId: accountId,
      email: claims['email'] as String?,
      apiKeySaved: apiKey != null,
    );
  }

  void _send(HttpResponse res, int status, String body, {ContentType? type}) {
    try {
      res
        ..statusCode = status
        ..headers.contentType = type ?? ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Connection', 'close')
        ..write(body);
      unawaited(res.close().then((_) {}, onError: (Object _) {}));
    } catch (_) {}
  }

  void _finish(LoginResult r) {
    if (_done.isCompleted) return;
    _done.complete(r);
    _shutdown();
  }

  void _fail(LoginFailure kind, String msg) {
    if (_done.isCompleted) return;
    _done.completeError(LoginException(kind, msg));
    _shutdown();
  }

  void _shutdown() {
    _timer?.cancel();
    final s = _server;
    _server = null;
    // Let the last response flush before closing the socket.
    if (s != null) Timer(const Duration(milliseconds: 200), () => s.close(force: true));
  }

  static String _page(String title, String message, {required bool ok}) {
    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final accent = ok ? '#1a7f37' : '#cf222e';
    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:#fafafa;color:#1f2328;
       font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
  .card{max-width:420px;padding:36px 40px;background:#fff;border:1px solid #e5e7eb;border-radius:14px;text-align:center}
  .dot{width:44px;height:44px;border-radius:50%;margin:0 auto 16px;display:grid;place-items:center;
       background:$accent;color:#fff;font-size:24px}
  h1{font-size:20px;margin:0 0 8px;font-weight:600} p{margin:0;color:#57606a}
</style></head>
<body><div class="card"><div class="dot">${ok ? '&#10003;' : '!'}</div>
<h1>${esc(title)}</h1><p>${esc(message)}</p></div></body></html>
''';
  }
}

/// Writes [json] to [path] atomically: temp file created with 0600, then
/// renamed over the target. The parent directory is created (0700).
Future<void> writeAuthJsonAtomic(String path, Map<String, Object?> json) async {
  final target = File(path);
  final dir = target.parent;
  if (!await dir.exists()) {
    await dir.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS || Platform.isAndroid) await Process.run('chmod', ['700', dir.path]);
  }
  final tmp = File(p.join(dir.path, '.auth.json.woi-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp'));
  await tmp.writeAsString('');
  if (Platform.isLinux || Platform.isMacOS || Platform.isAndroid) await Process.run('chmod', ['600', tmp.path]);
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json), flush: true);
  await tmp.rename(target.path);
}
