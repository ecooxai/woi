import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/images/generated_image_context.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/media/media_context.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/voice/context_images.dart';

import 'fakes/fakes.dart';
import 'turn_pipeline_test.dart' show Harness;

class _ImageSink extends ScriptedBackend implements ContextImageSink {
  final slots = <String, DelegationImage>{};
  @override
  void setContextImage(String slot, DelegationImage? image) =>
      image == null ? slots.remove(slot) : slots[slot] = image;
}

Future<Message> _generated(
  Harness h, {
  String id = 'generated-reference',
}) async {
  final path = '${h.store.paths.imagesDir}/$id.png';
  await File(path)
      .writeAsBytes(img.encodePng(img.Image(width: 24, height: 16)));
  return Message(
    id: id,
    kind: MessageKind.assistant,
    image: ImageAttachment(
      path: path,
      width: 24,
      height: 16,
      originalWidth: 24,
      originalHeight: 16,
      generationModel: 'gpt-image-2.6-flare',
      generationDurationMs: 100,
    ),
    meta: {
      'type': 'image_generation',
      'status': 'completed',
      'prompt': 'A blue circle',
    },
  );
}

void main() {
  test(
    'camera queue pressure cannot evict artwork completed during connection',
    () async {
      final gate = Completer<void>();
      final backends = <ScriptedBackend>[];
      final h = await Harness.create(
        backend: () {
          final backend = ScriptedBackend();
          if (backends.isNotEmpty) backend.connectGate = gate;
          backends.add(backend);
          return backend;
        },
        options: const PipelineOptions(autoScreenshot: false),
      );
      addTearDown(h.dispose);
      final connecting = h.pipeline.connect();
      await waitFor(() => backends.length == 2 && backends.last.connectStarted);
      final message = await _generated(h);
      h.conv.add(message);
      await h.pipeline.generatedImageCompleted(h.conv, message);
      final camera = await File(message.image!.path).readAsBytes();
      for (var i = 0; i < 5; i++) {
        h.pipeline.attachContextImage(
          ContextImage(
            bytes: camera,
            width: 24,
            height: 16,
            note: 'Camera frame $i',
            kind: ContextImageKind.camera,
          ),
        );
      }
      gate.complete();
      await connecting;
      final artwork = backends.last.images.where(
        (image) =>
            image.$2?.contains('source_message_id: ${message.id}') ?? false,
      );
      expect(artwork, hasLength(1));
      expect(artwork.single.$1.take(2), [0xff, 0xd8]);
    },
  );

  test('completed image enters live context as a JPEG without changing its original file', () async {
    final h = await Harness.create(
      options: const PipelineOptions(autoScreenshot: false),
    );
    addTearDown(h.dispose);
    final message = await _generated(h);
    h.conv.add(message);
    await h.pipeline.generatedImageCompleted(h.conv, message);
    final bytes = h.scripted.images.single.$1;
    expect(bytes.take(2), [0xff, 0xd8]);
    expect(img.decodeJpg(bytes)!.width, 24);
    expect(
      h.scripted.images.single.$2,
      contains('source_message_id: ${message.id}'),
    );
    expect(h.scripted.images.single.$2, contains('not the current screen'));
    expect((await File(message.image!.path).readAsBytes()).take(4), [
      137,
      80,
      78,
      71,
    ]);
    expect(h.conv.messages.where((m) => m.id == message.id), hasLength(1));
    await h.pipeline.generatedImageCompleted(h.conv, message);
    expect(
      h.scripted.images,
      hasLength(1),
      reason: 'A callback and pending replay must not double-send.',
    );
  });

  test(
    'generated images restore on reconnect and stay out of other conversations',
    () async {
      final h = await Harness.create(
        options: const PipelineOptions(autoScreenshot: false),
      );
      addTearDown(h.dispose);
      final origin = h.conv;
      origin.add(await _generated(h));
      await h.pipeline.connect();
      expect(h.scripted.images, hasLength(1));
      final other = Conversation();
      await h.pipeline.switchConversation(other);
      expect(h.scripted.images, isEmpty);
      await h.pipeline.generatedImageCompleted(origin, origin.messages.single);
      expect(h.scripted.images, isEmpty);
      await h.pipeline.switchConversation(origin);
      expect(h.scripted.images, hasLength(1));
      expect(h.scripted.images.single.$1.take(2), [0xff, 0xd8]);
    },
  );

  test(
    'live delegation retains generated references as persistent artwork slots',
    () async {
      final h = await Harness.create(
        backend: _ImageSink.new,
        options: const PipelineOptions(autoScreenshot: false),
      );
      addTearDown(h.dispose);
      for (var i = 0; i < 4; i++) {
        final m = await _generated(h, id: 'artwork-$i');
        h.conv.add(m);
        await h.pipeline.generatedImageCompleted(h.conv, m);
      }
      final sink = h.scripted as _ImageSink;
      expect(sink.images, isEmpty);
      expect(sink.slots.keys, [
        'generated:artwork-1',
        'generated:artwork-2',
        'generated:artwork-3',
      ]);
      expect(sink.slots.values.every((i) => i.persistent), isTrue);
      expect(
        sink.slots.values.every((i) => i.png[0] == 0xff && i.png[1] == 0xd8),
        isTrue,
      );
    },
  );

  test('restore skips missing files and compacted images, keeping a bounded recent set', () async {
    final h = await Harness.create(
      options: const PipelineOptions(autoScreenshot: false),
    );
    addTearDown(h.dispose);
    for (var i = 0; i < 5; i++) {
      h.conv.add(await _generated(h, id: 'history-$i'));
    }
    h.conv.messages.last.compacted = true;
    await File(h.conv.messages[1].image!.path).delete();
    final restored = await recentGeneratedImageContext(h.conv);
    expect(restored.map((r) => r.message.id), ['history-2', 'history-3']);
  });
}
