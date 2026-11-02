import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum AuthMode {
  codex('Codex login'),
  apiKey('OpenAI API key');

  const AuthMode(this.label);
  final String label;
}

/// Credentials handed to a backend. Never log or display [bearerToken].
class Credentials {
  const Credentials({required this.mode, required this.bearerToken, this.accountId});

  final AuthMode mode;
  final String bearerToken;
  final String? accountId;
}

/// Read-only view of `~/.codex/auth.json` (written by the Codex CLI login).
class CodexAuthInfo {
  const CodexAuthInfo({required this.path, this.accessToken, this.accountId, this.lastRefresh, this.error});

  final String path;
  final String? accessToken;
  final String? accountId;
  final DateTime? lastRefresh;
  final String? error;

  bool get isAvailable => accessToken != null && accessToken!.isNotEmpty;

  /// Safe, non-secret summary for the UI.
  String get summary {
    if (error != null) return error!;
    if (!isAvailable) return 'No Codex login found at $path';
    final acct = accountId == null || accountId!.length < 6
        ? ''
        : ' · account …${accountId!.substring(accountId!.length - 6)}';
    final when = lastRefresh == null ? '' : ' · refreshed ${lastRefresh!.toLocal().toString().split('.').first}';
    return 'Codex login found$acct$when';
  }

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
      if (tokens is Map) {
        access = tokens['access_token'] as String?;
        account = tokens['account_id'] as String?;
      }
      final lr = json['last_refresh'];
      return CodexAuthInfo(
        path: file.path,
        accessToken: access,
        accountId: account,
        lastRefresh: lr is String ? DateTime.tryParse(lr) : null,
      );
    } catch (e) {
      return CodexAuthInfo(path: file.path, error: 'Cannot read auth.json: $e');
    }
  }
}

/// Resolves [Credentials] for the selected [AuthMode].
Future<Credentials?> resolveCredentials(AuthMode mode, String apiKey, {String? codexPath}) async {
  switch (mode) {
    case AuthMode.apiKey:
      var key = apiKey.trim();
      if (key.isEmpty) key = (Platform.environment['OPENAI_API_KEY'] ?? '').trim();
      return key.isEmpty ? null : Credentials(mode: AuthMode.apiKey, bearerToken: key);
    case AuthMode.codex:
      final info = await CodexAuthInfo.load(path: codexPath);
      if (!info.isAvailable) return null;
      return Credentials(mode: AuthMode.codex, bearerToken: info.accessToken!, accountId: info.accountId);
  }
}
