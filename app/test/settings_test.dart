import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/settings/settings.dart';

void main() {
  test('thinking earcon is off by default and round-trips through JSON', () {
    const d = AppSettings();
    expect(d.thinkingEarcon, isFalse);
    expect(AppSettings.fromJson(const {}).thinkingEarcon, isFalse);
    final on = d.copyWith(thinkingEarcon: true);
    expect(AppSettings.fromJson(on.toJson()).thinkingEarcon, isTrue);
    expect(on.sessionDiffers(d), isFalse, reason: 'toggling it never reconnects');
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
