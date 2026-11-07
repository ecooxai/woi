import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/images/image_generation.dart';
import 'package:woi/core/images/image_model_catalog.dart';
import 'package:woi/core/models/message.dart';
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
      expect(await File(result.path).readAsBytes(), orderedEquals(png));
      expect(result.width, 7);
      expect(result.height, 5);
      expect(result.byteSize, await File(result.path).length());
      expect(result.generationDurationMs, greaterThanOrEqualTo(0));
      expect(result.generationModel, kDefaultImageModel);
      expect(result.generationQuality, 'low');
      expect(await dir.list().length, 1);
      if (mode == AuthMode.apiKey) {
        expect(sent?['model'], kDefaultImageModel);
        expect(sent?['quality'], 'low');
        expect(sent?['n'], 1);
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
            'size': 'auto',
            'output_format': 'png',
            'action': 'generate',
          },
        ]);
      }
    });
  }

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
