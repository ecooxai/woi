import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/pre_connect_buffer.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/screen_capture.dart';

import 'fakes/fakes.dart';
import 'turn_pipeline_test.dart' show Harness;

/// 20 ms chunk whose samples all encode [i] (loud, so voiced).
Uint8List tagged(int i) {
  final bd = ByteData(kVoiceBytesPerSecond ~/ 50);
  for (var k = 0; k < bd.lengthInBytes ~/ 2; k++) {
    bd.setInt16(k * 2, (k.isEven ? 1 : -1) * (3000 + i), Endian.little);
  }
  return bd.buffer.asUint8List();
}

Uint8List cat(Iterable<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

void main() {
  group('PreConnectBuffer', () {
    test('the cap drops the oldest audio', () {
      final buf = PreConnectBuffer(capBytes: tagged(0).length * 5);
      for (var i = 0; i < 8; i++) {
        buf.add(tagged(i));
      }
      expect(buf.dropped, 3);
      expect(cat(buf.take()), cat([for (var i = 3; i < 8; i++) tagged(i)]));
    });

    test('a long leading digital silence is trimmed to ~300 ms before the signal', () {
      final buf = PreConnectBuffer();
      for (var t = 0; t < 2000; t += 20) {
        buf.add(Uint8List(kVoiceBytesPerSecond ~/ 50));
      }
      final speech = [for (var i = 0; i < 10; i++) tagged(i)];
      speech.forEach(buf.add);
      final out = cat(buf.take());
      expect(out.length, kVoiceBytesPerSecond * 3 ~/ 10 + cat(speech).length);
      expect(Uint8List.sublistView(out, out.length - cat(speech).length), cat(speech));
    });

    test('quiet audio (room noise, soft call-mode speech) is never trimmed', () {
      final buf = PreConnectBuffer();
      final quiet = [for (var t = 0; t < 3000; t += 20) pcm(20, amplitude: 20)];
      quiet.forEach(buf.add);
      final speech = [for (var i = 0; i < 10; i++) tagged(i)];
      speech.forEach(buf.add);
      expect(cat(buf.take()), cat([...quiet, ...speech]));
    });

    test('audio with no voiced chunk at all is kept whole', () {
      final buf = PreConnectBuffer();
      // ~-60 dBFS: below the voice gate, but signal.
      final soft = [for (var t = 0; t < 5000; t += 20) pcm(20, amplitude: 30)];
      soft.forEach(buf.add);
      expect(buf.hasVoice, isFalse);
      expect(cat(buf.take()), cat(soft));
    });

    test('digital silence after the first signal is kept', () {
      final buf = PreConnectBuffer();
      final parts = [
        tagged(1),
        for (var t = 0; t < 2000; t += 20) Uint8List(kVoiceBytesPerSecond ~/ 50),
        tagged(2),
      ];
      parts.forEach(buf.add);
      expect(cat(buf.take()), cat(parts));
    });

    test('the default cap holds a slow cold start (15 s held + 10 s handshake)', () {
      final buf = PreConnectBuffer();
      for (var t = 0; t < 25000; t += 20) {
        buf.add(tagged(t ~/ 20 % 100));
      }
      expect(buf.dropped, 0);
    });

    test('a short leading silence is kept; frames are bounded', () {
      final buf = PreConnectBuffer();
      for (var t = 0; t < 500; t += 20) {
        buf.add(pcm(20, amplitude: 20));
      }
      for (var i = 0; i < 100; i++) {
        buf.add(tagged(i));
      }
      final frames = buf.take();
      expect(cat(frames).length, kVoiceBytesPerSecond ~/ 2 + tagged(0).length * 100);
      expect(frames.every((f) => f.length <= kVoiceBytesPerSecond * 2 ~/ 10), isTrue);
      expect(buf.isEmpty, isTrue);
    });
  });

  group('pre-connect capture', () {
    late Harness h;
    Completer<void>? gate;

    setUp(() async {
      gate = null;
      h = await Harness.create(backend: () => ScriptedBackend()..connectGate = gate);
    });
    tearDown(() async {
      if (gate?.isCompleted == false) gate!.complete();
      await h.dispose();
    });

    test('audio before ready is sent after ready, in order, no loss or duplicate at the seam', () async {
      final mic = h.mic;
      gate = Completer<void>();
      unawaited(h.pipeline.connect());
      await Future<void>.delayed(Duration.zero);
      expect(h.pipeline.status, SessionStatus.connecting);
      expect(identical(h.fp.audio.mic, mic), isTrue, reason: 'the mic stays open while connecting');
      expect(h.pipeline.capturingWhileConnecting, isTrue);
      final backend = h.scripted;
      for (var i = 0; i < 25; i++) {
        mic.push(tagged(i));
      }
      expect(backend.sentAudio, isEmpty);
      gate!.complete();
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
      expect(h.pipeline.capturingWhileConnecting, isFalse);
      for (var i = 25; i < 35; i++) {
        mic.push(tagged(i));
      }
      expect(cat(backend.sentAudio), cat([for (var i = 0; i < 35; i++) tagged(i)]));
      expect(h.pipeline.preConnectFlushedBytes, tagged(0).length * 25);
    });

    test('an image attached while connecting goes before the buffered audio, then live audio', () async {
      final mic = h.mic;
      gate = Completer<void>();
      unawaited(h.pipeline.connect());
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 10; i++) {
        mic.push(tagged(i));
      }
      await h.pipeline.attachScreenshot(
        Screenshot(png: tinyPng(72, 144), width: 72, height: 144, originalWidth: 720, originalHeight: 1440),
        note: 'Assist screenshot.',
        activation: true,
      );
      final backend = h.scripted;
      expect(backend.sendLog, isEmpty, reason: 'nothing goes out before the session is ready');
      gate!.complete();
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
      for (var i = 10; i < 13; i++) {
        mic.push(tagged(i));
      }
      final firstImage = backend.sendLog.indexOf('image');
      expect(firstImage, 0, reason: 'the assist screenshot is the first thing sent: ${backend.sendLog}');
      expect(backend.images.where((i) => i.$2!.startsWith('Assist screenshot.')), hasLength(1));
      expect(backend.sendLog.lastIndexOf('image'), lessThan(backend.sendLog.indexOf('audio')));
      expect(
        cat(backend.sentAudio),
        cat([for (var i = 0; i < 13; i++) tagged(i)]),
        reason: 'buffered audio then live audio, in order',
      );
    });

    test('a reconnect keeps capturing and flushes on ready', () async {
      h.pipeline.reconnectBaseDelay = const Duration(milliseconds: 30);
      final mic = h.mic;
      gate = Completer<void>();
      h.scripted.emit(const BackendError('connection lost (1006)', code: 'connection_lost', fatal: true));
      expect(h.pipeline.status, SessionStatus.connecting);
      for (var i = 0; i < 5; i++) {
        mic.push(tagged(i)); // during the backoff
      }
      await waitFor(() => h.pipeline.reconnecting && h.lastBackend is ScriptedBackend && h.scripted.config == null);
      for (var i = 5; i < 10; i++) {
        mic.push(tagged(i)); // during the handshake
      }
      final next = h.scripted;
      gate!.complete();
      await waitFor(() => h.pipeline.status == SessionStatus.connected && !h.pipeline.reconnecting);
      expect(identical(h.fp.audio.mic, mic), isTrue);
      expect(cat(next.sentAudio), cat([for (var i = 0; i < 10; i++) tagged(i)]));
    });

    test('a slow mic open does not hold up connect; its audio still flushes on ready', () async {
      await h.pipeline.suspend();
      final micGate = h.fp.audio.openMicGate = Completer<void>();
      gate = Completer<void>();
      unawaited(h.pipeline.resume());
      await waitFor(() => h.lastBackend is ScriptedBackend && h.scripted.connectStarted);
      expect(h.pipeline.status, SessionStatus.connecting);
      // connect went ahead while the mic is still opening.
      micGate.complete();
      await waitFor(() => h.pipeline.capturingWhileConnecting);
      final mic = h.fp.audio.mic!;
      for (var i = 0; i < 10; i++) {
        mic.push(tagged(i));
      }
      expect(h.scripted.sentAudio, isEmpty);
      gate!.complete();
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
      mic.push(tagged(10));
      expect(cat(h.scripted.sentAudio), cat([for (var i = 0; i < 11; i++) tagged(i)]));
      expect(h.pipeline.preConnectFlushedBytes, tagged(0).length * 10);
      expect(h.fp.audio.micOpens, hasLength(2), reason: 'one open, not a second one after ready');
    });

    test('a mic open that never completes does not stop connect', () async {
      await h.pipeline.suspend();
      final micGate = h.fp.audio.openMicGate = Completer<void>();
      unawaited(h.pipeline.resume());
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
      // The mic shows up late: it streams live.
      micGate.complete();
      await waitFor(() => h.fp.audio.mic != null && !h.fp.audio.mic!.closed && h.pipeline.micLevel != null);
      final mic = h.fp.audio.mic!;
      await Future<void>.delayed(Duration.zero);
      mic.push(tagged(1));
      expect(cat(h.scripted.sentAudio), tagged(1));
    });

    test('a failed mic open does not stop connect', () async {
      await h.pipeline.suspend();
      h.fp.audio.openMicError = StateError('no mic');
      unawaited(h.pipeline.resume());
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
    });

    test('a mic opened while connecting is closed by a disconnect before it arrives', () async {
      await h.pipeline.suspend();
      final micGate = h.fp.audio.openMicGate = Completer<void>();
      gate = Completer<void>();
      unawaited(h.pipeline.resume());
      await waitFor(() => h.lastBackend is ScriptedBackend && h.scripted.connectStarted);
      await h.pipeline.suspend();
      micGate.complete();
      await waitFor(() => h.fp.audio.mic != null);
      await waitFor(() => h.fp.audio.mic!.closed);
      expect(h.pipeline.capturingWhileConnecting, isFalse);
    });

    test('speech in the pre-roll grabs the screen then and attaches it to the turn', () async {
      final mic = h.mic;
      gate = Completer<void>();
      unawaited(h.pipeline.connect());
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 10; i++) {
        mic.push(tagged(i));
      }
      await Future<void>.delayed(Duration.zero);
      expect(h.fp.screen.captureTimes, hasLength(1));
      gate!.complete();
      await waitFor(() => h.pipeline.status == SessionStatus.connected);
      h.scripted.emit(const SpeechStarted(itemId: 'u1'));
      await waitFor(() => h.scripted.images.isNotEmpty);
      expect(h.fp.screen.captureTimes, hasLength(1));
      h.scripted.emit(const SpeechStopped(itemId: 'u1'));
      h.scripted.emit(const UserTranscriptDone('hello', itemId: 'u1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final user = h.conv.messages.where((m) => m.text == 'hello').single;
      expect(user.image, isNotNull);
    });
  });
}
