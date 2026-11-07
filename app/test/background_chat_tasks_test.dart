import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:woi/core/background/chat_tasks.dart';
import 'package:woi/core/images/image_generation.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/search/web_search.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/platform/app_paths.dart';

class _Images extends ImageGenerationClient {
  _Images() : super(credentials: () async => null);
  final result = Completer<ImageAttachment>();
  int calls = 0;
  bool closed = false;
  String? requestedModel;
  String? requestedQuality;
  String? requestedSize;
  String? requestedFormat;
  List<ImageAttachment> requestedInputs = [];

  @override
  Future<ImageAttachment> generate({
    required String prompt,
    required String model,
    required String quality,
    required String textModel,
    required Directory outputDirectory,
    String size = '1024x1024',
    String outputFormat = 'jpeg',
    List<ImageAttachment> inputImages = const [],
  }) {
    calls++;
    requestedModel = model;
    requestedQuality = quality;
    requestedSize = size;
    requestedFormat = outputFormat;
    requestedInputs = inputImages;
    return result.future;
  }

  @override
  void close() {
    closed = true;
    if (calls > 0 && !result.isCompleted) {
      result.completeError(StateError('Image request cancelled.'));
    }
    super.close();
  }
}

class _Search extends WebSearchService {
  _Search()
    : super(
        client: ResponsesClient(credentials: () async => null),
        model: () => 'text-model',
      );
  final result = Completer<Map<String, Object?>>();
  @override
  Future<Map<String, Object?>> search(String query) => result.future;
}

/// Hold one real serialized write before it touches disk. This makes the
/// deletion race deterministic without depending on the filesystem's speed.
class _History extends HistoryStore {
  _History(super.paths);
  Completer<void>? gate;
  Completer<void>? entered;
  bool failNextWrite = false;

  void holdNextWrite() {
    gate = Completer<void>();
    entered = Completer<void>();
  }

  @override
  Future<void> writeSnapshot(String id, String json) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const FileSystemException('Test disk full');
    }
    final wait = gate;
    if (wait != null) {
      gate = null;
      entered!.complete();
      await wait.future;
    }
    await super.writeSnapshot(id, json);
  }
}

Future<void> _until(bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('Background operation did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late Directory temp;
  late _History history;
  late _Images images;
  late _Search search;
  late BackgroundChatTasks tasks;
  late Conversation current;
  late List<Conversation> changes;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('woi-background-test-');
    history = _History(AppPaths(dataDir: temp.path, homeDir: temp.path));
    await history.init();
    images = _Images();
    search = _Search();
    current = Conversation();
    changes = [];
    tasks = BackgroundChatTasks(
      images: images,
      search: search,
      history: history,
      currentConversation: () => current,
      onChanged: changes.add,
    );
  });

  tearDown(() async {
    await tasks.shutdown();
    search.client.close();
    await temp.delete(recursive: true);
  });

  Future<Map<String, Object?>> generate() => tasks.generateImage(
    prompt: 'A green leaf',
    model: 'gpt-image-flare-2.1',
    quality: 'low',
    textModel: 'text-model',
  );

  Future<ImageAttachment> image() async {
    final file = File(p.join(history.paths.imagesDir, 'generated.png'));
    await file.writeAsBytes([137, 80, 78, 71], flush: true);
    return ImageAttachment(
      path: file.path,
      width: 1024,
      height: 1024,
      originalWidth: 1024,
      originalHeight: 1024,
      byteSize: 4,
      generationDurationMs: 1234,
      generationModel: 'gpt-image-flare-2.1',
      generationQuality: 'low',
    );
  }

  test(
    'queued image completes in its originating chat after switching',
    () async {
      final origin = current;
      final queued = await generate();
      expect(queued['status'], 'queued');
      expect(origin.messages.single.meta['status'], 'pending');
      expect(images.result.isCompleted, isFalse);
      expect(images.requestedModel, 'gpt-image-flare-2.1');
      expect(images.requestedQuality, 'low');
      expect(
        (await history.load(origin.id))!.messages.single.meta['status'],
        'pending',
      );

      current = Conversation();
      current.add(Message(kind: MessageKind.user, text: 'Another chat'));
      expect(tasks.retainedConversation(origin.id), same(origin));
      final attachment = await image();
      images.result.complete(attachment);
      await _until(() => tasks.retainedConversation(origin.id) == null);

      expect(current.messages.single.text, 'Another chat');
      expect(origin.messages.single.image, same(attachment));
      expect(origin.messages.single.meta['status'], 'completed');
      final stored = (await history.load(origin.id))!.messages.single;
      expect(stored.image!.byteSize, 4);
      expect(stored.image!.generationDurationMs, 1234);
      expect(stored.meta['duration_ms'], 1234);
      expect(changes.every((c) => identical(c, origin)), isTrue);
    },
  );

  test(
    'reopened retained chat keeps new messages when an image completes',
    () async {
      final origin = current;
      await generate();
      current = Conversation();
      current = tasks.retainedConversation(origin.id)!;
      current.add(
        Message(kind: MessageKind.user, text: 'Keep this later message'),
      );
      images.result.complete(await image());
      await _until(() => tasks.retainedConversation(origin.id) == null);
      final stored = (await history.load(origin.id))!.messages;
      expect(stored, hasLength(2));
      expect(stored.first.text, 'Keep this later message');
      expect(stored.last.image, isNotNull);
      expect(stored.last.meta['imageKind'], 'generated');
    },
  );

  test(
    'completed image moves after later turns and preserves its reference ID',
    () async {
      final queued = await generate();
      final pending = current.messages.single;
      current.add(
        Message(kind: MessageKind.user, text: 'Meanwhile, another request'),
      );
      current.add(Message(kind: MessageKind.assistant, text: 'Another reply'));
      images.result.complete(await image());
      await _until(() => tasks.retainedConversation(current.id) == null);
      expect(
        current.messages
            .map((m) => m.id)
            .where((id) => id == queued['message_id']),
        hasLength(1),
      );
      final completed = current.messages.last;
      expect(completed.id, pending.id);
      expect(completed.createdAt.isBefore(pending.createdAt), isFalse);
      expect(
        completed.meta['requested_at'],
        pending.createdAt.toIso8601String(),
      );
      expect(completed.image, isNotNull);
      expect(images.requestedSize, '1024x1024');
      expect(images.requestedFormat, 'jpeg');
      expect(images.requestedInputs, isEmpty);
    },
  );

  test(
    'edit uses saved artwork instead of an automatic screen capture',
    () async {
      final artwork = await image();
      final source = Message(kind: MessageKind.assistant, image: artwork);
      current.add(source);
      current.add(
        Message(
          kind: MessageKind.user,
          text: 'Make the leaf blue',
          image: ImageAttachment(
            path: 'automatic-screen.jpg',
            width: 800,
            height: 600,
            originalWidth: 800,
            originalHeight: 600,
          ),
        ),
      );
      final queued = await tasks.generateImage(
        prompt: 'Make the leaf blue',
        model: 'gpt-image-2.6-flare',
        quality: 'low',
        textModel: 'text-model',
        action: 'edit',
      );
      expect(queued['action'], 'edit');
      expect(queued['source_message_id'], source.id);
      expect(images.requestedInputs, [same(artwork)]);
      images.result.complete(await image());
      await _until(() => tasks.retainedConversation(current.id) == null);
      expect(current.messages.last.meta['source_message_id'], source.id);
    },
  );

  test(
    'explicit source selection stays inside the originating conversation',
    () async {
      current.add(
        Message(
          id: 'first-artwork',
          kind: MessageKind.assistant,
          image: await image(),
        ),
      );
      final source = current.messages.single.image!;
      current.add(
        Message(
          id: 'second-artwork',
          kind: MessageKind.assistant,
          image: await image(),
        ),
      );
      await tasks.generateImage(
        prompt: 'Edit the first image',
        model: 'gpt-image-2.6-flare',
        quality: 'low',
        textModel: 'text-model',
        action: 'edit',
        sourceMessageId: 'first-artwork',
      );
      expect(images.requestedInputs.single, same(source));
      images.result.complete(await image());
      await _until(() => tasks.retainedConversation(current.id) == null);
    },
  );

  test(
    'edit without a matching image fails before any provider request',
    () async {
      await expectLater(
        tasks.generateImage(
          prompt: 'Edit the image',
          model: 'gpt-image-2.6-flare',
          quality: 'low',
          textModel: 'text-model',
          action: 'edit',
          sourceMessageId: 'another-chat-image',
        ),
        throwsArgumentError,
      );
      expect(images.calls, 0);
      expect(current.messages, isEmpty);
    },
  );

  test('completed result is delivered to context once without creating a duplicate message', () async {
    final delivered = <Message>[];
    var contextReady = false;
    final origin = current;
    tasks = BackgroundChatTasks(
      images: images,
      search: search,
      history: history,
      currentConversation: () => current,
      onChanged: (conversation) {
        if (conversation.messages.any((m) => m.meta['status'] == 'completed')) {
          expect(
            contextReady,
            isTrue,
            reason: 'The visible completion must already be queued in model context.',
          );
        }
        changes.add(conversation);
      },
      onImageCompleted: (conversation, message) async {
        expect(conversation, same(origin));
        expect(message.meta['status'], 'completed');
        expect(message.image, isNotNull);
        contextReady = true;
        delivered.add(message);
      },
    );
    await generate();
    images.result.complete(await image());
    await _until(() => tasks.retainedConversation(origin.id) == null);
    expect(delivered, [same(origin.messages.single)]);
  });

  test(
    'deleted chat drops a late image and removes its generated file',
    () async {
      final origin = current;
      await generate();
      tasks.discardConversation(origin.id);
      await history.delete(origin.id);
      current = Conversation();
      final attachment = await image();
      images.result.complete(attachment);
      await _until(() => !File(attachment.path).existsSync());
      expect(await history.load(origin.id), isNull);
      expect(current.messages, isEmpty);
      await history.save(origin);
      history.saveSoon(origin, delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await history.load(origin.id), isNull);
    },
  );

  test(
    'deletion during initial save cancels generation before provider call',
    () async {
      final origin = current;
      history.holdNextWrite();
      final gate = history.gate!;
      final entered = history.entered!.future;
      final pending = generate();
      await entered;
      tasks.discardConversation(origin.id);
      final removing = history.delete(origin.id);
      gate.complete();
      expect((await pending)['status'], 'cancelled');
      await removing;
      expect(images.calls, 0);
      expect(await history.load(origin.id), isNull);
    },
  );

  test(
    'delete during a queued completed-image save leaves no file or chat',
    () async {
      final origin = current;
      await generate();
      history.holdNextWrite();
      final gate = history.gate!;
      final entered = history.entered!.future;
      final priorWrite = history.save(origin);
      await entered;
      final attachment = await image();
      images.result.complete(attachment);
      await _until(() => origin.messages.single.image != null);
      tasks.discardConversation(origin.id);
      final deleting = history.delete(origin.id);
      gate.complete();
      await priorWrite;
      await deleting;
      await _until(() => !File(attachment.path).existsSync());
      expect(await history.load(origin.id), isNull);
    },
  );

  test('generation failure is visible and persisted', () async {
    final origin = current;
    await generate();
    images.result.completeError(
      StateError('Provider rejected the selected model.'),
    );
    await _until(() => tasks.retainedConversation(origin.id) == null);
    final stored = (await history.load(origin.id))!.messages.single;
    expect(stored.meta['status'], 'failed');
    expect(stored.text, contains('Provider rejected the selected model.'));
    expect(stored.image, isNull);
  });

  test(
    'successful image with history failure remains completed and viewable',
    () async {
      final origin = current;
      await generate();
      history.failNextWrite = true;
      final attachment = await image();
      images.result.complete(attachment);
      await _until(() => tasks.retainedConversation(origin.id) == null);
      final m = origin.messages.single;
      expect(m.meta['status'], 'completed');
      expect(m.image, same(attachment));
      expect(m.text, contains('could not be saved'));
      expect(m.text, isNot(contains('generation failed')));
      expect(m.meta['save_error'], contains('disk full'));
      tasks.discardConversation(origin.id);
      await history.delete(origin.id);
      expect(await File(attachment.path).exists(), isFalse);
      expect(await history.load(origin.id), isNull);
    },
  );

  test(
    'shutdown interrupts pending jobs and the next launch can recover them',
    () async {
      final origin = current;
      await generate();
      final savedPending = (await history.load(origin.id))!;
      expect(BackgroundChatTasks.recoverInterrupted(savedPending), isTrue);
      expect(BackgroundChatTasks.recoverInterrupted(savedPending), isFalse);
      expect(savedPending.messages.single.meta['status'], 'interrupted');
      expect(savedPending.messages.single.text, contains('Ask to generate'));
      await tasks.shutdown();
      expect(images.closed, isTrue);
      expect(
        (await history.load(origin.id))!.messages.single.meta['status'],
        'interrupted',
      );
    },
  );

  test(
    'shutdown preserves an image that completed while its save is pending',
    () async {
      final origin = current;
      await generate();
      history.holdNextWrite();
      final gate = history.gate!;
      final entered = history.entered!.future;
      images.result.complete(await image());
      await entered;
      final stopping = tasks.shutdown();
      expect(origin.messages.single.meta['status'], 'completed');
      gate.complete();
      await stopping;
      final stored = (await history.load(origin.id))!.messages.single;
      expect(stored.meta['status'], 'completed');
      expect(stored.image, isNotNull);
      expect(await File(stored.image!.path).exists(), isTrue);
    },
  );

  test(
    'web search persists readable sources in the originating chat',
    () async {
      final origin = current;
      final result = tasks.searchWeb('Dart Future documentation');
      current = Conversation();
      search.result.complete({
        'ok': true,
        'answer': 'A Future represents an asynchronous result.\uE200cite\uE202turn0search0\uE201',
        'sources': [
          {
            'url': 'https://api.dart.dev/dart-async/Future-class.html',
            'title': 'Future class',
          },
        ],
        'model': 'text-model',
        'duration_ms': 75,
      });
      await result;
      expect(current.messages, isEmpty);
      final message = (await history.load(origin.id))!.messages.single;
      expect(message.text, 'A Future represents an asynchronous result.');
      expect(message.meta['type'], 'web_search');
      expect(
        (message.meta['sources'] as List).single['url'],
        startsWith('https://api.dart.dev/'),
      );
    },
  );

  test(
    'history deletion waits for in-flight writes and cancels autosaves',
    () async {
      final origin = current;
      final attachment = await image();
      origin.add(Message(kind: MessageKind.assistant, image: attachment));
      await history.save(origin);
      history.holdNextWrite();
      final gate = history.gate!;
      final entered = history.entered!.future;
      origin.add(Message(kind: MessageKind.user, text: 'Queued update'));
      final saving = history.save(origin);
      await entered;
      history.saveSoon(origin, delay: Duration.zero);
      var deleted = false;
      final removing = history.delete(origin.id).then((_) => deleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        deleted,
        isFalse,
        reason: 'Removal must wait for the active writer.',
      );
      await history.save(origin);
      gate.complete();
      await saving;
      await removing;
      expect(await history.load(origin.id), isNull);
      expect(await File(attachment.path).exists(), isFalse);
      expect(
        await File(
          p.join(history.paths.conversationsDir, '${origin.id}.json.tmp'),
        ).exists(),
        isFalse,
      );
      history.saveSoon(origin, delay: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await history.load(origin.id), isNull);
    },
  );
}
