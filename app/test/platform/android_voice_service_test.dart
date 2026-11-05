import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_integration.dart';

void main() {
  VoiceService v({
    bool needsLogin = false,
    bool muted = false,
    bool overlay = false,
    bool idleWarm = false,
    bool suspended = false,
  }) => voiceServiceFor(
    needsLogin: needsLogin,
    muted: muted,
    overlay: overlay,
    idleWarm: idleWarm,
    suspended: suspended,
  );

  test('listening session uses the microphone service', () {
    expect(v(), VoiceService.mic);
  });

  test('panel open keeps the microphone service, even muted', () {
    expect(v(overlay: true), VoiceService.mic);
    expect(v(overlay: true, muted: true), VoiceService.mic);
    // Shown again while the session is still warm: mic comes back.
    expect(v(overlay: true, idleWarm: true), VoiceService.mic);
  });

  test('dismissed panel with the session kept warm is quiet (no mic type)', () {
    expect(v(idleWarm: true), VoiceService.warm);
  });

  test('suspended session (keep-alive over) stops the service', () {
    expect(v(suspended: true), VoiceService.off);
    expect(v(idleWarm: true, suspended: true), VoiceService.off);
  });

  test('signed out or muted stops the service', () {
    expect(v(needsLogin: true, overlay: true), VoiceService.off);
    expect(v(muted: true), VoiceService.off);
    expect(v(muted: true, idleWarm: true), VoiceService.off);
  });
}
