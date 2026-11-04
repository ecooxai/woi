import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../auth/auth.dart';
import '../util/usage_limit.dart';

/// ChatGPT-login endpoint (research/REALTIME_API.md §4).
final kCodexResponsesUrl = Uri.parse('https://chatgpt.com/backend-api/codex/responses');

/// Public API endpoint used with an API key.
final kOpenAiResponsesUrl = Uri.parse('https://api.openai.com/v1/responses');

class ResponsesException implements Exception, HasErrorBody {
  ResponsesException(this.message, {this.status, this.code, this.errorBody});
  final String message;
  final int? status;
  final String? code;

  /// The raw (redacted) error response, e.g. the 429 usage-limit JSON.
  @override
  final String? errorBody;
  @override
  String toString() => 'Responses API error${status == null ? '' : ' $status'}: $message';
}

class FunctionCallItem {
  const FunctionCallItem({required this.callId, required this.name, required this.arguments});
  final String callId;
  final String name;
  final String arguments;

  /// Input item to send back on the next turn (no server id: store=false).
  Map<String, Object?> toInput() => {'type': 'function_call', 'call_id': callId, 'name': name, 'arguments': arguments};
}

class ResponsesResult {
  ResponsesResult({
    required this.text,
    required this.functionCalls,
    required this.status,
    this.usage,
    this.timeToFirstEvent,
    this.timeToFirstToken,
    this.total,
    this.quota = const {},
  });

  final String text;
  final List<FunctionCallItem> functionCalls;
  final String status;
  final Map<String, Object?>? usage;
  final Duration? timeToFirstEvent;
  final Duration? timeToFirstToken;
  final Duration? total;

  /// `x-codex-*` plan quota headers (never x-codex-turn-state).
  final Map<String, String> quota;

  int get totalTokens => (usage?['total_tokens'] as num?)?.toInt() ?? 0;

  /// Output items to append to the input for the next turn.
  List<Map<String, Object?>> get outputAsInput => [
    if (text.isNotEmpty)
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
    for (final c in functionCalls) c.toInput(),
  ];
}

/// One parsed server-sent event.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String? event;
  final String data;
}

/// Incremental SSE parser. Works on raw bytes and does not depend on the
/// Content-Type header (the ChatGPT endpoint sends none, §4 gotcha).
class SseParser extends StreamTransformerBase<List<int>, SseEvent> {
  const SseParser();

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) async* {
    String? event;
    final data = <String>[];
    await for (final line in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          data.add(value);
      }
    }
    if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
  }
}

/// Builds the image input part for a PNG/JPEG.
Map<String, Object?> inputImage(Uint8List bytes) {
  final mime = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 ? 'image/jpeg' : 'image/png';
  return {'type': 'input_image', 'image_url': 'data:$mime;base64,${base64Encode(bytes)}'};
}

Map<String, Object?> userMessage(List<Map<String, Object?>> content) => {
  'type': 'message',
  'role': 'user',
  'content': content,
};

Map<String, Object?> inputText(String text) => {'type': 'input_text', 'text': text};

/// Streaming client for the Responses API (`stream: true`, `store: false`,
/// both mandatory on the ChatGPT endpoint). Codex credentials go to
/// chatgpt.com/backend-api/codex/responses, an API key to api.openai.com.
class ResponsesClient {
  ResponsesClient({
    required this.credentials,
    Uri? codexEndpoint,
    Uri? apiKeyEndpoint,
    HttpClient Function()? httpClient,
    this.timeout = const Duration(minutes: 5),
    this.reuseConnections = false,
  }) : codexEndpoint = codexEndpoint ?? kCodexResponsesUrl,
       apiKeyEndpoint = apiKeyEndpoint ?? kOpenAiResponsesUrl,
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Credentials?> Function() credentials;
  final Uri codexEndpoint;
  final Uri apiKeyEndpoint;
  final HttpClient Function() _httpClient;
  final Duration timeout;

  /// Receives the `x-codex-*` plan quota headers of every response (all
  /// clients, errors included): the app's CodexUsage listens here.
  static void Function(Map<String, String> quota)? onQuotaHeaders;

  /// Keep one HttpClient (and its TLS connection) alive across requests;
  /// saves the handshake on latency-critical paths (gpt-live delegation).
  /// Call [close] when done.
  final bool reuseConnections;
  HttpClient? _shared;

  HttpClient _client() =>
      reuseConnections ? (_shared ??= _httpClient()..idleTimeout = const Duration(minutes: 2)) : _httpClient();

  /// Opens the (reused) connection ahead of the first request. Best effort.
  Future<void> warmUp() async {
    if (!reuseConnections) return;
    try {
      final req = await _client().openUrl('HEAD', codexEndpoint).timeout(const Duration(seconds: 5));
      await (await req.close().timeout(const Duration(seconds: 5))).drain<void>();
    } catch (_) {}
  }

  void close() {
    _shared?.close(force: true);
    _shared = null;
  }

  /// Runs one request and collects the streamed result.
  Future<ResponsesResult> create({
    required String model,
    required List<Map<String, Object?>> input,
    String? instructions,
    List<Map<String, Object?>>? tools,
    Map<String, Object?>? reasoning,
    void Function(String delta)? onTextDelta,
    void Function(FunctionCallItem call)? onFunctionCall,
    bool parallelToolCalls = false,
  }) async {
    final creds = await credentials();
    if (creds == null) throw ResponsesException('Not signed in (no Codex login or API key)');
    final body = <String, Object?>{
      'model': model,
      'instructions': ?instructions,
      'input': input,
      if (tools != null && tools.isNotEmpty) ...{
        'tools': tools,
        'tool_choice': 'auto',
        'parallel_tool_calls': parallelToolCalls,
      },
      'reasoning': ?reasoning,
      'stream': true,
      'store': false,
    };
    final url = creds.mode == AuthMode.apiKey ? apiKeyEndpoint : codexEndpoint;
    final client = _client();
    final sw = Stopwatch()..start();
    try {
      final req = await client.postUrl(url).timeout(const Duration(seconds: 30));
      creds.headers().forEach(req.headers.set);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final quota = <String, String>{};
      res.headers.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk.startsWith('x-codex-') && lk != 'x-codex-turn-state') quota[lk] = v.join(',');
      });
      if (quota.isNotEmpty) {
        try {
          onQuotaHeaders?.call(Map.unmodifiable(quota));
        } catch (_) {}
      }
      if (res.statusCode != 200) {
        final text = await utf8.decodeStream(res).timeout(const Duration(seconds: 30), onTimeout: () => '');
        String? code;
        var msg = text;
        try {
          final j = jsonDecode(text);
          if (j is Map) {
            final err = j['error'];
            if (err is Map) {
              code = (err['code'] ?? err['type']) as String?;
              msg = err['message'] as String? ?? text;
            } else if (j['detail'] != null) {
              msg = '${j['detail']}';
            }
          }
        } catch (_) {}
        throw ResponsesException(
          redactSecrets(msg.length > 500 ? msg.substring(0, 500) : msg),
          status: res.statusCode,
          code: code,
          errorBody: redactSecrets(text.length > 2000 ? text.substring(0, 2000) : text),
        );
      }
      return await _collect(res.transform(const SseParser()), sw, quota, onTextDelta, onFunctionCall).timeout(timeout);
    } on ResponsesException {
      rethrow;
    } on TimeoutException {
      throw ResponsesException('request timed out after ${sw.elapsed.inSeconds}s');
    } catch (e) {
      throw ResponsesException(redactSecrets('$e'));
    } finally {
      if (!reuseConnections) client.close(force: true);
    }
  }

  static Future<ResponsesResult> _collect(
    Stream<SseEvent> events,
    Stopwatch sw,
    Map<String, String> quota,
    void Function(String)? onTextDelta, [
    void Function(FunctionCallItem)? onFunctionCall,
  ]) async {
    final text = StringBuffer();
    final calls = <FunctionCallItem>[];
    final seenCalls = <String>{};
    Duration? firstEvent, firstToken;
    Map<String, Object?>? usage;
    var status = 'incomplete';
    String? finalText;
    // Iterate manually so that after `response.completed` the rest of the
    // body (chunked terminator) is drained in the background: cancelling an
    // HttpClientResponse early destroys its socket, which would defeat the
    // kept-alive connection ([reuseConnections]).
    final it = StreamIterator(events);
    try {
      while (await it.moveNext()) {
        final e = it.current;
        if (e.data == '[DONE]') break;
        Map<String, Object?> ev;
        try {
          final j = jsonDecode(e.data);
          if (j is! Map) continue;
          ev = j.cast<String, Object?>();
        } catch (_) {
          continue;
        }
        firstEvent ??= sw.elapsed;
        final type = ev['type'] as String? ?? e.event ?? '';
        switch (type) {
          case 'response.output_text.delta':
            final d = ev['delta'] as String? ?? '';
            firstToken ??= sw.elapsed;
            text.write(d);
            onTextDelta?.call(d);
          case 'response.output_item.done':
            final item = (ev['item'] as Map?)?.cast<String, Object?>();
            if (item?['type'] == 'function_call') {
              final id = item!['call_id'] as String? ?? '';
              firstToken ??= sw.elapsed;
              if (seenCalls.add(id)) {
                final call = FunctionCallItem(
                  callId: id,
                  name: item['name'] as String? ?? '',
                  arguments: item['arguments'] as String? ?? '{}',
                );
                calls.add(call);
                onFunctionCall?.call(call);
              }
            }
          case 'response.completed' || 'response.incomplete' || 'response.failed':
            final r = (ev['response'] as Map?)?.cast<String, Object?>();
            status = r?['status'] as String? ?? type.split('.').last;
            usage = (r?['usage'] as Map?)?.cast<String, Object?>();
            if (type == 'response.failed') {
              final err = (r?['error'] as Map?)?.cast<String, Object?>();
              throw ResponsesException(
                redactSecrets(err?['message'] as String? ?? 'response failed'),
                code: err?['code'] as String?,
              );
            }
            if (text.isEmpty) finalText = _textFromOutput(r?['output']);
          case 'error':
            final err = (ev['error'] as Map?)?.cast<String, Object?>() ?? ev;
            throw ResponsesException(
              redactSecrets(err['message'] as String? ?? 'stream error'),
              code: err['code'] as String?,
            );
        }
        if (type == 'response.completed' || type == 'response.incomplete') break;
      }
    } finally {
      unawaited(() async {
        try {
          while (await it.moveNext().timeout(const Duration(seconds: 10))) {}
        } catch (_) {
          await it.cancel();
        }
      }());
    }
    return ResponsesResult(
      text: text.isEmpty ? (finalText ?? '') : text.toString(),
      functionCalls: calls,
      status: status,
      usage: usage,
      timeToFirstEvent: firstEvent,
      timeToFirstToken: firstToken,
      total: sw.elapsed,
      quota: quota,
    );
  }

  static String? _textFromOutput(Object? output) {
    if (output is! List) return null;
    final sb = StringBuffer();
    for (final o in output) {
      if (o is Map && o['type'] == 'message' && o['content'] is List) {
        for (final c in o['content'] as List) {
          if (c is Map && c['type'] == 'output_text') sb.write(c['text'] ?? '');
        }
      }
    }
    return sb.isEmpty ? null : sb.toString();
  }
}
