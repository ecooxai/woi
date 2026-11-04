import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_audio_io.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  late List<MethodCall> calls;
  late List<Object?> listenArgs;

  setUp(() {
    calls = [];
    listenArgs = [];
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'requestPermissions':
          return true;
        case 'aecStatus':
          return 'active (VOICE_COMMUNICATION + platform AEC + NS)';
      }
      return null;
    });
    messenger.setMockMessageHandler('woi/android/events', (msg) async => codec.encodeSuccessEnvelope(null));
    messenger.setMockMessageHandler(AndroidBridge.micChannel.name, (msg) async {
      final call = codec.decodeMethodCall(msg);
      if (call.method == 'listen') listenArgs.add(call.arguments);
      return codec.encodeSuccessEnvelope(null);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
    messenger.setMockMessageHandler(AndroidBridge.micChannel.name, null);
    messenger.setMockMessageHandler('woi/android/events', null);
  });

  test('the Echo cancellation setting picks the capture source and shows the platform state', () async {
    final io = AndroidAudioIO();
    expect(io, isA<EchoCancellable>());
    expect(io.echoCancellation, isTrue);

    final mic = await io.openMic();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(listenArgs.last, {'aec': true, 'route': 'phone'});
    expect(io.echoCancellationStatus, contains('platform AEC'));
    expect(io.description, contains('echo cancellation: active'));
    await mic.close();

    io.echoCancellation = false;
    final plain = await io.openMic();
    expect(listenArgs.last, {'aec': false, 'route': 'phone'});
    expect(io.echoCancellationStatus, 'off (setting)');
    await plain.close();
  });
  test('the audio route goes to the recorder; another app recording pauses the mic', () async {
    final io = AndroidAudioIO();
    expect(io, isA<AudioRouted>());
    io.audioRoute = 'media';
    final mic = await io.openMic();
    expect(listenArgs.last, {'aec': true, 'route': 'media'});
    expect(io.description, contains('media route'));
    expect(io.micPaused.value, isNull);

    Future<void> emit(Map<String, Object?> e) => messenger.handlePlatformMessage(
      'woi/android/events',
      codec.encodeSuccessEnvelope(e),
      (_) {},
    );
    await emit({'type': 'micState', 'paused': true, 'reason': 'Mic paused: another app is using it'});
    await Future<void>.delayed(Duration.zero);
    expect(io.micPaused.value, 'Mic paused: another app is using it');
    await emit({'type': 'micState', 'paused': false});
    await Future<void>.delayed(Duration.zero);
    expect(io.micPaused.value, isNull);
    await mic.close();
  });
}
