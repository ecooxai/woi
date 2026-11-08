import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/live_rtc_transport.dart';

void main() {
  Map<String, Object?> nativeOptions(Map<String, Object> audio) => {
    for (final entry in (audio['optional'] as List))
      ...(entry as Map).cast<String, Object?>(),
  };

  test('Android receives AEC, NS and AGC in its native optional parser', () {
    const options = LiveRtcOptions(androidAudioRoute: 'media');
    final audio = liveAudioConstraints(options,
        android: true, externalEchoCapture: false, deviceId: 'built-in-mic');
    expect(options.androidAudioRoute, 'media');
    expect(audio['echoCancellation'], true);
    expect(nativeOptions(audio), containsPair('googEchoCancellation', true));
    expect(nativeOptions(audio), containsPair('sourceId', 'built-in-mic'));
    expect(nativeOptions(audio), containsPair('googNoiseSuppression', true));
  });

  test('Android does not silently ignore disabled audio processing', () {
    final audio = liveAudioConstraints(
        const LiveRtcOptions(echoCancellation: false,
            noiseSuppression: false, autoGainControl: false),
        android: true, externalEchoCapture: false);
    expect(nativeOptions(audio), containsPair('googEchoCancellation', false));
    expect(nativeOptions(audio), containsPair('echoCancellation', false));
    expect(nativeOptions(audio), containsPair('googNoiseSuppression', false));
    expect(nativeOptions(audio), containsPair('googAutoGainControl', false));
  });

  test('external cancellation is not cascaded with native WebRTC AEC', () {
    final audio = liveAudioConstraints(const LiveRtcOptions(),
        android: true, externalEchoCapture: true);
    expect(audio['echoCancellation'], false);
    expect(nativeOptions(audio), containsPair('googEchoCancellation', false));
  });

  test('non-Android constraints keep the existing device shape', () {
    final audio = liveAudioConstraints(const LiveRtcOptions(),
        android: false, externalEchoCapture: false);
    expect(audio.containsKey('optional'), false);
    expect(audio['echoCancellation'], true);
  });
}
