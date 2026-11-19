import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/wav.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/audio_retention.dart';
import 'package:woi/core/voice/context_sync.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/fake_realtime.dart';

const _credentials = Credentials(mode: AuthMode.apiKey, bearerToken: 'synthetic-test-key');

SessionConfig _config({List<RetainedUserAudio> Function()? audio}) => SessionConfig(
  model: 'gpt-realtime-2.1',
  voice: 'marin',
  instructions: 'Be brief.',
  priorContext: 'Earlier facts.',
  recentContext: 'User: recent typed request.',
  retainedUserAudio: audio,
);

Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('reconnect not ready');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void _add(FakeSocket ws, String id, {bool audio = false, bool assistant = false}) => ws.addItem({
  'id': id,
  'type': 'message',
  'role': assistant ? 'assistant' : 'user',
  'content': [
    if (audio)
      {'type': assistant ? 'output_audio' : 'input_audio', 'transcript': '$id words'}
    else
      {'type': assistant ? 'output_text' : 'input_text', 'text': '$id words'},
  ],
});

List<Map> _createdAudio(FakeSocket ws) => [
  for (final event in ws.ofType('conversation.item.create'))
    if ((event['item'] as Map)['content'] case final List content
        when content.any((c) => (c as Map)['type'] == 'input_audio'))
      event['item'] as Map,
];

void main() {
  late FakeRealtimeServer server;
  late RealtimeWsBackend backend;
  late List<BackendEvent> events;
  late StreamSubscription<BackendEvent> subscription;

  void make({int keep = 1, Future<Uint8List> Function(String)? reader}) {
    server = FakeRealtimeServer();
    backend = RealtimeWsBackend(
      connector: server.connect,
      credentialsProvider: () async => _credentials,
      keepRecentTurns: keep,
      readRecordedAudio: reader,
      reconnectBaseDelay: const Duration(milliseconds: 1),
      connectTimeout: const Duration(seconds: 1),
      log: (_) {},
    );
    events = [];
    subscription = backend.events.listen(events.add);
  }

  tearDown(() async {
    await backend.close();
    await subscription.cancel();
  });

  test('provider deletion preserves the newest five user audio items across older text gaps', () async {
    make();
    await backend.connect(_config());
    for (var i = 0; i < 7; i++) {
      _add(server.last, 'u$i', audio: true);
      _add(server.last, 'a$i', audio: true, assistant: true);
      _add(server.last, 't$i');
    }
    _add(server.last, 'latest-text');
    await _pump();
    final result = await backend.applySummary('Facts: compacted text.');
    expect(result.method, ContextApplyMethod.deletedItems);
    expect(backend.serverItemIds.where((id) => RegExp(r'^u\d+$').hasMatch(id)), ['u2', 'u3', 'u4', 'u5', 'u6']);
    expect(
      backend.serverItemIds.where((id) => RegExp(r'^a\d+$').hasMatch(id)),
      isEmpty,
      reason: 'assistant TTS never occupies the five-user-audio window',
    );
    expect(backend.serverItemIds, contains('latest-text'));
    expect(server.last.items, backend.serverItemIds);
    expect(backend.serverItemIds.first, startsWith('woi_ctx_'));
  });

  test('provider audio cap overrides an unusually wide recent text window and rolls once', () async {
    make(keep: 20);
    await backend.connect(_config());
    for (var i = 0; i < 7; i++) {
      _add(server.last, 'u$i', audio: true);
    }
    await _pump();
    await backend.applySummary('First summary.');
    expect(backend.serverItemIds.where((id) => id.startsWith('u')), ['u2', 'u3', 'u4', 'u5', 'u6']);
    _add(server.last, 'u7', audio: true);
    await _pump();
    await backend.applySummary('Second summary.');
    expect(backend.serverItemIds.where((id) => id.startsWith('u')), ['u3', 'u4', 'u5', 'u6', 'u7']);
    expect(backend.serverItemIds.where((id) => id.startsWith('woi_ctx_')), hasLength(1));
    expect(server.last.items.toSet().length, server.last.items.length);
  });

  test(
    'connect and repeated reconnect replay exactly five original PCM clips, sequentially and without WAV headers',
    () async {
      final directory = await Directory.systemTemp.createTemp('woi-retained-audio-');
      addTearDown(() => directory.delete(recursive: true));
      final recordings = <RetainedUserAudio>[];
      final bytes = <String, Uint8List>{};
      for (var i = 0; i < 7; i++) {
        final pcm = Uint8List.fromList(List.generate(48, (n) => (n + i) % 128));
        final path = '${directory.path}/$i.wav';
        await writeWav(path, pcm);
        recordings.add(RetainedUserAudio(messageId: 'm$i', path: path, transcript: 'recording-$i'));
        bytes['recording-$i'] = pcm;
      }
      var concurrent = 0, peak = 0;
      make(
        reader: (path) async {
          concurrent++;
          if (concurrent > peak) peak = concurrent;
          try {
            return await File(path).readAsBytes();
          } finally {
            concurrent--;
          }
        },
      );
      await backend.connect(_config(audio: () => recordings));
      for (var connection = 1; connection <= 3; connection++) {
        if (connection > 1) {
          await server.last.drop();
          await _until(() => server.sockets.length == connection && backend.isReady);
        }
        await _pump();
        final sent = _createdAudio(server.last);
        expect(sent, hasLength(5));
        expect(sent.map((item) => ((item['content'] as List).single as Map)['transcript']), [
          'recording-2',
          'recording-3',
          'recording-4',
          'recording-5',
          'recording-6',
        ]);
        for (final item in sent) {
          final part = (item['content'] as List).single as Map;
          expect(base64Decode(part['audio'] as String), orderedEquals(bytes[part['transcript']]!));
        }
        expect(
          server.last.ofType('response.create'),
          isEmpty,
          reason: 'historical recordings never trigger a new answer',
        );
      }
      expect(peak, 1);
      for (final recording in recordings) {
        expect(decodePcm16Wav(await File(recording.path).readAsBytes()), orderedEquals(bytes[recording.transcript]!));
      }
      final replayId = _createdAudio(server.last).last['id'];
      server.last.push({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': replayId,
        'transcript': 'reference transcript',
      });
      await _pump();
      expect(
        events.whereType<UserTranscriptDone>(),
        isEmpty,
        reason: 'replay acknowledgements do not create duplicate chat messages',
      );
    },
  );

  test('missing and incompatible files retain real transcripts or an unknown-content marker', () async {
    make(
      reader: (path) async {
        if (path == 'missing') throw const FileSystemException('missing');
        return encodeWav(Uint8List(48), sampleRate: 16000);
      },
    );
    await backend.connect(
      _config(
        audio: () => const [
          RetainedUserAudio(messageId: 'one', path: 'missing', transcript: 'exact remembered words'),
          RetainedUserAudio(messageId: 'two', path: 'wrong-rate', transcript: ''),
        ],
      ),
    );
    await _pump();
    expect(backend.isReady, isTrue);
    expect(_createdAudio(server.last), isEmpty);
    final text = jsonEncode(server.last.ofType('conversation.item.create'));
    expect(text, contains('exact remembered words'));
    expect(text, contains('audio contents unknown'));
    expect(events.whereType<BackendError>().where((e) => e.code == 'context_audio_unavailable'), hasLength(2));
    expect(server.last.ofType('response.create'), isEmpty);
  });

  test('closing during a lazy file read prevents late replay into a superseded session', () async {
    final gate = Completer<Uint8List>();
    var reading = false;
    make(
      reader: (_) {
        reading = true;
        return gate.future;
      },
    );
    final connecting = backend.connect(
      _config(
        audio: () => const [RetainedUserAudio(messageId: 'one', path: 'held', transcript: 'words')],
      ),
    );
    final expected = expectLater(connecting, throwsA(isA<RealtimeException>()));
    await _until(() => reading);
    await backend.close();
    gate.complete(encodeWav(Uint8List(48)));
    await expected;
    expect(_createdAudio(server.last), isEmpty);
    expect(backend.isReady, isFalse);
  });
}
