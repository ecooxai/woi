import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/media/held_audio_recorder.dart';
import 'package:woi/platform/audio_io.dart';

class _Mic implements MicStream {
  final controller = StreamController<Uint8List>.broadcast(sync: true);
  @override
  final level = ValueNotifier<double>(0);
  bool closed = false;
  @override
  Stream<Uint8List> get chunks => controller.stream;
  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

class _TailMic extends _Mic {
  _TailMic(this.tail);
  final Uint8List tail;

  @override
  Future<void> close() async {
    // Native mixing can deliver a final partial frame while closing.
    await Future<void>.delayed(Duration.zero);
    controller.add(tail);
    await super.close();
  }
}

class _UnreleasedMic extends _Mic {
  @override
  Future<void> close() async => throw StateError('native capture stop was not acknowledged');
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('audio stays local until release, closes capture, then submits and restores listening', () async {
    final mic = _Mic();
    final events = <String>[];
    Uint8List? sent;
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async => events.add('suspend'),
      resumeListening: () async => events.add('resume'),
      submit: (pcm, current) async {
        expect(current(), isTrue);
        expect(mic.closed, isTrue);
        events.add('submit');
        sent = pcm;
      },
      report: (message) => fail(message),
    );
    recorder.start();
    await _tick();
    final bytes = Uint8List(9600)..fillRange(0, 9600, 17);
    mic.controller.add(bytes);
    bytes[0] = 90; // native buffers may be reused after delivery
    expect(sent, isNull);
    expect(recorder.recording, isTrue);
    await recorder.release();
    expect(sent!.length, 9600);
    expect(sent!.first, 17);
    expect(events, ['suspend', 'submit', 'resume']);
    expect(recorder.busy, isFalse);
    await recorder.release();
    expect(events.where((e) => e == 'submit').length, 1);
    recorder.dispose();
  });

  test('release includes the final native mixer frame flushed during close', () async {
    final mic = _TailMic(Uint8List(960)..fillRange(0, 960, 29));
    Uint8List? sent;
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (pcm, _) async {
        expect(mic.closed, isTrue);
        sent = pcm;
      },
      report: (message) => fail(message),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(4800)..fillRange(0, 4800, 17));
    await recorder.release();
    expect(sent, hasLength(5760));
    expect(sent!.sublist(0, 4800), everyElement(17));
    expect(sent!.sublist(4800), everyElement(29));
    expect(mic.controller.hasListener, isFalse);
    recorder.dispose();
  });

  test('cancel discards the capture including a native mixer frame flushed during close', () async {
    final mic = _TailMic(Uint8List(960));
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (_, _) async => fail('cancelled recording tail sent'),
      report: (message) => fail(message),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(4800));
    await recorder.cancel();
    expect(mic.closed, isTrue);
    expect(mic.controller.hasListener, isFalse);
    expect(recorder.busy, isFalse);
    recorder.dispose();
  });

  test('duration cap keeps a bounded clip local until release', () async {
    final mic = _Mic();
    final reports = <String>[];
    Uint8List? sent;
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (pcm, _) async => sent = pcm,
      report: reports.add,
      maxDuration: const Duration(milliseconds: 100),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(9600)..fillRange(0, 9600, 17));
    mic.controller.add(Uint8List(9600)..fillRange(0, 9600, 29));
    await _tick();
    expect(sent, isNull);
    expect(recorder.recording, isTrue);
    expect(recorder.limitReached, isTrue);
    expect(reports, ['Recording limit reached. Release to send, or cancel to discard.']);
    await recorder.release();
    expect(sent, hasLength(4800));
    expect(sent!.last, 17);
    expect(mic.closed, isTrue);
    recorder.dispose();
  });

  test('cancelling a capped clip discards it without sending', () async {
    final mic = _Mic();
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (_, _) async => fail('capped recording sent before release'),
      report: (_) {},
      maxDuration: const Duration(milliseconds: 100),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(9600));
    await recorder.cancel();
    expect(mic.closed, isTrue);
    expect(recorder.busy, isFalse);
    recorder.dispose();
  });

  test('cancelling while permission or device open is pending closes its late stream', () async {
    final opening = Completer<MicStream>();
    final mic = _Mic();
    var resumed = 0;
    var sends = 0;
    final recorder = HeldAudioRecorder(
      open: () => opening.future,
      suspendListening: () async {},
      resumeListening: () async => resumed++,
      submit: (_, _) async => sends++,
      report: (message) => expect(message, contains('setup finished')),
    );
    recorder.start();
    await _tick();
    final cancelled = recorder.cancel();
    opening.complete(mic);
    await cancelled;
    expect(mic.closed, isTrue);
    expect(resumed, 1);
    expect(sends, 0);
    recorder.dispose();
  });

  test('release during a pending open never captures after release', () async {
    final opening = Completer<MicStream>();
    final mic = _Mic();
    final reports = <String>[];
    var sends = 0;
    final recorder = HeldAudioRecorder(
      open: () => opening.future,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (_, _) async => sends++,
      report: reports.add,
    );
    recorder.start();
    await _tick();
    final released = recorder.release();
    opening.complete(mic);
    await released;
    expect(mic.closed, isTrue);
    expect(sends, 0);
    expect(reports.single, contains('setup finished'));
    recorder.dispose();
  });

  test('unconfirmed close leaves listening paused and a later successful hold recovers', () async {
    final failedMic = _UnreleasedMic();
    final recoveredMic = _Mic();
    final reports = <String>[];
    var opens = 0;
    var resumed = 0;
    var sends = 0;
    final recorder = HeldAudioRecorder(
      open: () async => opens++ == 0 ? failedMic : recoveredMic,
      suspendListening: () async {},
      resumeListening: () async => resumed++,
      submit: (_, _) async => sends++,
      report: reports.add,
    );
    recorder.start();
    await _tick();
    failedMic.controller.add(Uint8List(4800));
    await recorder.release();
    expect(recorder.busy, isFalse);
    expect(resumed, 0);
    expect(sends, 0);
    expect(failedMic.controller.hasListener, isFalse);
    expect(reports.single, contains('Audio release failed. Listening is paused.'));
    await failedMic.controller.close();

    recorder.start();
    await _tick();
    recoveredMic.controller.add(Uint8List(4800));
    await recorder.release();
    expect(sends, 1);
    expect(resumed, 1);
    expect(recoveredMic.closed, isTrue);
    expect(recorder.busy, isFalse);
    recorder.dispose();
  });

  test('open cleanup release failure leaves listening paused without a returned stream', () async {
    final reports = <String>[];
    var resumed = 0;
    final recorder = HeldAudioRecorder(
      open: () async => throw AudioCaptureReleaseFailure('native stop timed out'),
      suspendListening: () async {},
      resumeListening: () async => resumed++,
      submit: (_, _) async => fail('failed opening sent audio'),
      report: reports.add,
    );
    recorder.start();
    await _tick();
    await recorder.cancel();
    expect(recorder.busy, isFalse);
    expect(resumed, 0);
    expect(reports.single, contains('Audio release failed. Listening is paused.'));
    recorder.dispose();
  });

  test('ordinary suspension failure still restores normal listening', () async {
    final reports = <String>[];
    var resumed = 0;
    final recorder = HeldAudioRecorder(
      open: () async => throw StateError('must not open after suspension failed'),
      suspendListening: () async => throw StateError('suspension interrupted'),
      resumeListening: () async => resumed++,
      submit: (_, _) async => fail('suspension failure sent audio'),
      report: reports.add,
    );
    recorder.start();
    await _tick();
    await recorder.cancel();
    expect(recorder.busy, isFalse);
    expect(resumed, 1);
    expect(reports.single, contains('suspension interrupted'));
    recorder.dispose();
  });

  test('permission failures restore listening and report the actual failure', () async {
    final reports = <String>[];
    var resumed = 0;
    final recorder = HeldAudioRecorder(
      open: () async => throw StateError('Microphone permission denied'),
      suspendListening: () async {},
      resumeListening: () async => resumed++,
      submit: (_, _) async => fail('denied recording sent'),
      report: reports.add,
    );
    recorder.start();
    await _tick();
    await recorder.cancel();
    expect(resumed, 1);
    expect(reports.single, contains('permission denied'));
    expect(recorder.busy, isFalse);
    recorder.dispose();
  });

  test('capture errors discard partial audio and close both-source capture', () async {
    final mic = _Mic();
    final reports = <String>[];
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (_, _) async => fail('partial audio sent'),
      report: reports.add,
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(9600));
    mic.controller.addError(StateError('system output disconnected'));
    await recorder.cancel();
    expect(mic.closed, isTrue);
    expect(reports.single, contains('system output disconnected'));
    recorder.dispose();
  });

  test('cancelling processing invalidates any late transcript submission', () async {
    final mic = _Mic();
    final transcript = Completer<void>();
    var sent = false;
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async {},
      submit: (_, current) async {
        await transcript.future;
        if (current()) sent = true;
      },
      report: (message) => fail(message),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(9600));
    final released = recorder.release();
    await _tick();
    final cancelled = recorder.cancel();
    transcript.complete();
    await Future.wait([released, cancelled]);
    expect(sent, isFalse);
    recorder.dispose();
  });

  test('dispose during capture closes the stream without a submission', () async {
    final mic = _Mic();
    var resumed = 0;
    final recorder = HeldAudioRecorder(
      open: () async => mic,
      suspendListening: () async {},
      resumeListening: () async => resumed++,
      submit: (_, _) async => fail('disposed recording sent'),
      report: (message) => fail(message),
    );
    recorder.start();
    await _tick();
    mic.controller.add(Uint8List(9600));
    recorder.dispose();
    await _tick();
    expect(mic.closed, isTrue);
    expect(resumed, 1);
  });
}
