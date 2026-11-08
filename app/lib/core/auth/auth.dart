import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum AuthMode {
  codex('Codex login'),
  apiKey('OpenAI API key');

  const AuthMode(this.label);
  final String label;
}

/// Codex CLI identity sent with ChatGPT-token requests (research/REALTIME_API.md §1).
const kCodexOriginator = 'codex_cli_rs';
const kCodexVersion = '0.166.0';
const kCodexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const kCodexRefreshUrl = 'https://auth.openai.com/oauth/token';

String codexUserAgent() {
  String release = '';
  try {
    release = Platform.operatingSystemVersion
        .split(' ')
        .firstWhere((s) => RegExp(r'^\d').hasMatch(s), orElse: () => '');
  } catch (_) {}
  final os = Platform.isLinux ? 'Linux' : Platform.operatingSystem;
  return '$kCodexOriginator/$kCodexVersion ($os $release; ${_arch()}) woi';
}

String _arch() {
  final v = Platform.version; // "... on "linux_x64""
  final m = RegExp(r'on "\w+_(\w+)"').firstMatch(v);
  return switch (m?.group(1)) {
    'x64' => 'x86_64',
    'arm64' => 'aarch64',
    final a? => a,
    null => 'unknown',
  };
}

/// Credentials handed to a backend. Never log or display [bearerToken].
class Credentials {
  const Credentials({required this.mode, required this.bearerToken, this.accountId, this.expiresAt});

  final AuthMode mode;
  final String bearerToken;
  final String? accountId;

  /// Access-token expiry (Codex JWT `exp`), when known.
  final DateTime? expiresAt;

  /// HTTP / WebSocket headers exactly as research/REALTIME_API.md §1 prescribes.
  /// [live] adds `openai-alpha: quicksilver=v2` (gpt-live call creation + sideband).
  Map<String, String> headers({bool live = false}) {
    if (mode == AuthMode.apiKey) return {'Authorization': 'Bearer $bearerToken'};
    return {
      'Authorization': 'Bearer $bearerToken',
      if (accountId != null && accountId!.isNotEmpty) 'chatgpt-account-id': accountId!,
      'originator': kCodexOriginator,
      'version': kCodexVersion,
      'User-Agent': codexUserAgent(),
      if (live) 'openai-alpha': 'quicksilver=v2',
    };
  }

  @override
  String toString() => 'Credentials(${mode.name}, token: <redacted>)';
}

/// Removes anything that looks like a token from [s] (JWTs, sk- keys, and any
/// explicitly registered secret). Use on every string that may be logged.
String redactSecrets(String s, [Iterable<String> secrets = const []]) {
  var out = s;
  for (final sec in [...secrets, ..._knownSecrets]) {
    if (sec.length >= 8) out = out.replaceAll(sec, '<redacted>');
  }
  out = out.replaceAll(RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+'), '<jwt>');
  out = out.replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{16,}'), 'sk-<redacted>');
  return out;
}

final Set<String> _knownSecrets = {};
void _remember(String? s) {
  if (s != null && s.length >= 8) _knownSecrets.add(s);
}

/// Decodes the (unverified) payload of a JWT; null when malformed.
Map<String, Object?>? jwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final norm = base64Url.normalize(parts[1]);
    final j = jsonDecode(utf8.decode(base64Url.decode(norm)));
    return j is Map ? j.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

DateTime? jwtExpiry(String token) {
  final exp = jwtClaims(token)?['exp'];
  return exp is num ? DateTime.fromMillisecondsSinceEpoch((exp * 1000).round(), isUtc: true) : null;
}

/// Read-only view of `~/.codex/auth.json` (written by the Codex CLI login).
class CodexAuthInfo {
  const CodexAuthInfo({
    required this.path,
    this.accessToken,
    this.accountId,
    this.email,
    this.lastRefresh,
    this.expiresAt,
    this.error,
  });

  final String path;
  final String? accessToken;
  final String? accountId;

  /// Display-only identity from the login token; never used for authorization.
  final String? email;
  final DateTime? lastRefresh;
  final DateTime? expiresAt;
  final String? error;

  bool get isAvailable => accessToken != null && accessToken!.isNotEmpty;

  /// Safe, non-secret summary for the UI.
  String get summary {
    if (error != null) return error!;
    if (!isAvailable) return 'No Codex login found at $path';
    final identity = email == null ? 'Signed in' : 'Signed in as $email';
    // Keep the date-time and validity duration together when the chip wraps.
    final stamp = lastRefresh?.toLocal().toString().split('.').first.replaceFirst(' ', '\u00a0');
    final when = stamp == null ? '' : ' · refreshed $stamp';
    final exp = expiresAt;
    var valid = '';
    if (exp != null) {
      final left = exp.difference(DateTime.now().toUtc());
      valid = left.isNegative ? ' · token expired (will refresh)' : ' · valid\u00a0${_fmtLeft(left)}';
    }
    return '$identity$when$valid';
  }

  static String? _loginEmail(String? idToken, String? accessToken) {
    for (final token in [idToken, accessToken]) {
      if (token == null) continue;
      final claims = jwtClaims(token);
      final profile = claims?['https://api.openai.com/profile'];
      for (final value in [claims?['email'], if (profile is Map) profile['email']]) {
        if (value is! String) continue;
        final email = value.trim();
        if (RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(email)) return email;
      }
    }
    return null;
  }

  static String _fmtLeft(Duration d) => d.inHours >= 48 ? '${d.inDays}\u00a0d' : '${d.inHours}\u00a0h';

  static String defaultPath() {
    final home = Platform.environment['HOME'] ?? '';
    final codexHome = Platform.environment['CODEX_HOME'];
    return codexHome != null && codexHome.isNotEmpty
        ? p.join(codexHome, 'auth.json')
        : p.join(home, '.codex', 'auth.json');
  }

  static Future<CodexAuthInfo> load({String? path}) async {
    final file = File(path ?? defaultPath());
    if (!await file.exists()) return CodexAuthInfo(path: file.path);
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) {
        return CodexAuthInfo(path: file.path, error: 'auth.json is malformed');
      }
      final tokens = json['tokens'];
      String? access;
      String? account;
      String? idToken;
      if (tokens is Map) {
        access = tokens['access_token'] as String?;
        account = tokens['account_id'] as String?;
        idToken = tokens['id_token'] is String ? tokens['id_token'] as String : null;
      }
      _remember(access);
      _remember(idToken);
      final lr = json['last_refresh'];
      return CodexAuthInfo(
        path: file.path,
        accessToken: access,
        accountId: account,
        email: _loginEmail(idToken, access),
        lastRefresh: lr is String ? DateTime.tryParse(lr) : null,
        expiresAt: access == null ? null : jwtExpiry(access),
      );
    } catch (e) {
      return CodexAuthInfo(path: file.path, error: 'Cannot read auth.json: ${redactSecrets('$e')}');
    }
  }
}

class AuthException implements Exception {
  AuthException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => 'AuthException: $message';
}

/// Loads `~/.codex/auth.json` and keeps the ChatGPT access token fresh.
///
/// Refresh tokens rotate and the file is shared with the Codex CLI, so this
/// refreshes only when the access token is within [refreshMargin] of expiry,
/// re-reads the file first (Codex may already have refreshed), and writes the
/// new tokens back atomically (tmp file + rename, mode 0600) exactly like
/// Codex: `tokens.{id_token,access_token,refresh_token}` + `last_refresh`.
class CodexAuthManager {
  CodexAuthManager({
    String? path,
    this.refreshMargin = const Duration(minutes: 5),
    Uri? refreshUrl,
    HttpClient Function()? httpClient,
    DateTime Function()? now,
  }) : path = path ?? CodexAuthInfo.defaultPath(),
       refreshUrl = refreshUrl ?? Uri.parse(kCodexRefreshUrl),
       _httpClient = httpClient ?? HttpClient.new,
       _now = now ?? (() => DateTime.now().toUtc());

  final String path;
  final Duration refreshMargin;
  final Uri refreshUrl;
  final HttpClient Function() _httpClient;
  final DateTime Function() _now;
  Future<Credentials?>? _inflight;

  /// Number of successful refreshes (diagnostics/tests).
  int refreshCount = 0;

  /// Valid credentials, refreshing first if needed. Null when not logged in.
  /// Throws [AuthException] when a needed refresh fails.
  Future<Credentials?> credentials({bool forceRefresh = false}) {
    // Single flight: concurrent callers share one refresh.
    return _inflight ??= _credentials(forceRefresh).whenComplete(() => _inflight = null);
  }

  Future<Credentials?> _credentials(bool force) async {
    final json = await _read();
    if (json == null) return null;
    final tokens = (json['tokens'] as Map?)?.cast<String, Object?>();
    final access = tokens?['access_token'] as String?;
    if (tokens == null || access == null || access.isEmpty) return null;
    final exp = jwtExpiry(access);
    final fresh = exp != null && exp.difference(_now()) > refreshMargin;
    if (fresh && !force) return _creds(tokens);
    final refreshToken = tokens['refresh_token'] as String?;
    if (refreshToken == null || refreshToken.isEmpty) {
      if (exp != null && exp.isAfter(_now())) return _creds(tokens);
      throw AuthException('Codex access token expired and no refresh token is available; run `codex login`.');
    }
    final updated = await _refresh(json, tokens, refreshToken);
    return _creds(updated);
  }

  Credentials _creds(Map<String, Object?> tokens) {
    final access = tokens['access_token'] as String;
    return Credentials(
      mode: AuthMode.codex,
      bearerToken: access,
      accountId: tokens['account_id'] as String?,
      expiresAt: jwtExpiry(access),
    );
  }

  Future<Map<String, Object?>?> _read() async {
    final f = File(path);
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      final m = j.cast<String, Object?>();
      final t = (m['tokens'] as Map?)?.cast<String, Object?>();
      if (t != null) {
        for (final k in ['access_token', 'refresh_token', 'id_token']) {
          _remember(t[k] as String?);
        }
      }
      return m;
    } catch (e) {
      throw AuthException('Cannot read $path: ${redactSecrets('$e')}');
    }
  }

  Future<Map<String, Object?>> _refresh(
    Map<String, Object?> json,
    Map<String, Object?> tokens,
    String refreshToken,
  ) async {
    final client = _httpClient();
    try {
      final req = await client.postUrl(refreshUrl).timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType.json;
      req.headers.set('User-Agent', codexUserAgent());
      req.headers.set('originator', kCodexOriginator);
      req.write(
        jsonEncode({'client_id': kCodexClientId, 'grant_type': 'refresh_token', 'refresh_token': refreshToken}),
      );
      final res = await req.close().timeout(const Duration(seconds: 45));
      final body = await utf8.decodeStream(res);
      if (res.statusCode != 200) {
        String? code;
        try {
          final e = jsonDecode(body);
          if (e is Map) {
            final err = e['error'];
            code = err is Map ? err['code'] as String? : err as String?;
          }
        } catch (_) {}
        throw AuthException(
          'Token refresh failed (${res.statusCode}${code == null ? '' : ' $code'}): '
          '${redactSecrets(body.length > 300 ? body.substring(0, 300) : body, [refreshToken])}',
          code: code,
        );
      }
      final fresh = jsonDecode(body);
      if (fresh is! Map) throw AuthException('Token refresh returned a malformed body');
      final next = Map<String, Object?>.from(tokens);
      for (final k in ['access_token', 'refresh_token', 'id_token']) {
        final v = fresh[k];
        if (v is String && v.isNotEmpty) {
          next[k] = v;
          _remember(v);
        }
      }
      final out = Map<String, Object?>.from(json)
        ..['tokens'] = next
        ..['last_refresh'] = _now().toUtc().toIso8601String();
      await _writeAtomic(out);
      refreshCount++;
      return next;
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Token refresh failed: ${redactSecrets('$e', [refreshToken])}');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _writeAtomic(Map<String, Object?> json) async {
    final target = File(path);
    final tmp = File(p.join(target.parent.path, '.auth.json.woi-$pid.tmp'));
    // Create with 0600 before writing any secret.
    await tmp.writeAsString('');
    if (Platform.isLinux || Platform.isMacOS) await Process.run('chmod', ['600', tmp.path]);
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json), flush: true);
    await tmp.rename(target.path);
  }
}

/// Resolves [Credentials] for the selected [AuthMode]. In Codex mode the
/// token is refreshed when close to expiry (see [CodexAuthManager]).
Future<Credentials?> resolveCredentials(
  AuthMode mode,
  String apiKey, {
  String? codexPath,
  CodexAuthManager? manager,
}) async {
  switch (mode) {
    case AuthMode.apiKey:
      var key = apiKey.trim();
      if (key.isEmpty) key = (Platform.environment['OPENAI_API_KEY'] ?? '').trim();
      _remember(key);
      return key.isEmpty ? null : Credentials(mode: AuthMode.apiKey, bearerToken: key);
    case AuthMode.codex:
      return (manager ?? CodexAuthManager(path: codexPath)).credentials();
  }
}
