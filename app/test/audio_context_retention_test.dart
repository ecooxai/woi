import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/audio_retention.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';

class _Summary implements Compressor {
  final batches = <List<Message>>[];
  final previous = <String?>[];
  Completer<void>? gate;
  Object? error;
  void Function()? afterAwait;
  String result = 'Facts: saved text.';

  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    batches.add([for (final m in messages) Message.fromJson(m.toJson())]);
    previous.add(previousSummary);
    await gate?.future;
    afterAwait?.call();
    if (error case final e?) throw e;
    return CompressionResult(summary: result, tokensAfter: result.length ~/ 4);
  }
}

Message _audio(int i, {MessageKind kind = MessageKind.user, String? text, int durationMs = 4000}) => Message(
  id: '${kind == MessageKind.user ? 'u' : 'a'}$i',
  kind: kind,
  text: text ?? 'recording $i: ${'words ' * 120}',
  audio: AudioClip(path: '/archive/${kind.name}-$i.wav', durationMs: durationMs),
);

Message _text(int i) => Message(id: 't$i', kind: MessageKind.user, text: 'typed $i: ${'text ' * 160}');

List<String> _activeAudio(Conversation c) => [
  for (final m in c.messages)
    if (!m.compacted && m.kind == MessageKind.user && m.audio != null) m.id,
];

void main() {
  late _Summary summary;
  late ContextManager context;
  late Conversation conversation;

  setUp(() {
    summary = _Summary();
    context = ContextManager(compressor: summary, threshold: 1000000, minInterval: const Duration(hours: 1));
    conversation = Conversation();
    context.attach(conversation);
  });
  tearDown(() => context.dispose());

  test('five USER recordings survive older text gaps with IDs, original media and history intact', () async {
    final originals = <Message>[];
    for (var i = 0; i < 8; i++) {
      final message = _audio(i);
      if (i == 3) {
        message.image = const ImageAttachment(
          path: '/archive/photo.png',
          width: 2,
          height: 2,
          originalWidth: 2,
          originalHeight: 2,
        );
      }
      originals.add(message);
      conversation
        ..add(message)
        ..add(_audio(i, kind: MessageKind.assistant))
        ..add(_text(i));
    }
    for (var i = 8; i < 12; i++) {
      conversation.add(_text(i));
    }
    final clips = originals.map((m) => m.audio).toList();
    final image = originals[3].image;
    await context.maybeCompress(force: true);

    expect(_activeAudio(conversation), ['u3', 'u4', 'u5', 'u6', 'u7']);
    expect(retainedUserAudioMessages(conversation.messages), originals.skip(3).toList());
    for (var i = 0; i < originals.length; i++) {
      expect(identical(originals[i].audio, clips[i]), isTrue);
      expect(conversation.messages.contains(originals[i]), isTrue);
    }
    expect(identical(originals[3].image, image), isTrue);
    expect(summary.batches.single.where((m) => m.kind == MessageKind.user && m.audio != null).map((m) => m.id), [
      'u0',
      'u1',
      'u2',
    ]);
    expect(conversation.messages.where((m) => m.kind == MessageKind.assistant && !m.compacted), isEmpty);
    final persisted = Conversation.fromJson(conversation.toJson());
    expect(persisted.messages.where((m) => m.kind == MessageKind.user && m.audio != null), hasLength(8));
    expect(_activeAudio(persisted), ['u3', 'u4', 'u5', 'u6', 'u7']);
  });

  test('audio cap still applies when all seven recordings fit the recent text window', () async {
    context.keepRecentTurns = 20;
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    await context.maybeCompress(force: true);
    expect(_activeAudio(conversation), ['u2', 'u3', 'u4', 'u5', 'u6']);
    expect(summary.batches.single.map((m) => m.id), ['u0', 'u1']);
    expect(context.maybeCompress(force: true), isNull);
  });

  test('repeated compaction rolls the audio window once and merges only the previous summary', () async {
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    await context.maybeCompress(force: true);
    final firstIds = summary.batches.single.map((m) => m.id).toSet();
    conversation.add(_audio(7));
    for (var i = 0; i < 4; i++) {
      conversation.add(_text(i));
    }
    await context.maybeCompress(force: true);
    expect(_activeAudio(conversation), ['u3', 'u4', 'u5', 'u6', 'u7']);
    expect(summary.previous, [null, 'Facts: saved text.']);
    expect(summary.batches.last.map((m) => m.id), contains('u2'));
    expect(summary.batches.last.any((m) => firstIds.contains(m.id)), isFalse);
    expect(context.maybeCompress(force: true), isNull);
  });

  test('text replay includes all five recordings across gaps even beyond its ordinary text budget', () async {
    for (var i = 0; i < 6; i++) {
      conversation
        ..add(_audio(i, text: i == 2 ? '' : 'recording-$i transcript'))
        ..add(_text(i));
    }
    for (var i = 6; i < 10; i++) {
      conversation.add(_text(i));
    }
    await context.maybeCompress(force: true);
    final recent = context.recentTurns(maxChars: 10);
    expect(recent, contains('recording-1 transcript'));
    expect(recent, contains('transcript unavailable'));
    expect(recent, contains('recording-5 transcript'));
    expect(recent, isNot(contains('recording-0 transcript')));
    expect('User:'.allMatches(recent), hasLength(5));
    expect(context.recentTurns(maxChars: 10, includeRetainedAudio: false), isEmpty);
  });

  test('new audio during the summary await restarts before committing a stale window', () async {
    conversation.summary = 'Earlier facts.';
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    summary.gate = Completer<void>();
    final pending = context.maybeCompress(force: true)!;
    expect(summary.batches, hasLength(1));
    conversation.add(_audio(7));
    summary.gate!.complete();
    await pending;
    expect(summary.batches, hasLength(2));
    expect(summary.previous, ['Earlier facts.', 'Earlier facts.']);
    expect(summary.batches.last.map((m) => m.id), ['u0', 'u1', 'u2']);
    expect(_activeAudio(conversation), ['u3', 'u4', 'u5', 'u6', 'u7']);
    expect(conversation.summary, 'Facts: saved text.');
  });

  test('a late saved recording cannot be archived by a stale text summary', () async {
    final lateAudio = _text(0);
    conversation.add(lateAudio);
    for (var i = 0; i < 4; i++) {
      conversation.add(_audio(i));
    }
    conversation.add(_text(1));
    summary.gate = Completer<void>();
    final pending = context.maybeCompress(force: true)!;
    lateAudio.audio = const AudioClip(path: '/archive/late.wav', durationMs: 4000);
    summary.gate!.complete();
    await pending;
    expect(lateAudio.compacted, isFalse);
    expect(conversation.summary, isNull, reason: 'the only previously compactable text is now retained audio');
    expect(_activeAudio(conversation), ['t0', 'u0', 'u1', 'u2', 'u3']);
  });

  test('failure is atomic and never edits original media or the previous summary', () async {
    conversation.summary = 'Earlier facts.';
    for (var i = 0; i < 8; i++) {
      conversation.add(_audio(i));
    }
    final before = jsonEncode(conversation.toJson());
    summary.error = StateError('offline');
    await context.maybeCompress(force: true);
    expect(jsonEncode(conversation.toJson()), before);
    expect(context.failures, 1);
    expect(context.compressing, isFalse);
  });

  test('a stale failure after a conversation switch does not contaminate the new session', () async {
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    summary.gate = Completer<void>();
    summary.error = StateError('old request failed');
    final pending = context.maybeCompress(force: true)!;
    final other = Conversation()..add(_text(90));
    context.attach(other);
    summary.gate!.complete();
    await pending;
    expect(context.failures, 0);
    expect(context.lastError, isNull);
    expect(other.summary, isNull);
    expect(conversation.messages.any((m) => m.compacted), isFalse);
  });

  test('retained audio alone over budget reports the reason without retries or dropping it', () async {
    context
      ..threshold = 50
      ..keepRecentTurns = 0;
    for (var i = 0; i < 5; i++) {
      conversation.add(_audio(i, text: '', durationMs: 600000));
    }
    for (var i = 0; i < 20; i++) {
      context.onConversationChanged();
    }
    expect(context.maybeCompress(force: true), isNull);
    expect(summary.batches, isEmpty);
    expect(context.status, contains('5 recent user recordings'));
    expect(context.status, contains('no older text'));
    expect(context.parts().audio, 30000);
    expect(_activeAudio(conversation), ['u0', 'u1', 'u2', 'u3', 'u4']);
    expect(context.nextRetryAt, isNull);
  });

  test('an expanding summary is rejected without changing the retained audio window', () async {
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    final before = jsonEncode(conversation.toJson());
    summary.result = 'S' * 100000;
    await context.maybeCompress(force: true);
    expect(jsonEncode(conversation.toJson()), before);
    expect(context.lastError, isA<StateError>());
  });

  test('continuously changing audio bounds retries and leaves the original summary untouched', () async {
    conversation.summary = 'Original summary.';
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    var next = 7;
    summary.afterAwait = () => conversation.add(_audio(next++));
    await context.maybeCompress(force: true);
    expect(summary.batches, hasLength(3));
    expect(summary.previous, everyElement('Original summary.'));
    expect(conversation.summary, 'Original summary.');
    expect(conversation.messages.any((m) => m.compacted), isFalse);
    expect(context.status, contains('kept changing'));
    expect(context.failures, 1);
  });

  test('disposing while a summary is in flight cancels application safely', () async {
    for (var i = 0; i < 7; i++) {
      conversation.add(_audio(i));
    }
    final owned = ContextManager(compressor: summary)..attach(conversation);
    summary.gate = Completer<void>();
    final pending = owned.maybeCompress(force: true)!;
    owned.dispose();
    summary.gate!.complete();
    await pending;
    expect(conversation.summary, isNull);
    expect(conversation.messages.any((m) => m.compacted), isFalse);
  });
}
