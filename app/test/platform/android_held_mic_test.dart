import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_audio_io.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  const name = 'woi/android/held_audio';
  late List<MethodCall> calls;
  late Completer<void> listening;
  var cancelled = 0;
  var permission = true;
  var sharingAccepted = true;
  Completer<bool>? stopAcknowledgement;
  var stopFails = false;

  Future<void> emit(Object? value) => messenger.handlePlatformMessage(
    name,
    codec.encodeSuccessEnvelope(value),
    (_) {},
  );

  setUp(() {
    calls = [];
    listening = Completer<void>();
    cancelled = 0;
    permission = true;
    sharingAccepted = true;
    stopAcknowledgement = null;
    stopFails = false;
    AndroidBridge.instance.sharing.value = true;
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      if (call.method == 'requestPermissions') return permission;
      if (call.method == 'shareStart') return sharingAccepted;
      if (call.method == 'heldAudioStop') {
        if (stopFails) {
          throw PlatformException(
            code: 'held_audio_stop',
            message: 'Driver still closing',
          );
        }
        return stopAcknowledgement?.future ?? true;
      }
      return null;
    });
    messenger.setMockMessageHandler(name, (message) async {
      final call = codec.decodeMethodCall(message);
      if (call.method == 'listen' && !listening.isCompleted) {
        listening.complete();
      }
      if (call.method == 'cancel') cancelled++;
      return codec.encodeSuccessEnvelope(null);
    });
  });

  tearDown(() {
    AndroidBridge.instance.sharing.value = false;
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
    messenger.setMockMessageHandler(name, null);
  });

  test('held capture waits for both native sources and receives PCM', () async {
    final opening = AndroidAudioIO().openMicAndSystemAudio();
    var ready = false;
    opening.then((_) => ready = true);
    await listening.future;
    expect(ready, isFalse);
    await emit({'ready': true});
    final mic = await opening;
    final first = mic.chunks.first;
    final pcm = Uint8List.fromList([0, 1, 0, 2, 0, 3, 0, 4]);
    await emit(pcm);
    expect(await first, pcm);
    expect(calls.where((c) => c.method == 'shareStart'), isEmpty);
    await mic.close();
    await mic.close();
    expect(cancelled, 1);
  });

  test('microphone permission denial never starts either source', () async {
    permission = false;
    await expectLater(
      AndroidAudioIO().openMicAndSystemAudio(),
      throwsStateError,
    );
    expect(listening.isCompleted, isFalse);
  });

  test('system consent denial never records a microphone-only clip', () async {
    AndroidBridge.instance.sharing.value = false;
    sharingAccepted = false;
    await expectLater(
      AndroidAudioIO().openMicAndSystemAudio(),
      throwsStateError,
    );
    expect(listening.isCompleted, isFalse);
  });

  test('consent completion waits for native projection readiness', () async {
    AndroidBridge.instance.sharing.value = false;
    final opening = AndroidAudioIO().openMicAndSystemAudio();
    await Future<void>.delayed(Duration.zero);
    expect(calls.any((c) => c.method == 'shareStart'), isTrue);
    expect(listening.isCompleted, isFalse);
    AndroidBridge.instance.sharing.value = true;
    await listening.future;
    await emit({'ready': true});
    final mic = await opening;
    await mic.close();
  });

  test(
    'native startup failure is returned and the capture channel is closed',
    () async {
      final opening = AndroidAudioIO().openMicAndSystemAudio();
      final expected = expectLater(opening, throwsA(isA<PlatformException>()));
      await listening.future;
      await messenger.handlePlatformMessage(
        name,
        codec.encodeErrorEnvelope(
          code: 'held_audio',
          message: 'System source unavailable',
        ),
        (_) {},
      );
      await expected;
      expect(cancelled, 1);
    },
  );

  test(
    'projection revocation reaches the active recorder as an error',
    () async {
      final opening = AndroidAudioIO().openMicAndSystemAudio();
      await listening.future;
      await emit({'ready': true});
      final mic = await opening;
      final error = expectLater(
        mic.chunks,
        emitsError(isA<PlatformException>()),
      );
      await messenger.handlePlatformMessage(
        name,
        codec.encodeErrorEnvelope(
          code: 'held_audio',
          message: 'Projection revoked',
        ),
        (_) {},
      );
      await error;
      await mic.close();
      expect(cancelled, 1);
    },
  );
  test(
    'close waits for native release before completing the microphone handoff',
    () async {
      final opening = AndroidAudioIO().openMicAndSystemAudio();
      await listening.future;
      await emit({'ready': true});
      final mic = await opening;
      stopAcknowledgement = Completer<bool>();
      var closed = false;
      final release = mic.close();
      expect(identical(release, mic.close()), isTrue);
      final closing = release.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(cancelled, 0);
      stopAcknowledgement!.complete(true);
      await closing;
      expect(closed, isTrue);
      expect(cancelled, 1);
    },
  );

  test(
    'failed native release still disposes the Dart capture subscription',
    () async {
      final opening = AndroidAudioIO().openMicAndSystemAudio();
      await listening.future;
      await emit({'ready': true});
      final mic = await opening;
      stopFails = true;
      await expectLater(
        mic.close(),
        throwsA(isA<AudioCaptureReleaseFailure>()),
      );
      expect(cancelled, 1);
      await expectLater(mic.chunks, emitsDone);
    },
  );
}
