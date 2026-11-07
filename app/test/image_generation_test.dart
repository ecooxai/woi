import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/images/image_generation.dart';
import 'package:woi/core/images/image_model_catalog.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/util/image_mime.dart';
import 'package:woi/platform/media_viewer.dart';

void main() {
  final png = img.encodePng(img.Image(width: 7, height: 5));
  final item = <String, Object?>{
    'type': 'image_generation_call',
    'status': 'completed',
    'result': base64Encode(png),
  };

  Stream<List<int>> events(List<Map<String, Object?>> values) =>
      Stream.fromIterable(
        values.map((value) => utf8.encode('data: ${jsonEncode(value)}\n\n')),
      );

  Future<Directory> output() async {
    final dir = await Directory.systemTemp.createTemp('woi-image-test-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  test(
    'only completed image results are accepted from Codex streams',
    () async {
      final bytes = await ImageGenerationClient.collectCodexImage(
        events([
          {'type': 'response.output_item.done', 'item': item},
          {
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': [item],
            },
          },
        ]),
        model: kDefaultImageModel,
      );
      expect(bytes, orderedEquals(png));
      for (final end in ['response.failed', 'response.incomplete']) {
        await expectLater(
          ImageGenerationClient.collectCodexImage(
            events([
              {'type': 'response.output_item.done', 'item': item},
              {
                'type': end,
                'response': {
                  'error': {'message': 'Generation stopped'},
                },
              },
            ]),
            model: kDefaultImageModel,
          ),
          throwsA(isA<ImageGenerationException>()),
        );
      }
      await expectLater(
        ImageGenerationClient.collectCodexImage(
          events([
            {'type': 'response.output_item.done', 'item': item},
          ]),
          model: kDefaultImageModel,
        ),
        throwsA(isA<ImageGenerationException>()),
      );
    },
  );

  test('image result parser rejects missing, URL-only and corrupt bytes', () {
    for (final value in [
      <String, Object?>{},
      {
        'data': [
          {'url': 'https://example.com/image.png'},
        ],
      },
      {
        'data': [
          {'b64_json': ''},
        ],
      },
      {
        'data': [
          {'b64_json': '!not-base64!'},
        ],
      },
    ]) {
      expect(
        () => ImageGenerationClient.decodeImageResult(value),
        throwsA(isA<ImageGenerationException>()),
      );
    }
    expect(
      ImageGenerationClient.decodeImageResult({
        'data': [
          {'b64_json': base64Encode(png)},
        ],
      }),
      orderedEquals(png),
    );
  });

  for (final mode in AuthMode.values) {
    test('$mode uses exact selected image model and persists real image facts', () async {
      final dir = await output();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}/images');
      Map<String, Object?>? sent;
      server.listen((request) async {
        sent = (jsonDecode(await utf8.decodeStream(request)) as Map)
            .cast<String, Object?>();
        expect(
          request.headers.value('authorization'),
          'Bearer fake-image-credential',
        );
        expect(
          request.headers.value('chatgpt-account-id'),
          mode == AuthMode.codex ? 'account-test' : isNull,
        );
        if (mode == AuthMode.codex) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: ${jsonEncode({'type': 'response.output_item.done', 'item': item})}\n\n',
          );
          request.response.write(
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {
                'status': 'completed',
                'output': [item],
              },
            })}\n\n',
          );
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {'b64_json': base64Encode(png)},
              ],
            }),
          );
        }
        await request.response.close();
      });
      final client = ImageGenerationClient(
        credentials: () async => Credentials(
          mode: mode,
          bearerToken: 'fake-image-credential',
          accountId: mode == AuthMode.codex ? 'account-test' : null,
        ),
        apiEndpoint: mode == AuthMode.apiKey
            ? endpoint
            : Uri.parse('http://127.0.0.1:1/unused'),
        codexEndpoint: mode == AuthMode.codex
            ? endpoint
            : Uri.parse('http://127.0.0.1:1/unused'),
      );
      addTearDown(client.close);
      final result = await client.generate(
        prompt: 'One green circle',
        model: kDefaultImageModel,
        quality: 'low',
        textModel: 'chosen-text-model',
        outputDirectory: dir,
      );
      final stored = await File(result.path).readAsBytes();
      expect(imageMimeOf(stored), 'image/jpeg');
      expect(result.path, endsWith('.jpg'));
      expect(img.decodeJpg(stored)!.width, 1024);
      expect(img.decodeJpg(stored)!.height, 1024);
      expect(result.width, 1024);
      expect(result.originalWidth, 7);
      expect(result.height, 1024);
      expect(result.originalHeight, 5);
      expect(result.byteSize, await File(result.path).length());
      expect(result.generationDurationMs, greaterThanOrEqualTo(0));
      expect(result.generationModel, kDefaultImageModel);
      expect(result.generationQuality, 'low');
      expect(await dir.list().length, 1);
      if (mode == AuthMode.apiKey) {
        expect(sent?['model'], kDefaultImageModel);
        expect(sent?['quality'], 'low');
        expect(sent?['n'], 1);
        expect(sent?['size'], '1024x1024');
        expect(sent?['output_format'], 'jpeg');
      } else {
        expect(sent?['model'], 'chosen-text-model');
        expect(sent?['stream'], isTrue);
        expect(sent?['store'], isFalse);
        expect(sent?['tool_choice'], {'type': 'image_generation'});
        expect(sent?['tools'], [
          {
            'type': 'image_generation',
            'model': kDefaultImageModel,
            'quality': 'low',
            'size': '1024x1024',
            'output_format': 'jpeg',
            'action': 'generate',
          },
        ]);
      }
    });
  }

  for (final mode in AuthMode.values) {
    test(
      '$mode edits with JPEG reference pixels and preserves source attachments',
      () async {
        final dir = await output();
        final source = File('${dir.path}/original.png');
        await source.writeAsBytes(png);
        final secondBytes = img.encodeJpg(img.Image(width: 3, height: 2));
        final second = File('${dir.path}/second.jpg');
        await second.writeAsBytes(secondBytes);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final endpoint = Uri.parse('http://127.0.0.1:${server.port}/edits');
        Uint8List? wire;
        String? boundary;
        String? contentType;
        String? authorization;
        String? requestPath;
        var requests = 0;
        server.listen((request) async {
          requests++;
          final buffer = BytesBuilder(copy: false);
          await for (final bytes in request) {
            buffer.add(bytes);
          }
          wire = buffer.takeBytes();
          contentType = request.headers.contentType?.mimeType;
          boundary = request.headers.contentType?.parameters['boundary'];
          authorization = request.headers.value('authorization');
          requestPath = request.uri.path;
          if (mode == AuthMode.apiKey) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'data': [
                  {'b64_json': base64Encode(png)},
                ],
              }),
            );
          } else {
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(
              'data: ${jsonEncode({
                'type': 'response.completed',
                'response': {
                  'status': 'completed',
                  'output': [item],
                },
              })}\n\n',
            );
          }
          await request.response.close();
        });
        final client = ImageGenerationClient(
          credentials: () async => Credentials(
            mode: mode,
            bearerToken: 'edit-test-credential',
            accountId: 'test-account',
          ),
          apiEndpoint: Uri.parse('http://127.0.0.1:1/generation-must-not-run'),
          apiEditsEndpoint: mode == AuthMode.apiKey
              ? endpoint
              : Uri.parse('http://127.0.0.1:1/api-must-not-run'),
          codexEndpoint: mode == AuthMode.codex
              ? endpoint
              : Uri.parse('http://127.0.0.1:1/codex-must-not-run'),
        );
        addTearDown(client.close);
        final result = await client.generate(
          prompt:
              'Keep the circle; add a café sign using the second reference.',
          model: kDefaultImageModel,
          quality: 'low',
          textModel: 'selected-text-model',
          outputDirectory: Directory('${dir.path}/generated'),
          inputImages: [
            ImageAttachment(
              path: source.path,
              width: 7,
              height: 5,
              originalWidth: 7,
              originalHeight: 5,
            ),
            ImageAttachment(
              path: second.path,
              width: 3,
              height: 2,
              originalWidth: 3,
              originalHeight: 2,
            ),
          ],
        );
        expect(requests, 1);
        expect(requestPath, '/edits');
        expect(authorization, 'Bearer edit-test-credential');
        final uploaded = <Uint8List>[];
        if (mode == AuthMode.apiKey) {
          expect(contentType, 'multipart/form-data');
          expect(boundary, isNotEmpty);
          final parts = parseMultipart(wire!, boundary!);
          final fields = {
            for (final part in parts.where((p) => p.filename == null))
              part.name: utf8.decode(part.bytes),
          };
          expect(fields, {
            'model': 'gpt-image-2.6-flare',
            'prompt':
                'Keep the circle; add a café sign using the second reference.',
            'quality': 'low',
            'size': '1024x1024',
            'n': '1',
            'output_format': 'jpeg',
          });
          final references = parts.where((p) => p.filename != null).toList();
          expect(references.map((p) => p.name), ['image[]', 'image[]']);
          expect(references.map((p) => p.filename), [
            'reference-1.jpg',
            'reference-2.jpg',
          ]);
          expect(references.map((p) => p.contentType), [
            'image/jpeg',
            'image/jpeg',
          ]);
          expect(latin1.decode(wire!), isNot(contains(source.path)));
          uploaded.addAll(references.map((p) => p.bytes));
        } else {
          expect(contentType, 'application/json');
          final body = jsonDecode(utf8.decode(wire!)) as Map;
          expect(body['model'], 'selected-text-model');
          expect(body['tools'], [
            {
              'type': 'image_generation',
              'model': 'gpt-image-2.6-flare',
              'quality': 'low',
              'size': '1024x1024',
              'output_format': 'jpeg',
              'action': 'edit',
            },
          ]);
          expect(body['tool_choice'], {'type': 'image_generation'});
          expect(body['store'], isFalse);
          final content =
              ((body['input'] as List).single as Map)['content'] as List;
          expect(
            (content.first as Map)['text'],
            contains('Output requirement: exactly 1024x1024 pixels.'),
          );
          expect(
            (content.first as Map)['text'],
            startsWith(
              'Keep the circle; add a café sign using the second reference.',
            ),
          );
          final references = content
              .where((p) => (p as Map)['type'] == 'input_image')
              .cast<Map>()
              .toList();
          expect(references, hasLength(2));
          for (final reference in references) {
            final url = reference['image_url'] as String;
            expect(url, startsWith('data:image/jpeg;base64,'));
            uploaded.add(base64Decode(url.split(',').last));
          }
          expect(utf8.decode(wire!), isNot(contains('input_fidelity')));
        }
        expect(uploaded.map(imageMimeOf), ['image/jpeg', 'image/jpeg']);
        expect(img.decodeJpg(uploaded[0])!.width, 7);
        expect(img.decodeJpg(uploaded[0])!.height, 5);
        expect(uploaded[1], orderedEquals(secondBytes));
        expect(await source.readAsBytes(), orderedEquals(png));
        expect(await second.readAsBytes(), orderedEquals(secondBytes));
        final stored = await File(result.path).readAsBytes();
        expect(imageMimeOf(stored), 'image/jpeg');
        expect(result.path, endsWith('.jpg'));
        expect(result.byteSize, stored.length);
        expect(result.width, 1024);
        expect(result.originalWidth, 7);
        expect(result.height, 1024);
        expect(result.originalHeight, 5);
      },
    );
  }

  test(
    'auto retains native provider resolution and already-correct JPEG bytes',
    () async {
      final dir = await output();
      final jpeg = img.encodeJpg(img.Image(width: 32, height: 16));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Map? body;
      server.listen((request) async {
        body = jsonDecode(await utf8.decodeStream(request)) as Map;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(jpeg)},
            ],
          }),
        );
        await request.response.close();
      });
      final client = ImageGenerationClient(
        credentials: () async => const Credentials(
          mode: AuthMode.apiKey,
          bearerToken: 'auto-test-credential',
        ),
        apiEndpoint: Uri.parse('http://127.0.0.1:${server.port}/images'),
      );
      addTearDown(client.close);
      final result = await client.generate(
        prompt: 'A circle',
        model: kDefaultImageModel,
        quality: 'low',
        textModel: 'text',
        outputDirectory: dir,
        size: 'auto',
      );
      expect(body?['size'], 'auto');
      expect(await File(result.path).readAsBytes(), orderedEquals(jpeg));
      expect((result.width, result.height), (32, 16));
      expect((result.originalWidth, result.originalHeight), (32, 16));
    },
  );

  test(
    'missing and corrupt edit references fail before sending a request',
    () async {
      final dir = await output();
      final invalid = File('${dir.path}/invalid.png');
      await invalid.writeAsString('This is not image data.');
      final client = ImageGenerationClient(
        credentials: () async => const Credentials(
          mode: AuthMode.apiKey,
          bearerToken: 'reference-test-token',
        ),
        apiEditsEndpoint: Uri.parse('http://127.0.0.1:1/must-not-connect'),
      );
      addTearDown(client.close);
      for (final path in ['${dir.path}/missing.png', invalid.path]) {
        await expectLater(
          client.generate(
            prompt: 'Edit the image',
            model: kDefaultImageModel,
            quality: 'low',
            textModel: 'text',
            outputDirectory: Directory('${dir.path}/generated'),
            inputImages: [
              ImageAttachment(
                path: path,
                width: 1,
                height: 1,
                originalWidth: 1,
                originalHeight: 1,
              ),
            ],
          ),
          throwsA(
            isA<ImageGenerationException>().having(
              (e) => e.message,
              'local validation',
              isNot(contains('SocketException')),
            ),
          ),
        );
      }
      expect(await Directory('${dir.path}/generated').exists(), isFalse);
    },
  );

  test(
    'invalid size, output format and excessive reference lists fail locally',
    () async {
      final dir = await output();
      var credentialReads = 0;
      final client = ImageGenerationClient(
        credentials: () async {
          credentialReads++;
          return null;
        },
      );
      addTearDown(client.close);
      Future<ImageAttachment> request({
        String size = '1024x1024',
        String format = 'jpeg',
        List<ImageAttachment> inputs = const [],
      }) => client.generate(
        prompt: 'A circle',
        model: kDefaultImageModel,
        quality: 'low',
        textModel: 'text',
        outputDirectory: dir,
        size: size,
        outputFormat: format,
        inputImages: inputs,
      );
      await expectLater(
        request(size: '1023x1024'),
        throwsA(isA<ImageGenerationException>()),
      );
      await expectLater(
        request(size: '32x2048'),
        throwsA(isA<ImageGenerationException>()),
      );
      await expectLater(
        request(format: 'svg'),
        throwsA(isA<ImageGenerationException>()),
      );
      await expectLater(
        request(
          inputs: List.filled(
            17,
            const ImageAttachment(
              path: 'none',
              width: 1,
              height: 1,
              originalWidth: 1,
              originalHeight: 1,
            ),
          ),
        ),
        throwsA(isA<ImageGenerationException>()),
      );
      expect(credentialReads, 0);
    },
  );

  test('provider rejection does not substitute models and redacts echoed credentials', () async {
    final dir = await output();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    const secret = 'private-fixture-token-not-a-jwt';
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = 400;
      request.response.write(
        jsonEncode({
          'error': {
            'code': 'model_not_found',
            'message': 'Unknown image model; authorization $secret',
          },
        }),
      );
      await request.response.close();
    });
    final client = ImageGenerationClient(
      credentials: () async =>
          const Credentials(mode: AuthMode.apiKey, bearerToken: secret),
      apiEndpoint: Uri.parse('http://127.0.0.1:${server.port}/images'),
    );
    addTearDown(client.close);
    await expectLater(
      client.generate(
        prompt: 'circle',
        model: kDefaultImageModel,
        quality: 'low',
        textModel: 'text-model',
        outputDirectory: dir,
      ),
      throwsA(
        isA<ImageGenerationException>()
            .having((e) => e.status, 'HTTP status', 400)
            .having(
              (e) => e.toString(),
              'redacted error',
              isNot(contains(secret)),
            )
            .having(
              (e) => e.message,
              'selected model hint',
              contains(kDefaultImageModel),
            ),
      ),
    );
    expect(requests, 1);
    expect(await dir.list().length, 0);
  });

  test('Codex error events redact non-JWT bearer before truncation', () async {
    const secret = 'fixture-private-bearer-that-must-be-redacted';
    await expectLater(
      ImageGenerationClient.collectCodexImage(
        events([
          {'type': 'error', 'message': '${'x' * 585}$secret failed'},
        ]),
        model: kDefaultImageModel,
        secrets: const [secret],
      ),
      throwsA(
        isA<ImageGenerationException>().having(
          (e) => e.message,
          'no truncated token prefix',
          isNot(contains('fixture-private')),
        ),
      ),
    );
  });

  test('closing an in-flight image request leaves no output file', () async {
    final dir = await output();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      received.complete();
    });
    final client = ImageGenerationClient(
      credentials: () async => const Credentials(
        mode: AuthMode.apiKey,
        bearerToken: 'test-cancel-token',
      ),
      apiEndpoint: Uri.parse('http://127.0.0.1:${server.port}/images'),
      timeout: const Duration(seconds: 3),
    );
    final generated = client.generate(
      prompt: 'circle',
      model: kDefaultImageModel,
      quality: 'low',
      textModel: 'text',
      outputDirectory: dir,
    );
    final rejected = expectLater(
      generated,
      throwsA(isA<ImageGenerationException>()),
    );
    await received.future;
    client.close();
    await rejected;
    expect(await dir.list().length, 0);
  });

  test(
    'catalog marks account-discovered image IDs and rejects text IDs',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'gpt-6-luna'},
              {'id': kDefaultImageModel},
              {'id': 'gpt-image-2.5-flare'},
            ],
          }),
        );
        await request.response.close();
      });
      final catalog = ImageModelCatalog(
        credentials: () async => const Credentials(
          mode: AuthMode.apiKey,
          bearerToken: 'catalog-test-token',
        ),
        apiEndpoint: Uri.parse('http://127.0.0.1:${server.port}/models'),
      );
      final result = await catalog.discover();
      expect(result.accountVerified, isTrue);
      expect(
        result.models,
        containsAll([kDefaultImageModel, 'gpt-image-2.5-flare']),
      );
      expect(result.models, isNot(contains('gpt-6-luna')));
      final fallback = await ImageModelCatalog(credentials: () async => null)
          .discover();
      expect(fallback.accountVerified, isFalse);
      expect(fallback.source, 'Documented models');
      expect(fallback.notice, isNotNull);
    },
  );

  test('image facts persist and legacy screenshots remain readable', () {
    final legacy = ImageAttachment.fromJson({
      'path': 'old.png',
      'w': 2,
      'h': 3,
      'ow': 20,
      'oh': 30,
    });
    expect(legacy.generated, isFalse);
    expect(legacy.byteSize, isNull);
    const image = ImageAttachment(
      path: 'new.png',
      width: 7,
      height: 5,
      originalWidth: 7,
      originalHeight: 5,
      byteSize: 1234,
      generationDurationMs: 13694,
      generationModel: kDefaultImageModel,
      generationQuality: 'low',
    );
    final message = Message(
      kind: MessageKind.assistant,
      image: image,
      meta: {'type': 'image_generation', 'status': 'completed'},
    );
    final restored = Message.fromJson(
      jsonDecode(jsonEncode(message.toJson())) as Map<String, Object?>,
    );
    expect(restored.image!.toJson(), image.toJson());
    expect(restored.meta['status'], 'completed');
    const media = MediaItem(
      kind: MediaKind.image,
      path: 'new.png',
      generationDurationMs: 13694,
      generationModel: kDefaultImageModel,
      generationQuality: 'low',
    );
    expect(MediaItem.fromJson(media.toJson()).toJson(), media.toJson());
  });
}

class MultipartPart {
  const MultipartPart(this.name, this.bytes, {this.filename, this.contentType});
  final String name;
  final Uint8List bytes;
  final String? filename;
  final String? contentType;
}

// Parse the captured wire MIME envelope independently of request construction.
List<MultipartPart> parseMultipart(Uint8List bytes, String boundary) {
  final parts = <MultipartPart>[];
  for (final segment in latin1.decode(bytes).split('--$boundary').skip(1)) {
    if (segment == '--\r\n') break;
    expect(segment, startsWith('\r\n'));
    expect(segment, endsWith('\r\n'));
    final split = segment.indexOf('\r\n\r\n');
    expect(split, greaterThan(0));
    final headers = segment.substring(2, split);
    final name = RegExp(r'name="([^"]+)"').firstMatch(headers)!.group(1)!;
    final filename = RegExp(r'filename="([^"]+)"')
        .firstMatch(headers)
        ?.group(1);
    final contentType = RegExp(r'Content-Type: ([^\r\n]+)')
        .firstMatch(headers)
        ?.group(1);
    final body = segment.substring(split + 4, segment.length - 2);
    parts.add(
      MultipartPart(
        name,
        Uint8List.fromList(latin1.encode(body)),
        filename: filename,
        contentType: contentType,
      ),
    );
  }
  return parts;
}
