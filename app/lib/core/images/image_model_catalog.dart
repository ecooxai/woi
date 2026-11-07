import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../auth/auth.dart';

/// The requested default is preserved verbatim, even when an account does not
/// advertise it. Selecting a model never silently substitutes another model.
const kDefaultImageModel = 'gpt-image-2.6-flare';
const kDefaultImageQuality = 'low';
const kDefaultImageSize = '1024x1024';
const kDefaultImageFormat = 'jpeg';

/// Documented candidates, not an entitlement claim for the current account.
/// https://developers.openai.com/api/docs/guides/image-generation
const kDocumentedImageModels = <String>[
  'gpt-image-2.6-flare',
  'gpt-image-2.6-sunburst',
  'gpt-image-2.5-flare',
  'gpt-image-2.5-sunburst',
  'gpt-image-2',
  'gpt-image-1.5',
  'gpt-image-1-mini',
  'chatgpt-image-latest',
];

class ImageModelCatalogResult {
  const ImageModelCatalogResult({
    required this.models,
    required this.source,
    this.notice,
    this.accountVerified = false,
  });
  final List<String> models;
  final String source;
  final String? notice;

  /// Models were returned by the selected account, not merely documented.
  /// A successful generation is still subject to that account's permissions.
  final bool accountVerified;
}

class ImageModelCatalog {
  ImageModelCatalog({
    required this.credentials,
    Uri? apiEndpoint,
    Uri? codexEndpoint,
    HttpClient Function()? httpClient,
  }) : apiEndpoint =
           apiEndpoint ?? Uri.parse('https://api.openai.com/v1/models'),
       codexEndpoint =
           codexEndpoint ??
           Uri.parse(
             'https://chatgpt.com/backend-api/codex/models?client_version=$kCodexVersion',
           ),
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Credentials?> Function() credentials;
  final Uri apiEndpoint;
  final Uri codexEndpoint;
  final HttpClient Function() _httpClient;

  Future<ImageModelCatalogResult> discover() async {
    final creds = await credentials();
    if (creds == null) {
      return _fallback(
        'Sign in or add an API key to check image models for your account.',
      );
    }
    final client = _httpClient();
    try {
      return await (() async {
        final req = await client.getUrl(
          creds.mode == AuthMode.apiKey ? apiEndpoint : codexEndpoint,
        );
        creds.headers().forEach(req.headers.set);
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final res = await req.close();
        if (res.statusCode != 200) {
          return _fallback(
            'The selected backend could not list image models (HTTP ${res.statusCode}). These are documented choices; access is checked when generating.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in res) {
          bytes.addAll(chunk);
          if (bytes.length > 4 * 1024 * 1024) {
            throw const FormatException('Model list was too large');
          }
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        final models = parseImageModels(decoded);
        if (models.isEmpty) {
          return _fallback(
            creds.mode == AuthMode.codex
                ? 'Codex does not advertise image models in its model list. These are documented choices; generation checks your account’s access.'
                : 'Your API model list returned no image models. These are documented choices; check model access or keep a custom model ID.',
          );
        }
        return ImageModelCatalogResult(
          models: models,
          source: creds.mode == AuthMode.codex
              ? 'Codex account'
              : 'API account',
          accountVerified: true,
          notice: 'Listed by the selected account. Image generation also requires the relevant model permissions.',
        );
      })().timeout(const Duration(seconds: 20));
    } catch (e) {
      return _fallback(
        'Image model discovery failed: ${redactSecrets('$e', [creds.bearerToken])}. Documented choices are shown.',
      );
    } finally {
      client.close(force: true);
    }
  }

  static ImageModelCatalogResult _fallback(String notice) =>
      ImageModelCatalogResult(
        models: kDocumentedImageModels,
        source: 'Documented models',
        notice: notice,
      );

  static List<String> parseImageModels(Object? body) {
    if (body is! Map) return const [];
    final values = body['data'] ?? body['models'];
    if (values is! List) return const [];
    final ids = <String>{};
    for (final value in values) {
      final id = value is String
          ? value
          : value is Map
          ? value['id'] ?? value['slug']
          : null;
      if (id is String &&
          (id.startsWith('gpt-image-') || id == 'chatgpt-image-latest')) {
        ids.add(id);
      }
    }
    return ids.toList()..sort();
  }
}
