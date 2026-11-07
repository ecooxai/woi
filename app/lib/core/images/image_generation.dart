import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../auth/auth.dart';
import '../models/message.dart';
import '../responses/responses_client.dart'
    show SseParser, kCodexResponsesUrl, ResponsesClient;
import '../util/image_mime.dart';
import 'image_encoding.dart';
import 'image_model_catalog.dart';

class ImageGenerationException implements Exception {
  const ImageGenerationException(this.message, {this.status, this.code});
  final String message;
  final int? status;
  final String? code;
  @override
  String toString() =>
      'Image generation${status == null ? '' : ' (HTTP $status)'}: $message';
}

/// One image request, independent of the conversational audio/text connection.
/// The caller schedules this future in the background and retains its original
/// conversation. Credentials and chosen model are snapshotted when it starts.
class ImageGenerationClient {
  ImageGenerationClient({
    required this.credentials,
    Uri? apiEndpoint,
    Uri? apiEditsEndpoint,
    Uri? codexEndpoint,
    HttpClient Function()? httpClient,
    this.timeout = const Duration(minutes: 5),
  }) : apiEndpoint =
           apiEndpoint ??
           Uri.parse('https://api.openai.com/v1/images/generations'),
       apiEditsEndpoint =
           apiEditsEndpoint ??
           Uri.parse('https://api.openai.com/v1/images/edits'),
       codexEndpoint = codexEndpoint ?? kCodexResponsesUrl,
       _httpClient = httpClient ?? HttpClient.new;

  final Future<Credentials?> Function() credentials;
  final Uri apiEndpoint;
  final Uri apiEditsEndpoint;
  final Uri codexEndpoint;
  final HttpClient Function() _httpClient;
  final Duration timeout;
  final _active = <HttpClient>{};
  bool _closed = false;
  // A completed image can occur in both output_item.done and response.completed.
  static const maxResponseBytes = 112 * 1024 * 1024;
  static const maxInputImages = 16;
  static const maxInputJpegBytes = 14 * 1024 * 1024;
  static const maxTotalInputJpegBytes = 32 * 1024 * 1024;

  void close() {
    _closed = true;
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }

  Future<ImageAttachment> generate({
    required String prompt,
    required String model,
    required String quality,
    required String textModel,
    required Directory outputDirectory,
    String size = kDefaultImageSize,
    String outputFormat = kDefaultImageFormat,
    List<ImageAttachment> inputImages = const [],
  }) async {
    if (_closed) {
      throw const ImageGenerationException('The image service has closed.');
    }
    if (prompt.trim().isEmpty) {
      throw const ImageGenerationException('An image prompt is required.');
    }
    if (prompt.length > 32000) {
      throw const ImageGenerationException(
        'The image prompt is too long (maximum 32,000 characters).',
      );
    }
    if (model.trim().isEmpty) {
      throw const ImageGenerationException(
        'Choose an image model in Settings.',
      );
    }
    if (!const {
      'auto',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    }.contains(quality)) {
      throw const ImageGenerationException(
        'The image quality must be auto, low, medium, high, xhigh or max.',
      );
    }
    if (!const {'jpeg', 'png', 'webp'}.contains(outputFormat)) {
      throw const ImageGenerationException(
        'The image format must be jpeg, png or webp.',
      );
    }
    int? targetWidth;
    int? targetHeight;
    if (size != 'auto') {
      final dimensions = RegExp(r'^(\d{2,5})x(\d{2,5})$').firstMatch(size);
      final width = dimensions == null ? 0 : int.parse(dimensions.group(1)!);
      final height = dimensions == null ? 0 : int.parse(dimensions.group(2)!);
      if (width <= 0 ||
          height <= 0 ||
          width % 16 != 0 ||
          height % 16 != 0 ||
          width * height > kMaximumImagePixels ||
          width > height * 3 ||
          height > width * 3) {
        throw const ImageGenerationException(
          'Choose auto or image dimensions divisible by 16 with an aspect ratio between 1:3 and 3:1.',
        );
      }
      targetWidth = width;
      targetHeight = height;
    }
    if (inputImages.length > maxInputImages) {
      throw const ImageGenerationException(
        'An image edit supports up to 16 reference images.',
      );
    }
    // Snapshot references before the caller can mutate its conversation/list.
    final references = List<ImageAttachment>.of(inputImages);
    final creds = await credentials();
    if (creds == null) {
      throw const ImageGenerationException(
        'Sign in with Codex or add an API key in Settings.',
      );
    }
    if (_closed) {
      throw const ImageGenerationException('The image service has closed.');
    }
    final client = _httpClient();
    _active.add(client);
    final watch = Stopwatch()..start();
    try {
      final inputs = await _readInputImages(references).timeout(timeout);
      _checkOpen();
      final raw = await _request(
        client,
        creds,
        prompt,
        model,
        quality,
        textModel,
        size,
        outputFormat,
        inputs,
      ).timeout(_remaining(watch));
      _checkOpen();
      final providerInfo = img.findDecoderForData(raw)?.startDecode(raw);
      if (providerInfo == null ||
          providerInfo.width <= 0 ||
          providerInfo.height <= 0) {
        throw const ImageGenerationException(
          'The provider returned an invalid image.',
        );
      }
      final bytes = await normalizeImageEncoding(
        raw,
        outputFormat: outputFormat,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      ).timeout(_remaining(watch));
      if (_closed) {
        throw const ImageGenerationException(
          'The image request was cancelled.',
        );
      }
      final info = img.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0) {
        throw const ImageGenerationException(
          'The provider returned an invalid image.',
        );
      }
      await outputDirectory.create(recursive: true);
      final ext = imageExtOf(bytes);
      final file = File(
        p.join(outputDirectory.path, '${newId('generated-')}.$ext'),
      );
      final temporary = File('${file.path}.tmp');
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        if (_closed) {
          throw const ImageGenerationException(
            'The image request was cancelled.',
          );
        }
        await temporary.rename(file.path);
        if (_closed) {
          await file.delete();
          throw const ImageGenerationException(
            'The image request was cancelled.',
          );
        }
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      watch.stop();
      return ImageAttachment(
        path: file.path,
        width: info.width,
        height: info.height,
        originalWidth: providerInfo.width,
        originalHeight: providerInfo.height,
        byteSize: bytes.length,
        generationDurationMs: watch.elapsedMilliseconds,
        generationModel: model,
        generationQuality: quality,
      );
    } on ImageGenerationException catch (e) {
      throw ImageGenerationException(
        redactSecrets(e.message, [creds.bearerToken]),
        status: e.status,
        code: e.code == null
            ? null
            : redactSecrets(e.code!, [creds.bearerToken]),
      );
    } on TimeoutException {
      throw ImageGenerationException(
        'The request timed out after ${watch.elapsed.inSeconds}s. No image was returned.',
      );
    } catch (e) {
      throw ImageGenerationException(redactSecrets('$e', [creds.bearerToken]));
    } finally {
      _active.remove(client);
      client.close(force: true);
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw const ImageGenerationException('The image request was cancelled.');
    }
  }

  Duration _remaining(Stopwatch watch) {
    final left = timeout - watch.elapsed;
    if (left <= Duration.zero) {
      throw TimeoutException('Image request timed out');
    }
    return left;
  }

  Future<List<Uint8List>> _readInputImages(
    List<ImageAttachment> references,
  ) async {
    final images = <Uint8List>[];
    var total = 0;
    for (var i = 0; i < references.length; i++) {
      _checkOpen();
      final file = File(references[i].path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw ImageGenerationException(
          'Reference image ${i + 1} is no longer available.',
        );
      }
      if (stat.size <= 0 || stat.size > kMaximumEncodedImageBytes) {
        throw ImageGenerationException(
          'Reference image ${i + 1} is empty or too large to process.',
        );
      }
      final jpeg = await normalizeImageToJpeg(await file.readAsBytes());
      _checkOpen();
      total += jpeg.length;
      if (jpeg.length > maxInputJpegBytes || total > maxTotalInputJpegBytes) {
        throw const ImageGenerationException(
          'The reference images are too large to send together. Use fewer or smaller images.',
        );
      }
      images.add(jpeg);
    }
    return images;
  }

  Future<Uint8List> _request(
    HttpClient client,
    Credentials creds,
    String prompt,
    String model,
    String quality,
    String textModel,
    String size,
    String outputFormat,
    List<Uint8List> inputImages,
  ) async {
    final api = creds.mode == AuthMode.apiKey;
    final edit = inputImages.isNotEmpty;
    final nativePrompt = size == 'auto'
        ? prompt
        : '$prompt\n\nOutput requirement: exactly $size pixels. Keep all requested content inside this canvas without cropping or stretching.';
    final endpoint = api
        ? (edit ? apiEditsEndpoint : apiEndpoint)
        : codexEndpoint;
    final req = await client.postUrl(endpoint);
    creds.headers().forEach(req.headers.set);
    req.headers.set(
      HttpHeaders.acceptHeader,
      api ? 'application/json' : 'text/event-stream',
    );
    if (api && edit) {
      _writeEditMultipart(req, {
        'model': model,
        'prompt': prompt,
        'quality': quality,
        'size': size,
        'n': '1',
        'output_format': outputFormat,
      }, inputImages);
    } else {
      final body = api
          ? <String, Object?>{
              'model': model,
              'prompt': prompt,
              'quality': quality,
              'size': size,
              'n': 1,
              'output_format': outputFormat,
            }
          : <String, Object?>{
              'model': textModel,
              'instructions': edit
                  ? 'Edit the supplied reference images as requested with the image_generation tool. Preserve details the user did not ask to change. Return one edited image. Do not claim success without an image result.'
                  : 'Generate the image requested by the user with the image_generation tool. Return one image. Do not claim success without an image result.',
              'input': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'input_text', 'text': nativePrompt},
                    for (final image in inputImages)
                      {
                        'type': 'input_image',
                        'image_url':
                            'data:image/jpeg;base64,${base64Encode(image)}',
                      },
                  ],
                },
              ],
              'tools': [
                {
                  'type': 'image_generation',
                  'model': model,
                  'quality': quality,
                  'size': size,
                  'output_format': outputFormat,
                  'action': edit ? 'edit' : 'generate',
                },
              ],
              'tool_choice': {'type': 'image_generation'},
              'stream': true,
              'store': false,
            };
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final response = await req.close();
    final quota = <String, String>{};
    response.headers.forEach((key, values) {
      if (key.startsWith('x-codex-') && key != 'x-codex-turn-state') {
        quota[key] = values.join(',');
      }
    });
    if (quota.isNotEmpty) {
      try {
        ResponsesClient.onQuotaHeaders?.call(Map.unmodifiable(quota));
      } catch (_) {
        // A UI quota observer must not discard a completed image response.
      }
    }
    if (response.statusCode != 200) {
      final error = await _readBounded(response, 64 * 1024);
      throw _providerError(
        utf8.decode(error, allowMalformed: true),
        creds,
        response.statusCode,
        model,
      );
    }
    if (api) {
      final raw = await _readBounded(response, maxResponseBytes);
      return decodeImageResult(jsonDecode(utf8.decode(raw)));
    }
    return collectCodexImage(
      _limited(response, maxResponseBytes),
      model: model,
      secrets: [creds.bearerToken],
    );
  }

  /// Images edits accepts multipart uploads; references are already validated
  /// JPEG copies. Fixed filenames avoid exposing local paths in request headers.
  /// https://developers.openai.com/api/reference/resources/images/methods/edit
  static void _writeEditMultipart(
    HttpClientRequest request,
    Map<String, String> fields,
    List<Uint8List> images,
  ) {
    final boundary = 'woi-image-${newId('part-')}';
    final parts = <List<int>>[];
    for (final field in fields.entries) {
      parts.add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="${field.key}"\r\n\r\n${field.value}\r\n',
        ),
      );
    }
    for (var i = 0; i < images.length; i++) {
      parts.add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="image[]"; filename="reference-${i + 1}.jpg"\r\nContent-Type: image/jpeg\r\n\r\n',
        ),
      );
      parts.add(images[i]);
      parts.add(const [13, 10]);
    }
    parts.add(utf8.encode('--$boundary--\r\n'));
    request.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: {'boundary': boundary},
    );
    request.contentLength = parts.fold<int>(
      0,
      (length, part) => length + part.length,
    );
    for (final part in parts) {
      request.add(part);
    }
  }

  static Future<Uint8List> _readBounded(
    Stream<List<int>> source,
    int limit,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in _limited(source, limit)) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Stream<List<int>> _limited(
    Stream<List<int>> source,
    int limit,
  ) async* {
    var count = 0;
    await for (final chunk in source) {
      count += chunk.length;
      if (count > limit) {
        throw const ImageGenerationException(
          'The image response exceeded the supported size.',
        );
      }
      yield chunk;
    }
  }

  static ImageGenerationException _providerError(
    String raw,
    Credentials creds,
    int status,
    String model,
  ) {
    String message = raw;
    String? code;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          message =
              '${error['message'] ?? 'The provider rejected the image request.'}';
          code = '${error['code'] ?? error['type'] ?? ''}';
        } else {
          message =
              '${decoded['detail'] ?? 'The provider rejected the image request.'}';
        }
      }
    } catch (_) {}
    message = redactSecrets(message, [creds.bearerToken]);
    if (message.length > 600) message = '${message.substring(0, 600)}…';
    final hint = status == 400 || status == 403 || status == 404
        ? ' The selected model is $model. Check image model access in Settings; no replacement model was used.'
        : '';
    return ImageGenerationException(
      '$message$hint',
      status: status,
      code: code,
    );
  }

  /// Supports GPT Image's Images API and completed Responses tool payloads.
  /// URL results are deliberately not fetched: GPT Image returns base64 and no
  /// bearer token should ever be forwarded to a provider-supplied URL.
  static Uint8List decodeImageResult(Object? body) {
    String? encoded;
    if (body is Map) {
      final data = body['data'];
      if (data is List && data.isNotEmpty && data.first is Map) {
        encoded = data.first['b64_json'] as String?;
      }
      if (body['type'] == 'image_generation_call') {
        encoded = body['result'] as String?;
      }
      final output = body['output'];
      if (output is List) {
        for (final item in output) {
          if (item is Map &&
              item['type'] == 'image_generation_call' &&
              item['result'] is String) {
            encoded = item['result'] as String;
            break;
          }
        }
      }
    }
    if (encoded == null || encoded.isEmpty) {
      throw const ImageGenerationException(
        'The provider completed without returning an image.',
      );
    }
    if (encoded.length > 48 * 1024 * 1024) {
      throw const ImageGenerationException(
        'The generated image exceeded the supported size.',
      );
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty) throw const FormatException('empty image');
      return bytes;
    } on FormatException {
      throw const ImageGenerationException(
        'The provider returned invalid image data.',
      );
    }
  }

  /// Wait for a confirmed completed response; an image output item followed by
  /// a failed/incomplete event must not be presented as a successful result.
  static Future<Uint8List> collectCodexImage(
    Stream<List<int>> stream, {
    required String model,
    Iterable<String> secrets = const [],
  }) async {
    Object? completedItem;
    await for (final event in stream.transform(const SseParser())) {
      if (event.data == '[DONE]') break;
      final decoded = jsonDecode(event.data);
      if (decoded is! Map) continue;
      final type = decoded['type'] ?? event.event;
      if (type == 'response.output_item.done') {
        final item = decoded['item'];
        if (item is Map &&
            item['type'] == 'image_generation_call' &&
            item['result'] is String) {
          completedItem = item;
        }
      }
      if (type == 'response.completed') {
        final response = decoded['response'];
        if (response is Map &&
            response['status'] != null &&
            response['status'] != 'completed') {
          throw const ImageGenerationException(
            'The image response did not complete.',
          );
        }
        try {
          return decodeImageResult(response);
        } on ImageGenerationException {
          if (completedItem != null) return decodeImageResult(completedItem);
          rethrow;
        }
      }
      if (type == 'error' ||
          type == 'response.failed' ||
          type == 'response.incomplete') {
        final response = decoded['response'];
        final error =
            decoded['error'] ?? (response is Map ? response['error'] : null);
        var message = error is Map
            ? '${error['message'] ?? error['code'] ?? 'The image request failed.'}'
            : '${decoded['message'] ?? 'The image request did not complete.'}';
        message = redactSecrets(message, secrets);
        if (message.length > 600) message = message.substring(0, 600);
        throw ImageGenerationException(
          '${redactSecrets(message)} Selected image model: $model.',
        );
      }
    }
    throw const ImageGenerationException(
      'The image stream ended before completion.',
    );
  }
}
