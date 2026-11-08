import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../auth/auth.dart';
import '../responses/responses_client.dart'
    show SseParser, kCodexResponsesUrl, kOpenAiResponsesUrl;
import '../settings/settings.dart';
import 'model_click_lab.dart';

const _protocol = 'screenshot-only-v3-tiers';
const _maxImageBytes = 6 * 1024 * 1024;
const _maxProviderBytes = 4 * 1024 * 1024;
const _instructions =
    'You are a visual coordinate locator in a controlled button test. '
    "Use only the attached screenshot and the user's instruction. "
    'Call screen_action exactly once. For a request to click, use action click; '
    'for a request to move the pointer without clicking, use action move. '
    'Choose a point inside the requested visible button, preferably its center. '
    'Return absolute pixel coordinates in the attached screenshot, with origin '
    'at the top-left, x increasing right and y increasing down. '
    'Do not return normalized coordinates, CSS/desktop coordinates, a label, '
    'an explanation, or any other tool call. Do not guess a target from prior turns; '
    'there are no prior turns.';
const _liveReason =
    'GPT-Live uses delegated tools. The current gpt-live-1.1 endpoint '
    'rejects native image input and session tool registration. Woi can execute explicit '
    'client actions; screenshot-based targeting needs an image-capable delegate. '
    'This direct-model lab does not substitute Luna or another model.';
const _tiers = <String, Map<String, String>>{
  'normal': {'label': 'Normal', 'service_tier': 'default'},
  'fast': {'label': 'Fast', 'service_tier': 'priority'},
  'ultrafast': {'label': 'Ultrafast', 'service_tier': 'ultrafast'},
  'flex': {'label': 'Flex', 'service_tier': 'flex'},
};
const _actionTool = <String, Object?>{
  'type': 'function',
  'name': 'screen_action',
  'description':
      'Click or move the pointer to one position in the supplied screenshot.',
  'parameters': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['click', 'move'],
      },
      'x': {'type': 'integer', 'description': 'Absolute screenshot x pixel.'},
      'y': {'type': 'integer', 'description': 'Absolute screenshot y pixel.'},
    },
    'required': ['action', 'x', 'y'],
    'additionalProperties': false,
  },
};
final _modelId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$');
final _requestId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');
final _tierError = RegExp(
  r'service[ _.-]?tier|ultrafast|priority tier|flex tier',
  caseSensitive: false,
);

typedef ModelClickLabCredentials = Future<Credentials?> Function(AuthMode mode);

/// One-shot native transports for the bundled synthetic click lab.
///
/// Each trial pins its selected auth mode and credentials once, opens a fresh
/// provider request, and has only the screenshot, instruction, and screen_action
/// schema. It has no access to Woi history, microphone, locator delegation, or
/// device input tools. Returned actions are dispatched inside the browser canvas.
class AppModelClickLabBackend implements ModelClickLabBackend {
  AppModelClickLabBackend({
    required this._credentials,
    required AppSettings Function() settings,
    required this.evidenceDirectory,
    Uri? codexResponsesEndpoint,
    Uri? apiResponsesEndpoint,
    Uri? codexModelsEndpoint,
    Uri? apiModelsEndpoint,
    Uri? realtimeEndpoint,
    this.trialTimeout = const Duration(seconds: 120),
    this.flexTimeout = const Duration(seconds: 600),
    this.catalogTimeout = const Duration(seconds: 25),
  }) : _settings = settings,
       _mode = settings().authMode,
       _codexResponses = codexResponsesEndpoint ?? kCodexResponsesUrl,
       _apiResponses = apiResponsesEndpoint ?? kOpenAiResponsesUrl,
       _codexModels =
           codexModelsEndpoint ??
           Uri.parse(
             'https://chatgpt.com/backend-api/codex/models?client_version=$kCodexVersion',
           ),
       _apiModels =
           apiModelsEndpoint ?? Uri.parse('https://api.openai.com/v1/models'),
       _realtime =
           realtimeEndpoint ?? Uri.parse('wss://api.openai.com/v1/realtime');

  final ModelClickLabCredentials _credentials;
  final AppSettings Function() _settings;
  final Directory evidenceDirectory;
  final Uri _codexResponses, _apiResponses, _codexModels, _apiModels, _realtime;
  final Duration trialTimeout, flexTimeout, catalogTimeout;
  AuthMode _mode;
  String? _sessionKey;
  int _revision = 0, _leases = 0;
  bool _closed = false;
  final _closedSignal = Completer<void>();
  final _clients = <HttpClient>{};
  final _sockets = <WebSocket>{};
  final _secrets = <String>{};
  Map<String, Object?>? _catalog;
  String? _catalogKey;
  DateTime? _catalogAt;
  final _statuses = <String, Map<String, Object?>>{};
  Future<void> _evidenceTail = Future<void>.value();

  void _ensureOpen() {
    if (_closed) {
      throw const ModelClickLabException(
        'cancelled',
        'The model click lab has closed.',
        status: 503,
      );
    }
  }

  Future<_ConnectionLease> _lease([int? expectedRevision]) async {
    _ensureOpen();
    if (expectedRevision != null && expectedRevision != _revision) {
      throw const ModelClickLabException(
        'connection_changed',
        'The connection changed. Refresh the models before starting another trial.',
        status: 409,
      );
    }
    // Increment before the first await: configuration cannot change while the
    // selected account is being refreshed or while any trial is in progress.
    _leases++;
    final mode = _mode, revision = _revision, sessionKey = _sessionKey;
    try {
      final credentials = mode == AuthMode.apiKey && sessionKey != null
          ? Credentials(mode: AuthMode.apiKey, bearerToken: sessionKey)
          : await _credentials(mode);
      _ensureOpen();
      if (credentials != null && credentials.mode != mode) {
        throw const ModelClickLabException(
          'authentication_error',
          'Credential source returned a different authentication mode.',
          status: 401,
        );
      }
      if (credentials != null) _secrets.add(credentials.bearerToken);
      return _ConnectionLease(
        mode,
        revision,
        mode == AuthMode.apiKey && sessionKey != null,
        credentials,
      );
    } catch (_) {
      _release();
      rethrow;
    }
  }

  void _release() {
    _leases--;
    if (_closed && _leases == 0) _secrets.clear();
  }

  Map<String, Object?> _publicConnection(_ConnectionLease lease) => {
    'mode': lease.mode == AuthMode.codex ? 'codex' : 'api',
    'auth_mode': lease.mode == AuthMode.codex ? 'codex' : 'api',
    'configured': lease.credentials != null,
    'source': lease.sessionKey
        ? 'Temporary lab API key'
        : lease.mode == AuthMode.codex
        ? 'Woi Codex login'
        : 'Woi API key',
    if (lease.credentials == null)
      'reason': lease.mode == AuthMode.codex
          ? 'Sign in to Codex in Woi, then refresh.'
          : 'Set an API key in Woi or enter a temporary lab key.',
    'revision': lease.revision,
    'session_key': lease.sessionKey,
    'speed_tiers': [
      for (final entry in _tiers.entries) {'id': entry.key, ...entry.value},
    ],
  };

  @override
  Future<Map<String, Object?>> connection() async {
    final lease = await _lease();
    try {
      return _publicConnection(lease);
    } finally {
      _release();
    }
  }

  @override
  Future<Map<String, Object?>> configureConnection(
    Map<String, Object?> input,
  ) async {
    _ensureOpen();
    if (_leases != 0) {
      throw const ModelClickLabException(
        'connection_busy',
        'Wait for active trials and model discovery before changing connection.',
        status: 409,
      );
    }
    if (input.keys.any((k) => k != 'auth_mode' && k != 'api_key') ||
        !['codex', 'api'].contains(input['auth_mode'])) {
      throw const ModelClickLabException(
        'invalid_connection',
        'Choose Codex login or API key.',
      );
    }
    final mode = input['auth_mode'] == 'codex'
        ? AuthMode.codex
        : AuthMode.apiKey;
    String? key = _sessionKey;
    if (input.containsKey('api_key')) {
      if (mode != AuthMode.apiKey || input['api_key'] is! String) {
        throw const ModelClickLabException(
          'invalid_api_key',
          'A temporary API key is allowed only in API mode.',
        );
      }
      final value = (input['api_key'] as String).trim();
      if (value.isNotEmpty &&
          (value.length < 8 ||
              value.length > 4096 ||
              value.codeUnits.any((x) => x < 33 || x > 126))) {
        throw const ModelClickLabException(
          'invalid_api_key',
          'Enter a printable API key between 8 and 4096 characters.',
        );
      }
      key = value.isEmpty ? null : value;
      if (key != null) _secrets.add(key);
    }
    _mode = mode;
    _sessionKey = key;
    _revision++;
    _catalog = null;
    return connection();
  }

  String _authKey(_ConnectionLease lease) =>
      '${lease.mode.name}:${sha256.convert(utf8.encode('${lease.credentials?.accountId ?? ''}\n${lease.credentials?.bearerToken ?? ''}'))}';

  @override
  Future<Map<String, Object?>> models({bool refresh = false}) async {
    final lease = await _lease();
    try {
      return await _discover(lease, refresh: refresh);
    } finally {
      _release();
    }
  }

  Future<Map<String, Object?>> _discover(
    _ConnectionLease lease, {
    bool refresh = false,
  }) async {
    final cacheKey = _authKey(lease);
    if (refresh ||
        _catalog == null ||
        _catalogKey != cacheKey ||
        DateTime.now().difference(_catalogAt!) > const Duration(minutes: 5)) {
      final byId = <String, Map<String, Object?>>{};
      final warnings = <String>[];
      final credentials = lease.credentials;
      if (credentials != null) {
        final endpoints = <(Uri, String)>[
          if (lease.mode == AuthMode.codex)
            (_codexModels, 'Codex model catalog'),
          (_apiModels, 'OpenAI model catalog'),
        ];
        final results = await Future.wait(
          endpoints.map((source) async {
            try {
              final data = await _catalogRequest(source.$1, credentials);
              final values = data['models'] ?? data['data'];
              if (values is! List) {
                throw const ModelClickLabException(
                  'catalog_error',
                  'Model catalog has no model list.',
                  status: 502,
                );
              }
              return (source.$2, values, null);
            } catch (error) {
              return (source.$2, <Object?>[], '${source.$2}: ${_safe(error)}');
            }
          }),
        );
        for (final result in results) {
          if (result.$3 != null) warnings.add(result.$3!);
          for (final raw in result.$2) {
            if (raw is! Map) continue;
            final entry = _modelEntry(
              Map<String, Object?>.from(raw),
              result.$1,
            );
            if (entry != null) {
              byId.putIfAbsent(entry['id']! as String, () => entry);
            }
          }
        }
      }
      _ensureOpen();
      final settings = _settings();
      for (final id in <String>{
        ...kRealtimeModels,
        ...kVoiceModels,
        settings.realtimeModel,
        settings.voiceModel,
        settings.delegateModel,
        settings.compressionModel,
      }) {
        final entry = _modelEntry({'id': id}, 'Woi model registry');
        if (entry != null) byId.putIfAbsent(id, () => entry);
      }
      if (credentials == null) {
        for (final entry in byId.values) {
          entry['available'] = false;
          // Keep a native capability explanation for GPT-Live even without login.
          if (entry['transport'] != 'live') {
            entry['reason'] = _publicConnection(lease)['reason'];
          }
        }
      }
      _catalog = {
        'models': byId.values.toList(),
        'source': byId.values.map((e) => e['source']).toSet().toList(),
        'warnings': warnings,
        'discovered_at': DateTime.now().toUtc().toIso8601String(),
        'notes': 'Listed or registered models are candidates; access and screenshot support are verified per trial. Each trial uses the selected model directly, with no substitute.',
      };
      _catalogKey = cacheKey;
      _catalogAt = DateTime.now();
    }
    final result = _object(jsonDecode(jsonEncode(_catalog)));
    for (final row in (result['models']! as List).cast<Map>()) {
      row['tier_results'] = {
        for (final tier in _tiers.keys)
          if (_statuses.containsKey('$cacheKey:${row['id']}:$tier'))
            tier: _statuses['$cacheKey:${row['id']}:$tier'],
      };
      row.addAll(
        _statuses['$cacheKey:${row['id']}:normal'] ?? <String, Object?>{},
      );
    }
    final connection = _publicConnection(lease);
    return {
      ...result,
      'auth': connection,
      'connection': connection,
      'speed_tiers': connection['speed_tiers'],
      'protocol': _protocol,
      'image_detail_policy': 'auto',
    };
  }

  Map<String, Object?>? _modelEntry(Map<String, Object?> raw, String source) {
    final id = raw['slug'] ?? raw['id'];
    if (id is! String || !_modelId.hasMatch(id)) return null;
    final modalities = raw['input_modalities'];
    final transport = id.startsWith('gpt-live')
        ? 'live'
        : id.contains('realtime')
        ? 'realtime'
        : [
            'embedding',
            'moderation',
            'gpt-image',
            'dall-e',
            'sora',
          ].any(id.contains)
        ? 'other'
        : ['audio', 'transcribe', 'tts', 'whisper'].any(id.contains)
        ? 'audio_only'
        : modalities is List ||
              [
                'gpt-',
                'chatgpt-',
                'o1',
                'o3',
                'o4',
                'computer-use',
                'codex-',
              ].any(id.startsWith)
        ? 'responses'
        : 'other';
    var available = true, reason = '';
    if (transport == 'live') {
      available = false;
      reason = _liveReason;
    } else if (transport == 'audio_only' || transport == 'other') {
      available = false;
      reason =
          'This model is not a direct text-plus-screenshot coordinate model.';
    } else if (modalities is List && !modalities.contains('image')) {
      available = false;
      reason = 'Catalog does not list image input support.';
    } else if (id == 'gpt-4' ||
        [
          'gpt-3.5',
          'gpt-4-0314',
          'gpt-4-0613',
          'gpt-4-32k',
        ].any(id.startsWith)) {
      available = false;
      reason = 'This legacy model does not accept screenshot input.';
    }
    final levels = raw['supported_reasoning_levels'];
    final low =
        levels is List && levels.any((v) => v is Map && v['effort'] == 'low');
    final original = raw['supports_image_detail_original'];
    return {
      'id': id,
      'name': raw['display_name'] is String ? raw['display_name'] : id,
      'kind': ['live', 'realtime', 'audio_only'].contains(transport)
          ? 'audio'
          : transport == 'responses'
          ? 'text'
          : 'other',
      'transport': transport,
      'available': available,
      'reason': reason,
      'source': source,
      'availability': source.contains('catalog') ? 'listed' : 'candidate',
      'input_modalities': modalities is List ? modalities : null,
      'visibility': raw['visibility'] ?? 'list',
      'supports_image_detail_original': original is bool ? original : null,
      'reasoning_effort': low ? 'low' : null,
      'test_status': 'untested',
      'image_detail': transport == 'responses'
          ? original == true
                ? 'original'
                : 'high'
          : transport == 'realtime'
          ? 'high'
          : null,
    };
  }

  Future<Map<String, Object?>> _catalogRequest(
    Uri endpoint,
    Credentials credentials,
  ) async {
    final client = _client();
    try {
      return await _bounded(
        () async {
          final request = await client.getUrl(endpoint);
          request.followRedirects = false;
          credentials.headers().forEach(request.headers.set);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          final response = await request.close();
          final bytes = await _collect(response, _maxProviderBytes);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw _apiError(
              response.statusCode,
              utf8.decode(bytes, allowMalformed: true),
            );
          }
          return _object(jsonDecode(utf8.decode(bytes)));
        }(),
        catalogTimeout,
        () => client.close(force: true),
      );
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, Object?>> trial(Map<String, Object?> input) async {
    final trial = _validate(input);
    final lease = await _lease(trial['connection_revision'] as int?);
    try {
      final catalog = await _discover(lease);
      final entries = (catalog['models']! as List).cast<Map>();
      final matching = entries.where((e) => e['id'] == trial['model']);
      if (matching.isEmpty) {
        throw const ModelClickLabException(
          'unknown_model',
          'Model was not found in the available catalog or Woi model registry.',
        );
      }
      final model = Map<String, Object?>.from(matching.first);
      final timing = _ProviderTiming();
      final watch = Stopwatch()..start();
      final tier = trial['speed_tier']! as String;
      final timeout = tier == 'flex' ? flexTimeout : trialTimeout;
      final output = <String, Object?>{
        'request_id': trial['request_id'],
        'model': trial['model'],
        'resolved_model': null,
        'action': null,
        'x': null,
        'y': null,
        'latency_ms': null,
        'usage': null,
        'error': null,
        'error_code': null,
        'transport': model['transport'],
        'fresh_context': true,
        'image_sha256': trial['image_sha256'],
        'image_bytes': trial['image_bytes'],
        'request_image_bytes': trial['image_bytes'],
        'width': trial['width'],
        'height': trial['height'],
        'screen': trial['screen'],
        'reasoning_effort': model['reasoning_effort'],
        'prompt_sha256': sha256.convert(utf8.encode(_instructions)).toString(),
        'raw_output': null,
        'endpoint': null,
        'protocol': _protocol,
        'image_detail_policy': 'auto',
        'image_detail': null,
        'speed_tier': tier,
        'requested_service_tier': _tiers[tier]!['service_tier'],
        'actual_service_tier': null,
        'tier_status': 'unreported',
        'tier_note': 'Provider has not reported a tier.',
        'connection_revision': lease.revision,
        'auth_mode': lease.mode == AuthMode.codex ? 'codex' : 'api',
        'timeout_ms': timeout.inMilliseconds,
      };
      try {
        if (model['available'] != true) {
          throw ModelClickLabException(
            'unsupported_capability',
            model['reason']! as String,
            status: 422,
          );
        }
        final credentials = lease.credentials;
        if (credentials == null) {
          throw const ModelClickLabException(
            'authentication_error',
            'No credentials are configured for the selected connection.',
            status: 401,
          );
        }
        final realtime = model['transport'] == 'realtime';
        final endpoint = realtime
            ? _realtime
            : lease.mode == AuthMode.codex
            ? _codexResponses
            : _apiResponses;
        output['endpoint'] = endpoint.toString();
        if (realtime) {
          output['requested_service_tier'] = null;
          if (tier != 'normal') {
            throw const ModelClickLabException(
              'tier_unsupported_transport',
              'Realtime does not expose service_tier. Select Normal or a Responses model; no substitute was used.',
              status: 422,
            );
          }
          output['tier_note'] = 'Realtime does not expose a service tier; no service_tier was sent.';
        }
        output['image_detail'] = model['image_detail'];
        final result = realtime
            ? await _realtimeTrial(trial, model, credentials, timing, timeout)
            : await _responsesTrial(
                trial,
                model,
                credentials,
                timing,
                endpoint,
                timeout,
              );
        output.addAll({
          'usage': result['usage'],
          'resolved_model': result['resolved_model'],
          'provider_status': result['provider_status'],
          'raw_output': _scrub(result),
        });
        final actual = result['actual_service_tier'];
        if (actual is String) {
          output['actual_service_tier'] = actual;
          final requested = output['requested_service_tier'];
          final matched =
              actual == requested ||
              requested == 'priority' && actual == 'fast';
          output['tier_status'] = matched ? 'reported' : 'different';
          output['tier_note'] = matched
              ? 'Provider reported the requested processing tier.'
              : 'Provider reported a different tier; no fallback request was made.';
        }
        output.addAll(
          _parseAction(
            result['calls'],
            trial['width']! as int,
            trial['height']! as int,
          ),
        );
      } catch (error) {
        timing.finish('error');
        var code = error is ModelClickLabException
            ? error.code
            : 'transport_error';
        final message = _safe(error);
        if (code == 'tier_unsupported_transport') {
          output.addAll({
            'requested_service_tier': null,
            'tier_status': 'unsupported',
            'tier_note': message,
          });
        } else if (code == 'tier_rejected' ||
            (code.startsWith('api_') || code.startsWith('provider_')) &&
                _tierError.hasMatch(message)) {
          code = 'tier_rejected';
          output.addAll({
            'tier_status': 'rejected',
            'tier_note': 'Provider rejected the selected tier; no fallback was attempted.',
          });
        }
        output.addAll({'error': message, 'error_code': code});
      }
      output.addAll({
        'timing': timing.snapshot(),
        'request_payload_bytes': timing.payloadBytes,
        'latency_ms': watch.elapsedMicroseconds / 1000,
      });
      _ensureOpen();
      _statuses['${_authKey(lease)}:${trial['model']}:$tier'] = {
        'test_status': output['error_code'] ?? 'responded',
        'last_error': output['error'],
        'tier_status': output['tier_status'],
        'actual_service_tier': output['actual_service_tier'],
      };
      try {
        await _persistTrial(trial, output);
      } catch (error) {
        output['evidence_error'] =
            'Trial completed, but evidence could not be saved: ${_safe(error)}';
      }
      return output;
    } finally {
      _release();
    }
  }

  Map<String, Object?> _inputItem(Map<String, Object?> trial, Object? detail) {
    final screen = _object(trial['screen']);
    return {
      'type': 'message',
      'role': 'user',
      'content': [
        {
          'type': 'input_image',
          'image_url': trial['screenshot'],
          'detail': detail,
        },
        {
          'type': 'input_text',
          'text':
              'Screenshot resolution: ${trial['width']} x ${trial['height']} pixels. '
              'Reported display resolution: ${screen['width']} x ${screen['height']} CSS pixels; devicePixelRatio: ${screen['devicePixelRatio']}. '
              'The screenshot covers only the controlled test surface. Return screenshot pixel coordinates; do not use display pixels or apply devicePixelRatio.\n'
              'User instruction: ${trial['instruction']}',
        },
      ],
    };
  }

  Future<Map<String, Object?>> _responsesTrial(
    Map<String, Object?> trial,
    Map<String, Object?> model,
    Credentials credentials,
    _ProviderTiming timing,
    Uri endpoint,
    Duration timeout,
  ) async {
    final body = <String, Object?>{
      'model': trial['model'],
      'instructions': _instructions,
      'input': [_inputItem(trial, model['image_detail'])],
      'tools': [_actionTool],
      'tool_choice': 'required',
      'parallel_tool_calls': false,
      'stream': true,
      'store': false,
      'service_tier': _tiers[trial['speed_tier']]!['service_tier'],
      if (model['reasoning_effort'] != null)
        'reasoning': {'effort': model['reasoning_effort']},
    };
    final bytes = utf8.encode(jsonEncode(body));
    final client = _client();
    final result = <String, Object?>{
      'calls': <Object?>[],
      'text': '',
      'usage': null,
      'resolved_model': null,
      'provider_status': null,
    };
    timing.start(
      bytes.length,
      'dart_io.request_flush_returned',
      'Offsets start before opening the provider HTTP request. Upload measures client request.flush() returning, '
          'not network transmission, TCP acknowledgement, provider receipt, or the standalone Python sendall boundary. '
          'The offset includes connection setup; duration covers adding and flushing the body to the client sink. '
          'request_payload_bytes is the actual UTF-8 JSON size, excluding HTTP/TLS overhead.',
    );
    try {
      return await _bounded(
        () async {
          final request = await client.postUrl(endpoint);
          request.followRedirects = false;
          credentials.headers().forEach(request.headers.set);
          request.headers.contentType = ContentType.json;
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          request.contentLength = bytes.length;
          request.bufferOutput = false;
          final bodyStart = timing.elapsed;
          request.add(bytes);
          await request.flush();
          timing.uploaded(bodyStart);
          final response = await request.close();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final errorBytes = await _collect(response, _maxProviderBytes);
            throw _apiError(
              response.statusCode,
              utf8.decode(errorBytes, allowMalformed: true),
            );
          }
          var completed = false;
          await for (final sse in _limited(
            response,
            _maxProviderBytes,
          ).transform(const SseParser())) {
            if (sse.data.isEmpty || sse.data == '[DONE]') continue;
            final event = _object(jsonDecode(sse.data));
            timing.observe(event);
            final type = event['type'];
            final provider = _maybeObject(event['response']);
            if (type == 'response.created' || type == 'response.in_progress') {
              if (provider['model'] is String) {
                result['resolved_model'] = provider['model'];
              }
              if (provider['service_tier'] is String) {
                result['actual_service_tier'] = provider['service_tier'];
              }
            } else if (type == 'response.output_text.delta') {
              result['text'] = _clip(
                '${result['text']}${event['delta'] ?? ''}',
                8192,
              );
            } else if (type == 'response.output_item.done') {
              final item = _maybeObject(event['item']);
              if (item['type'] == 'function_call') {
                (result['calls']! as List).add({
                  'name': item['name'],
                  'arguments': item['arguments'],
                });
              }
            } else if ([
              'response.completed',
              'response.incomplete',
              'response.failed',
            ].contains(type)) {
              result.addAll({
                'usage': provider['usage'],
                'provider_status': provider['status'],
              });
              if (provider['model'] is String) {
                result['resolved_model'] = provider['model'];
              }
              if (provider['service_tier'] is String) {
                result['actual_service_tier'] = provider['service_tier'];
              }
              final calls = _finalCalls(provider);
              if (calls.isNotEmpty) result['calls'] = calls;
              if (type != 'response.completed' ||
                  ![null, 'completed'].contains(provider['status'])) {
                throw ModelClickLabException(
                  'provider_${provider['status'] ?? 'failed'}',
                  _safe(
                    provider['error'] ??
                        provider['incomplete_details'] ??
                        'Provider did not complete.',
                  ),
                  status: 502,
                );
              }
              timing.finish('completed');
              completed = true;
              break;
            } else if (type == 'error') {
              throw ModelClickLabException(
                'provider_error',
                _safe(event['message'] ?? event['error'] ?? 'Provider error'),
                status: 502,
              );
            }
          }
          if (!completed) {
            throw const ModelClickLabException(
              'incomplete_stream',
              'Responses stream closed before completion.',
              status: 502,
            );
          }
          return result;
        }(),
        timeout,
        () => client.close(force: true),
      );
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _realtimeTrial(
    Map<String, Object?> trial,
    Map<String, Object?> model,
    Credentials credentials,
    _ProviderTiming timing,
    Duration timeout,
  ) async {
    final session = jsonEncode({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'instructions': _instructions,
        'output_modalities': ['text'],
        'audio': {
          'input': {'turn_detection': null},
        },
        'tools': [_actionTool],
        'tool_choice': 'required',
      },
    });
    final response = jsonEncode({
      'type': 'response.create',
      'response': {
        'conversation': 'none',
        'input': [_inputItem(trial, model['image_detail'])],
        'output_modalities': ['text'],
        'instructions': _instructions,
        'tools': [_actionTool],
        'tool_choice': 'required',
      },
    });
    final endpoint = _realtime.replace(
      queryParameters: {
        ..._realtime.queryParameters,
        'model': trial['model']! as String,
      },
    );
    final client = _client();
    WebSocket? socket;
    StreamIterator<dynamic>? events;
    var expired = false;
    final result = <String, Object?>{
      'calls': <Object?>[],
      'text': '',
      'usage': null,
      'resolved_model': null,
      'provider_status': null,
    };
    timing.start(
      utf8.encode(session).length + utf8.encode(response).length,
      'dart_io.websocket_add_enqueued',
      'Offsets start before the fresh WebSocket connection. WebSocket.add only enqueues response.create: '
          'upload_enqueued_ms records that client boundary. Upload completion and duration are unavailable, '
          'because Dart exposes no socket-send completion hook. It is not provider receipt. '
          'request_payload_bytes sums the actual UTF-8 session.update and response.create JSON sizes, excluding WebSocket/TLS overhead.',
    );
    try {
      return await _bounded(
        () async {
          final connected = await WebSocket.connect(
            endpoint.toString(),
            headers: credentials.headers(),
            customClient: client,
          );
          if (expired || _closed) {
            unawaited(connected.close());
            throw const ModelClickLabException(
              'cancelled',
              'Realtime trial was cancelled.',
              status: 503,
            );
          }
          socket = connected;
          _sockets.add(connected);
          events = StreamIterator<dynamic>(connected);
          var providerBytes = 0;
          Future<Map<String, Object?>> nextEvent() async {
            if (!await events!.moveNext()) {
              throw const ModelClickLabException(
                'incomplete_stream',
                'Realtime connection closed before completion.',
                status: 502,
              );
            }
            final frame = events!.current;
            final text = frame is String
                ? frame
                : utf8.decode((frame as List).cast<int>());
            providerBytes += utf8.encode(text).length;
            if (providerBytes > _maxProviderBytes) {
              throw const ModelClickLabException(
                'provider_response_limit',
                'Provider response exceeded 4 MiB.',
                status: 502,
              );
            }
            final event = _object(jsonDecode(text));
            if (event['type'] == 'error') {
              final error = _maybeObject(event['error']);
              final message = _safe(error['message'] ?? error);
              final code = error['code'];
              final mapped = ['model_not_found', 'invalid_model'].contains(code)
                  ? 'model_unavailable'
                  : message.toLowerCase().contains('image') &&
                        message.toLowerCase().contains('support')
                  ? 'image_unsupported'
                  : 'api_request_rejected';
              throw ModelClickLabException(
                mapped,
                '${code ?? 'realtime_error'}: $message',
                status: 502,
              );
            }
            return event;
          }

          while (true) {
            final event = await nextEvent();
            if (event['type'] == 'session.created') {
              result['resolved_model'] = _maybeObject(
                event['session'],
              )['model'];
              break;
            }
          }
          connected.add(session);
          while ((await nextEvent())['type'] != 'session.updated') {
            /* fresh session acknowledgement */
          }
          connected.add(response);
          timing.enqueued();
          while (true) {
            final event = await nextEvent();
            timing.observe(event);
            final type = event['type'];
            if (type == 'response.function_call_arguments.done') {
              (result['calls']! as List).add({
                'name': event['name'],
                'arguments': event['arguments'],
              });
            } else if (type == 'response.output_text.done' ||
                type == 'response.text.done') {
              result['text'] = _clip(
                '${result['text']}${event['text'] ?? ''}',
                8192,
              );
            } else if (type == 'response.done') {
              final provider = _maybeObject(event['response']);
              result.addAll({
                'usage': provider['usage'],
                'provider_status': provider['status'],
              });
              if (provider['model'] is String) {
                result['resolved_model'] = provider['model'];
              }
              final calls = _finalCalls(provider);
              if (calls.isNotEmpty) result['calls'] = calls;
              if (provider['status'] != 'completed') {
                throw ModelClickLabException(
                  'provider_${provider['status'] ?? 'failed'}',
                  _safe(
                    provider['status_details'] ??
                        'Realtime response did not complete.',
                  ),
                  status: 502,
                );
              }
              timing.finish('completed');
              return result;
            }
          }
        }(),
        timeout,
        () {
          expired = true;
          client.close(force: true);
          if (socket != null) unawaited(socket!.close());
        },
      );
    } finally {
      expired = true;
      if (events != null) unawaited(events!.cancel());
      if (socket != null) {
        _sockets.remove(socket);
        unawaited(socket!.close());
      }
      _clients.remove(client);
      client.close(force: true);
    }
  }

  List<Map<String, Object?>> _finalCalls(Map<String, Object?> response) {
    final output = response['output'];
    return output is List
        ? [
            for (final item in output)
              if (item is Map && item['type'] == 'function_call')
                {'name': item['name'], 'arguments': item['arguments']},
          ]
        : [];
  }

  HttpClient _client() {
    _ensureOpen();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    _clients.add(client);
    return client;
  }

  Future<T> _bounded<T>(
    Future<T> operation,
    Duration timeout,
    void Function() cancel,
  ) =>
      Future.any<T>([
        operation,
        _closedSignal.future.then<T>(
          (_) => throw const ModelClickLabException(
            'cancelled',
            'The model click lab has closed.',
            status: 503,
          ),
        ),
      ]).timeout(
        timeout,
        onTimeout: () {
          cancel();
          throw const ModelClickLabException(
            'timeout',
            'The provider request timed out; no retry or fallback was attempted.',
            status: 504,
          );
        },
      );

  Stream<List<int>> _limited(Stream<List<int>> stream, int limit) async* {
    var size = 0;
    await for (final bytes in stream) {
      size += bytes.length;
      if (size > limit) {
        throw const ModelClickLabException(
          'provider_response_limit',
          'Provider response exceeded its size limit.',
          status: 502,
        );
      }
      yield bytes;
    }
  }

  Future<Uint8List> _collect(Stream<List<int>> stream, int limit) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in _limited(stream, limit)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  ModelClickLabException _apiError(int status, String body) {
    var text = _safe(body);
    try {
      final detail = _object(jsonDecode(body))['error'];
      if (detail is Map) {
        text = _safe(detail['message'] ?? detail);
      } else if (detail != null) {
        text = _safe(detail);
      }
    } catch (_) {
      /* non-JSON provider error is still sanitized and bounded */
    }
    final lower = text.toLowerCase();
    var code = 'api_error';
    if ([401, 403].contains(status) &&
        _tierError.hasMatch(lower) &&
        !['api key', 'token', 'credential', 'bearer'].any(lower.contains)) {
      code = 'tier_rejected';
    } else if (status == 401) {
      code = 'authentication_error';
    } else if (status == 403) {
      code = 'access_denied';
    } else if (status == 429) {
      code = 'rate_limit';
    } else if ([400, 404, 422].contains(status)) {
      if (_tierError.hasMatch(lower)) {
        code = 'tier_rejected';
      } else if (lower.contains('image') &&
          ['support', 'invalid'].any(lower.contains)) {
        code = 'image_unsupported';
      } else if ([
        'unknown parameter',
        'unsupported parameter',
        'unsupported value',
        'tool_choice',
        'tool choice',
        'reasoning.effort',
        'parallel_tool_calls',
      ].any(lower.contains)) {
        code = 'api_request_rejected';
      } else if (lower.contains('model') &&
          [
            'model_not_found',
            'model not found',
            'does not exist',
            'not have access',
            'not supported',
          ].any(lower.contains)) {
        code = 'model_unavailable';
      } else {
        code = 'api_request_rejected';
      }
    } else if (status >= 500) {
      code = 'provider_error';
    }
    return ModelClickLabException(
      code,
      'HTTP $status: ${_clip(text, 500)}',
      status: 502,
    );
  }

  String _safe(Object? value) => _clip(
    redactSecrets(
      value is ModelClickLabException ? value.message : value.toString(),
      _secrets,
    ),
    600,
  );

  Object? _scrub(Object? value) {
    if (value is Map) {
      const banned = {
        'authorization',
        'apikey',
        'api_key',
        'token',
        'access_token',
        'refresh_token',
        'id_token',
        'headers',
        'history',
        'messages',
        'previous_response_id',
      };
      return {
        for (final entry in value.entries)
          if (!banned.contains(entry.key.toString().toLowerCase()))
            entry.key.toString(): _scrub(entry.value),
      };
    }
    if (value is List) return value.map(_scrub).toList();
    if (value is String) {
      return redactSecrets(
        value.replaceAll(RegExp(r'data:image/[^\s"\x27]+'), '[image omitted]'),
        _secrets,
      );
    }
    return value;
  }

  Future<void> _writeEvidence(Future<void> Function() write) {
    final next = _evidenceTail.then((_) {
      _ensureOpen();
      return write();
    });
    _evidenceTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _persistTrial(
    Map<String, Object?> trial,
    Map<String, Object?> output,
  ) => _writeEvidence(() async {
    await evidenceDirectory.create(recursive: true);
    final screenshots = Directory('${evidenceDirectory.path}/screenshots');
    await screenshots.create(recursive: true);
    final hash = trial['image_sha256']! as String;
    final file = File('${screenshots.path}/$hash.png');
    if (!await file.exists()) {
      await file.writeAsBytes(
        base64Decode(
          (trial['screenshot']! as String).substring(
            'data:image/png;base64,'.length,
          ),
        ),
        flush: true,
      );
    }
    final safeInput = {...trial}..remove('screenshot');
    final record = {
      'time': DateTime.now().toUtc().toIso8601String(),
      'input': safeInput,
      'screenshot_file': 'screenshots/$hash.png',
      'response': output,
    };
    await File('${evidenceDirectory.path}/trials.jsonl').writeAsString(
      '${jsonEncode(_scrub(record))}\n',
      mode: FileMode.append,
      flush: true,
    );
  });

  @override
  Future<Map<String, Object?>> saveResult(Map<String, Object?> input) async {
    _ensureOpen();
    final id = input['request_id'];
    if (id is! String || !_requestId.hasMatch(id)) {
      throw const ModelClickLabException(
        'invalid_request_id',
        'A valid request_id is required.',
      );
    }
    if (utf8.encode(jsonEncode(input)).length > 128 * 1024) {
      throw const ModelClickLabException(
        'result_too_large',
        'Result evidence exceeds 128 KiB.',
        status: 413,
      );
    }
    await _writeEvidence(() async {
      await evidenceDirectory.create(recursive: true);
      await File('${evidenceDirectory.path}/results.jsonl').writeAsString(
        '${jsonEncode(_scrub(input))}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    return {'saved': true, 'request_id': id};
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sessionKey = null;
    _catalog = null;
    _statuses.clear();
    _closedSignal.complete();
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    for (final socket in _sockets.toList()) {
      unawaited(socket.close());
    }
    _clients.clear();
    _sockets.clear();
    await _evidenceTail;
    if (_leases == 0) _secrets.clear();
  }
}

class _ConnectionLease {
  const _ConnectionLease(
    this.mode,
    this.revision,
    this.sessionKey,
    this.credentials,
  );
  final AuthMode mode;
  final int revision;
  final bool sessionKey;
  final Credentials? credentials;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) {
    throw const ModelClickLabException(
      'invalid_json',
      'Expected a JSON object.',
    );
  }
  return Map<String, Object?>.from(value);
}

Map<String, Object?> _maybeObject(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : {};
String _clip(String value, int length) =>
    value.length > length ? value.substring(0, length) : value;

Map<String, Object?> _validate(Map<String, Object?> input) {
  const allowed = {
    'model',
    'instruction',
    'screenshot',
    'width',
    'height',
    'screen',
    'request_id',
    'speed_tier',
    'connection_revision',
  };
  if (input.keys.any((key) => !allowed.contains(key))) {
    throw const ModelClickLabException(
      'unexpected_fields',
      'Trial accepts only model, instruction, screenshot, dimensions, screen, request_id, speed_tier, and connection_revision. No target data or history.',
    );
  }
  final model = input['model'],
      instruction = input['instruction'],
      id = input['request_id'];
  if (model is! String || !_modelId.hasMatch(model)) {
    throw const ModelClickLabException(
      'invalid_model',
      'Invalid model identifier.',
    );
  }
  if (id is! String || !_requestId.hasMatch(id)) {
    throw const ModelClickLabException(
      'invalid_request_id',
      'Invalid request identifier.',
    );
  }
  if (instruction is! String ||
      instruction.trim().isEmpty ||
      instruction.trim().length > 2000) {
    throw const ModelClickLabException(
      'invalid_instruction',
      'Instruction must contain between 1 and 2000 characters.',
    );
  }
  final tier = input['speed_tier'] ?? 'normal';
  if (tier is! String || !_tiers.containsKey(tier)) {
    throw const ModelClickLabException(
      'invalid_speed_tier',
      'Choose Normal, Fast, Ultrafast, or Flex.',
    );
  }
  final revision = input['connection_revision'];
  if (revision != null && (revision is! int || revision < 0)) {
    throw const ModelClickLabException(
      'invalid_connection_revision',
      'Connection revision must be a nonnegative integer.',
    );
  }
  final width = input['width'], height = input['height'];
  if (width is! int || height is! int) {
    throw const ModelClickLabException(
      'invalid_dimensions',
      'Screenshot dimensions must be integers.',
    );
  }
  final screen = input['screen'];
  if (screen is! Map ||
      screen.length != 3 ||
      !screen.keys.toSet().containsAll({
        'width',
        'height',
        'devicePixelRatio',
      })) {
    throw const ModelClickLabException(
      'invalid_screen',
      'Screen must contain only width, height, and devicePixelRatio.',
    );
  }
  for (final key in ['width', 'height', 'devicePixelRatio']) {
    final value = screen[key];
    final isDpr = key == 'devicePixelRatio';
    if (value is! num ||
        !value.isFinite ||
        value < (isDpr ? 0.25 : 1) ||
        value > (isDpr ? 8 : 32768)) {
      throw const ModelClickLabException(
        'invalid_screen',
        'Invalid display dimensions or devicePixelRatio.',
      );
    }
  }
  final screenshot = input['screenshot'];
  const prefix = 'data:image/png;base64,';
  if (screenshot is! String || !screenshot.startsWith(prefix)) {
    throw const ModelClickLabException(
      'invalid_screenshot',
      'Screenshot must be a PNG data URL.',
    );
  }
  final encoded = screenshot.substring(prefix.length);
  if (encoded.length > ((_maxImageBytes + 2) ~/ 3) * 4) {
    throw const ModelClickLabException(
      'screenshot_too_large',
      'PNG screenshot exceeds 6 MiB.',
      status: 413,
    );
  }
  Uint8List bytes;
  try {
    if (encoded.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
      throw const FormatException();
    }
    bytes = base64Decode(encoded);
  } on FormatException {
    throw const ModelClickLabException(
      'invalid_screenshot',
      'Screenshot contains invalid base64.',
    );
  }
  if (bytes.length > _maxImageBytes) {
    throw const ModelClickLabException(
      'screenshot_too_large',
      'PNG screenshot exceeds 6 MiB.',
      status: 413,
    );
  }
  final dimensions = _pngDimensions(bytes);
  if (width != dimensions.$1 || height != dimensions.$2) {
    throw const ModelClickLabException(
      'dimension_mismatch',
      'Declared dimensions do not match the PNG screenshot.',
    );
  }
  return {
    ...input,
    'instruction': instruction.trim(),
    'speed_tier': tier,
    'screen': Map<String, Object?>.from(screen),
    'image_sha256': sha256.convert(bytes).toString(),
    'image_bytes': bytes.length,
  };
}

final _crcTable = List<int>.generate(256, (value) {
  var crc = value;
  for (var i = 0; i < 8; i++) {
    crc = (crc & 1) != 0 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
  }
  return crc;
});

(int, int) _pngDimensions(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 45 ||
      !List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v)) {
    throw const ModelClickLabException(
      'invalid_screenshot',
      'Screenshot must be a valid PNG.',
    );
  }
  final data = ByteData.sublistView(bytes);
  var offset = 8, width = 0, height = 0;
  var imageData = false, ended = false;
  while (offset + 12 <= bytes.length) {
    final size = data.getUint32(offset);
    final end = offset + size + 12;
    if (size > _maxImageBytes || end > bytes.length) {
      throw const ModelClickLabException(
        'invalid_screenshot',
        'Truncated PNG chunk.',
      );
    }
    final tag = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    var crc = 0xffffffff;
    for (var i = offset + 4; i < end - 4; i++) {
      crc = _crcTable[(crc ^ bytes[i]) & 255] ^ (crc >> 8);
    }
    if ((crc ^ 0xffffffff) != data.getUint32(end - 4)) {
      throw const ModelClickLabException(
        'invalid_screenshot',
        'PNG checksum mismatch.',
      );
    }
    if (offset == 8) {
      if (tag != 'IHDR' || size != 13) {
        throw const ModelClickLabException(
          'invalid_screenshot',
          'PNG does not begin with IHDR.',
        );
      }
      width = data.getUint32(offset + 8);
      height = data.getUint32(offset + 12);
      if (width < 16 ||
          width > 8192 ||
          height < 16 ||
          height > 8192 ||
          width * height > 16777216) {
        throw const ModelClickLabException(
          'invalid_screenshot',
          'PNG dimensions exceed the 16-megapixel test limit.',
        );
      }
    } else if (tag == 'IHDR') {
      throw const ModelClickLabException(
        'invalid_screenshot',
        'PNG has multiple IHDR chunks.',
      );
    }
    if (tag == 'IDAT') imageData = true;
    if (tag == 'IEND') {
      if (size != 0 || end != bytes.length) {
        throw const ModelClickLabException(
          'invalid_screenshot',
          'Invalid PNG ending.',
        );
      }
      ended = true;
      break;
    }
    offset = end;
  }
  if (!ended || !imageData) {
    throw const ModelClickLabException(
      'invalid_screenshot',
      'PNG is missing image data or its ending.',
    );
  }
  return (width, height);
}

Map<String, Object?> _parseAction(Object? calls, int width, int height) {
  if (calls is! List ||
      calls.length != 1 ||
      calls.first is! Map ||
      (calls.first as Map)['name'] != 'screen_action') {
    throw const ModelClickLabException(
      'invalid_output',
      'Model must return exactly one screen_action call.',
      status: 422,
    );
  }
  final raw = (calls.first as Map)['arguments'];
  Object? action;
  try {
    action = raw is String ? jsonDecode(raw) : raw;
  } on FormatException {
    throw const ModelClickLabException(
      'invalid_output',
      'Model returned invalid tool JSON.',
      status: 422,
    );
  }
  if (action is! Map ||
      action.length != 3 ||
      !action.keys.toSet().containsAll({'action', 'x', 'y'}) ||
      !['click', 'move'].contains(action['action'])) {
    throw const ModelClickLabException(
      'invalid_output',
      'Model tool must contain only action, x, and y.',
      status: 422,
    );
  }
  final x = action['x'], y = action['y'];
  if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
    throw const ModelClickLabException(
      'invalid_coordinates',
      'Model coordinates are not finite numbers.',
      status: 422,
    );
  }
  if (x < 0 || y < 0 || x >= width || y >= height) {
    throw const ModelClickLabException(
      'out_of_bounds',
      'Model coordinates are outside the screenshot; no clamping was applied.',
      status: 422,
    );
  }
  return Map<String, Object?>.from(action);
}

class _ProviderTiming {
  final _watch = Stopwatch();
  int? payloadBytes;
  double? uploadComplete,
      uploadDuration,
      uploadEnqueued,
      firstToken,
      firstOutput,
      finishMs;
  String status = 'not_started';
  String? firstOutputSource, measurement;
  String note =
      'No provider request was started; timing stages are unavailable.';
  double get elapsed => _watch.elapsedMicroseconds / 1000;

  void start(int bytes, String mechanism, String explanation) {
    payloadBytes = bytes;
    measurement = mechanism;
    note = explanation;
    status = 'running';
    _watch.start();
  }

  void uploaded(double bodyStart) {
    uploadComplete = elapsed;
    uploadDuration = elapsed - bodyStart;
  }

  void enqueued() {
    uploadEnqueued = elapsed;
  }

  bool _hasText(Object? value) => value is String && value.isNotEmpty;
  bool _hasOutput(Object? item) {
    if (item is! Map) return false;
    if (item['type'] == 'function_call') return _hasText(item['arguments']);
    final content = item['content'];
    return content is List &&
        content.any(
          (part) =>
              part is Map &&
              ['text', 'output_text'].contains(part['type']) &&
              _hasText(part['text']),
        );
  }

  void observe(Map<String, Object?> event) {
    final type = event['type'];
    if ([
          'response.output_text.delta',
          'response.text.delta',
          'response.function_call_arguments.delta',
        ].contains(type) &&
        _hasText(event['delta'])) {
      firstToken ??= elapsed;
      firstOutput ??= firstToken;
      firstOutputSource ??= 'stream_delta';
      return;
    }
    var output =
        type == 'response.function_call_arguments.done' &&
            _hasText(event['arguments']) ||
        ['response.output_text.done', 'response.text.done'].contains(type) &&
            _hasText(event['text']) ||
        type == 'response.output_item.done' && _hasOutput(event['item']);
    if ([
      'response.completed',
      'response.incomplete',
      'response.failed',
      'response.done',
    ].contains(type)) {
      final items = _maybeObject(event['response'])['output'];
      output = output || items is List && items.any(_hasOutput);
    }
    if (output && firstOutput == null) {
      firstOutput = elapsed;
      firstOutputSource = 'final_only';
    }
  }

  void finish(String value) {
    if (!_watch.isRunning || finishMs != null) return;
    finishMs = elapsed;
    status = value;
    _watch.stop();
  }

  Map<String, Object?> snapshot() => {
    'origin': 'provider_request_start',
    'upload_complete_ms': uploadComplete,
    'upload_duration_ms': uploadDuration,
    'upload_enqueued_ms': uploadEnqueued,
    'first_token_ms': firstToken,
    'first_output_ms': firstOutput,
    'first_output_source': firstOutputSource,
    'finish_ms': finishMs,
    'status': status,
    'upload_measurement': measurement,
    'note': note,
  };
}
