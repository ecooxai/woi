import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/settings/settings.dart';

import 'package:woi/core/voice/backend_factory.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';

void main() {
  test('reply delay defaults to 2 s, is clamped, and sets the Direct server VAD silence', () async {
    const d = AppSettings(backendMode: BackendMode.direct);
    expect(d.replyDelayMs, 2000);
    expect(AppSettings.fromJson(const {}).replyDelayMs, 2000);
    expect(AppSettings.fromJson(const {'replyDelayMs': 50}).replyDelayMs, kMinReplyDelayMs);
    expect(AppSettings.fromJson(const {'replyDelayMs': 99999}).replyDelayMs, kMaxReplyDelayMs);
    final longer = d.copyWith(replyDelayMs: 3000);
    expect(AppSettings.fromJson(longer.toJson()).replyDelayMs, 3000);
    expect(longer.sessionDiffers(d), isTrue, reason: 'Direct reconnects with the new turn detection');
    expect(
      const AppSettings(backendMode: BackendMode.gptLive).copyWith(replyDelayMs: 3000).sessionDiffers(
        const AppSettings(backendMode: BackendMode.gptLive),
      ),
      isFalse,
      reason: 'gpt-live does not use it',
    );
    final sel = createVoiceBackend(BackendContext(settings: longer, credentials: () async => null));
    final b = sel.backend as RealtimeWsBackend;
    expect(b.vadSilenceMs, 3000);
    await b.close();
  });

  test('idle standby defaults to 60 s, 0 is off, and is clamped', () {
    expect(const AppSettings().idleStandbySeconds, 60);
    expect(AppSettings.fromJson(const {}).idleStandbySeconds, 60);
    expect(AppSettings.fromJson(const {'idleStandbySeconds': 0}).idleStandbySeconds, 0);
    expect(AppSettings.fromJson(const {'idleStandbySeconds': 99999}).idleStandbySeconds, kMaxIdleStandbySeconds);
    expect(AppSettings.fromJson(const AppSettings(idleStandbySeconds: 90).toJson()).idleStandbySeconds, 90);
  });

  test('thinking earcon is off by default and round-trips through JSON', () {
    const d = AppSettings();
    expect(d.thinkingEarcon, isFalse);
    expect(AppSettings.fromJson(const {}).thinkingEarcon, isFalse);
    final on = d.copyWith(thinkingEarcon: true);
    expect(AppSettings.fromJson(on.toJson()).thinkingEarcon, isTrue);
    expect(on.sessionDiffers(d), isFalse, reason: 'toggling it never reconnects');
  });

  test('the Android audio route defaults to phone and round-trips through JSON', () {
    const d = AppSettings();
    expect(d.androidAudioRoute, AndroidAudioRoute.phone);
    expect(AppSettings.fromJson(const {'androidAudioRoute': 'bogus'}).androidAudioRoute, AndroidAudioRoute.phone);
    final media = d.copyWith(androidAudioRoute: AndroidAudioRoute.media);
    expect(AppSettings.fromJson(media.toJson()).androidAudioRoute, AndroidAudioRoute.media);
    expect(media.sessionDiffers(d), isFalse);
  });

  test('echo cancellation is on by default and round-trips through JSON', () {
    const d = AppSettings();
    expect(d.echoCancellation, isTrue);
    expect(AppSettings.fromJson(const {}).echoCancellation, isTrue);
    final off = d.copyWith(echoCancellation: false);
    expect(AppSettings.fromJson(off.toJson()).echoCancellation, isFalse);
    expect(off.sessionDiffers(d), isFalse);
  });

  test('voice is per mode: gpt-live voices vs realtime voices', () {
    const d = AppSettings();
    expect(d.activeVoice, 'cove');
    expect(d.voiceChoices, kLiveVoices);
    final direct = d.copyWith(backendMode: BackendMode.direct);
    expect(direct.activeVoice, 'marin');
    expect(direct.voiceChoices, kVoices);
    final changed = d.copyWith(liveVoice: 'juniper');
    expect(changed.sessionDiffers(d), isTrue);
    expect(AppSettings.fromJson(changed.toJson()).activeVoice, 'juniper');
  });

  test('workspace dir and image tiers round-trip with defaults 3/5/5', () {
    const d = AppSettings();
    expect((d.imageFullCount, d.imageScaledCount, d.imageScaleDivisor, d.workspaceDir), (3, 5, 5, ''));
    final x = d.copyWith(imageFullCount: 2, imageScaledCount: 4, imageScaleDivisor: 3, workspaceDir: '~/w');
    final y = AppSettings.fromJson(x.toJson());
    expect((y.imageFullCount, y.imageScaledCount, y.imageScaleDivisor, y.workspaceDir), (2, 4, 3, '~/w'));
  });
}
