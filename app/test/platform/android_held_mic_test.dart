import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_audio_io.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_screen_capture.dart';
import 'package:woi/platform/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  const name = 'woi/android/held_audio';
  late List<MethodCall> calls;
  late Completer<void> listening;
  var cancelled = 0;
  var permission = true;
  Completer<bool>? stopAcknowledgement;
  var stopFails = false;

  Future<void> emit(Object? value) => messenger.handlePlatformMessage(name, codec.encodeSuccessEnvelope(value), (_) {});

  Future<MicStream> openReadyMic() async {
    final opening = AndroidAudioIO().openHeldAudio();
    await listening.future;
    await emit({
      'ready': true,
      'sources': ['microphone'],
    });
    return opening;
  }

  void expectNoScreenCalls() {
    expect(
      calls.where((call) => call.method.startsWith('share')),
      isEmpty,
      reason: 'Held microphone capture must not start, stop, or read screen sharing',
    );
  }

  setUp(() {
    calls = [];
    listening = Completer<void>();
    cancelled = 0;
    permission = true;
    stopAcknowledgement = null;
    stopFails = false;
    AndroidBridge.instance.sharing.value = false;
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      if (call.method == 'requestPermissions') return permission;
      if (call.method == 'heldAudioStop') {
        if (stopFails) {
          throw PlatformException(code: 'held_audio_stop', message: 'Driver still closing');
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
    expectNoScreenCalls();
    AndroidBridge.instance.sharing.value = false;
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
    messenger.setMockMessageHandler(name, null);
  });

  test('held mic starts without projection and waits for native readiness', () async {
    final audio = AndroidAudioIO();
    final screen = AndroidScreenCapture();
    expect(audio, isA<HeldAudioCapture>());
    expect(audio.includesSystemAudio, isFalse);
    expect(screen.autoCapture, isFalse);
    final opening = audio.openHeldAudio();
    var ready = false;
    opening.then((_) => ready = true);
    await listening.future;
    expect(ready, isFalse);
    expect(calls.single.method, 'requestPermissions');
    expect(calls.single.arguments, {
      'permissions': ['android.permission.RECORD_AUDIO'],
    });
    await emit({
      'ready': true,
      'sources': ['microphone'],
    });
    final mic = await opening;
    final first = mic.chunks.first;
    final pcm = Uint8List.fromList([0, 1, 0, 2, 0, 3, 0, 4]);
    await emit(pcm);
    expect(await first, pcm);
    expect(AndroidBridge.instance.sharing.value, isFalse);
    expect(screen.autoCapture, isFalse);
    await mic.close();
    await mic.close();
    expect(cancelled, 1);
    expect(screen.autoCapture, isFalse);
  });

  test('microphone permission denial never opens native capture', () async {
    permission = false;
    await expectLater(AndroidAudioIO().openHeldAudio(), throwsStateError);
    expect(listening.isCompleted, isFalse);
    expect(calls.map((call) => call.method), ['requestPermissions']);
  });

  test('held mic preserves independently active screen sharing', () async {
    AndroidBridge.instance.sharing.value = true;
    final mic = await openReadyMic();
    expect(AndroidBridge.instance.sharing.value, isTrue);
    await mic.close();
    expect(AndroidBridge.instance.sharing.value, isTrue);
    expect(cancelled, 1);
  });

  test('ending an independent share does not end the held microphone', () async {
    AndroidBridge.instance.sharing.value = true;
    final mic = await openReadyMic();
    AndroidBridge.instance.sharing.value = false;
    final first = mic.chunks.first;
    final pcm = Uint8List.fromList([0, 1, 0, 2]);
    await emit(pcm);
    expect(await first, pcm);
    expect(cancelled, 0);
    await mic.close();
  });

  test('native startup failure is returned and the channel is closed', () async {
    final opening = AndroidAudioIO().openHeldAudio();
    final expected = expectLater(opening, throwsA(isA<PlatformException>()));
    await listening.future;
    await messenger.handlePlatformMessage(
      name,
      codec.encodeErrorEnvelope(code: 'held_audio', message: 'Microphone unavailable'),
      (_) {},
    );
    await expected;
    expect(calls.where((call) => call.method == 'heldAudioStop'), hasLength(1));
    expect(cancelled, 1);
  });

  test('native stream ending before readiness releases the microphone', () async {
    final opening = AndroidAudioIO().openHeldAudio();
    final expected = expectLater(opening, throwsStateError);
    await listening.future;
    await messenger.handlePlatformMessage(name, null, (_) {});
    await expected;
    expect(calls.where((call) => call.method == 'heldAudioStop'), hasLength(1));
    expect(cancelled, 1);
  });

  test('native microphone silencing reaches the active recorder as an error', () async {
    final mic = await openReadyMic();
    final error = expectLater(mic.chunks, emitsError(isA<PlatformException>()));
    await messenger.handlePlatformMessage(
      name,
      codec.encodeErrorEnvelope(code: 'held_audio', message: 'Android silenced the microphone; recording cancelled'),
      (_) {},
    );
    await error;
    await mic.close();
    expect(cancelled, 1);
  });

  test('close waits for native release before completing microphone handoff', () async {
    final mic = await openReadyMic();
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
  });

  test('failed native release still disposes the Dart capture subscription', () async {
    final mic = await openReadyMic();
    stopFails = true;
    await expectLater(mic.close(), throwsA(isA<AudioCaptureReleaseFailure>()));
    expect(cancelled, 1);
    await expectLater(mic.chunks, emitsDone);
  });

  test('unconfirmed native release fails the handoff', () async {
    final mic = await openReadyMic();
    stopAcknowledgement = Completer<bool>()..complete(false);
    await expectLater(mic.close(), throwsA(isA<AudioCaptureReleaseFailure>()));
    expect(cancelled, 1);
  });
}
