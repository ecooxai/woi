import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/auth/auth.dart';

import 'package:woi/core/voice/backend_factory.dart';
import 'package:woi/core/voice/realtime_ws_backend.dart';

void main() {
  test('text thinking defaults to medium, persists, and never reconnects voice', () {
    const defaults = AppSettings();
    expect(defaults.textReasoningEffort, 'medium');
    expect(AppSettings.fromJson(const {}).textReasoningEffort, 'medium');
    for (final effort in AppSettings.textReasoningEffortChoices) {
      final changed = defaults.copyWith(textReasoningEffort: effort);
      expect(AppSettings.fromJson(changed.toJson()).textReasoningEffort, effort);
      expect(changed.sessionDiffers(defaults), isFalse);
    }
    expect(AppSettings.fromJson(const {'textReasoningEffort': 'bad'}).textReasoningEffort, 'medium');
    expect(defaults.copyWith(textReasoningEffort: 'bad').textReasoningEffort, 'medium');
    expect(AppSettings.textReasoningEffortChoicesFor('gpt-6-luna'), contains('none'));
    expect(AppSettings.textReasoningEffortChoicesFor('gpt-6.1-sol'), isNot(contains('none')));
    expect(AppSettings.textReasoningEffortChoicesFor('gpt-4.1'), isEmpty);
    expect(AppSettings.fromJson(defaults.copyWith(idleStandbySeconds: 30).toJson()).idleStandbySeconds, 30);
  });

  test('image output choices persist and pointer routing refreshes session tools', () {
    final d = AppSettings.fromJson(const {});
    expect(d.imageModel, 'gpt-image-2.6-flare');
    expect(d.imageQuality, 'low');
    expect(d.imageSize, '1024x1024');
    expect(d.imageFormat, 'jpeg');
    expect(d.webSearchEnabled, isTrue);
    expect(d.useLunaPointer, isTrue);
    final changed = d.copyWith(
      imageModel: 'tenant-image-model',
      imageQuality: 'high',
      imageSize: '1536x1024',
      imageFormat: 'png',
      useLunaPointer: false,
    );
    final restored = AppSettings.fromJson(changed.toJson());
    expect(restored.imageModel, 'tenant-image-model');
    expect(restored.imageQuality, 'high');
    expect(restored.imageSize, '1536x1024');
    expect(restored.imageFormat, 'png');
    expect(restored.useLunaPointer, isFalse);
    expect(
      changed.copyWith(useLunaPointer: true).sessionDiffers(d),
      isFalse,
      reason: 'Image output choices apply to subsequent generation calls',
    );
    expect(
      d.copyWith(useLunaPointer: false).sessionDiffers(d),
      isTrue,
      reason: 'Changing the pointer agent refreshes control_pointer schema availability',
    );
    final searchOff = d.copyWith(webSearchEnabled: false);
    expect(AppSettings.fromJson(searchOff.toJson()).webSearchEnabled, isFalse);
    expect(searchOff.sessionDiffers(d), isTrue, reason: 'Search tool availability refreshes the session');
    for (final quality in ['low', 'medium', 'high', 'xhigh', 'max', 'auto']) {
      expect(AppSettings.fromJson(d.copyWith(imageQuality: quality).toJson()).imageQuality, quality);
    }
    for (final size in AppSettings.imageSizeChoices) {
      expect(AppSettings.fromJson(d.copyWith(imageSize: size).toJson()).imageSize, size);
    }
    for (final format in AppSettings.imageFormatChoices) {
      expect(AppSettings.fromJson(d.copyWith(imageFormat: format).toJson()).imageFormat, format);
    }
    final invalid = AppSettings.fromJson(const {
      'imageQuality': 'invalid',
      'imageSize': 'invalid',
      'imageFormat': 'invalid',
    });
    expect(invalid.imageQuality, 'low');
    expect(invalid.imageSize, '1024x1024');
    expect(invalid.imageFormat, 'jpeg');
    expect(AppSettings.fromJson(const {'imageFormat': 'JPG'}).imageFormat, 'jpeg');
  });

  test('previous image default migrates without resetting unrelated saved preferences', () {
    final previous =
        const AppSettings(
            imageModel: 'gpt-image-flare-2.1',
            imageQuality: 'high',
            delegateModel: 'private-reasoner',
            backendMode: BackendMode.apiKey,
            apiKey: 'qa-only-key',
            webSearchEnabled: false,
            theme: AppTheme.dark,
            micMode: MicMode.muted,
            screenshotScale: 0.5,
          ).toJson()
          ..remove('imageSize')
          ..remove('imageFormat')
          ..remove('useLunaPointer');
    expect(AppSettings.fromJson(previous).toJson(), {
      ...previous,
      'imageModel': 'gpt-image-2.6-flare',
      'imageSize': '1024x1024',
      'imageFormat': 'jpeg',
      'useLunaPointer': true,
    });
    for (final custom in ['tenant-image-model', 'gpt-image-flare-2.1-custom']) {
      expect(AppSettings.fromJson({...previous, 'imageModel': custom}).imageModel, custom);
    }
  });

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
      const AppSettings(backendMode: BackendMode.gptLive)
          .copyWith(replyDelayMs: 3000)
          .sessionDiffers(const AppSettings(backendMode: BackendMode.gptLive)),
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

  group('independent login, audio model and voice choices', () {
    const saved = AppSettings(
      backendMode: BackendMode.gptLive,
      apiKey: 'saved-api-key',
      voiceModel: 'saved-custom-live',
      realtimeModel: 'saved-custom-realtime',
      voice: 'echo',
      liveVoice: 'juniper',
      delegateModel: 'saved-text-model',
      compressionModel: 'saved-compaction-model',
    );

    test('existing JSON fields retain family and saved custom choices', () {
      for (final mode in BackendMode.values) {
        final original = saved.copyWith(backendMode: mode);
        final restored = AppSettings.fromJson(original.toJson());
        expect(restored.toJson(), original.toJson());
        expect(
          restored.audioModelFamily,
          mode == BackendMode.gptLive ? AudioModelFamily.live : AudioModelFamily.realtime,
        );
        expect(restored.audioModel, mode == BackendMode.gptLive ? 'saved-custom-live' : 'saved-custom-realtime');
        expect(restored.toJson(), isNot(contains('audioModel')));
        expect(restored.toJson(), isNot(contains('audioModelFamily')));
      }
      final legacy = AppSettings.fromJson(const {
        'authMode': 'apiKey',
        'realtimeModel': 'legacy-custom-realtime',
        'voice': 'echo',
      });
      expect(legacy.authMode, AuthMode.apiKey);
      expect(legacy.audioModelFamily, AudioModelFamily.realtime);
      expect(legacy.audioModel, 'legacy-custom-realtime');
      expect(legacy.activeVoice, 'echo');
    });

    test('API then Codex preserves realtime instead of silently returning to live', () {
      expect(identical(saved.withAuthMode(AuthMode.codex), saved), isTrue);
      final api = saved.withAuthMode(AuthMode.apiKey);
      expect(api.toJson(), {...saved.toJson(), 'backendMode': 'apiKey'});
      expect(api.audioModel, 'saved-custom-realtime');
      expect(api.activeVoice, 'echo');
      final codex = api.withAuthMode(AuthMode.codex);
      expect(codex.toJson(), {...saved.toJson(), 'backendMode': 'direct'});
      expect(codex.authMode, AuthMode.codex);
      expect(codex.audioModelFamily, AudioModelFamily.realtime);
      expect(codex.audioModel, api.audioModel);
      expect(codex.activeVoice, api.activeVoice);
    });

    test('model selections preserve authentication and both saved voices', () {
      final realtime = saved.withAudioModel('gpt-realtime-2.1', family: AudioModelFamily.realtime);
      expect(realtime.toJson(), {...saved.toJson(), 'backendMode': 'direct', 'realtimeModel': 'gpt-realtime-2.1'});
      expect(realtime.authMode, AuthMode.codex);
      final live = realtime.withAudioModel('gpt-live-1.1', family: AudioModelFamily.live);
      expect(live.toJson(), {...realtime.toJson(), 'backendMode': 'gptLive', 'voiceModel': 'gpt-live-1.1'});
      expect(live.authMode, AuthMode.codex);
      final api = saved.withAuthMode(AuthMode.apiKey);
      final apiModel = api.withAudioModel('gpt-realtime-2.1-mini', family: AudioModelFamily.realtime);
      expect(apiModel.toJson(), {...api.toJson(), 'realtimeModel': 'gpt-realtime-2.1-mini'});
      expect(apiModel.authMode, AuthMode.apiKey);
    });

    test('custom IDs use explicit family, without guessing from their name', () {
      final realtime = saved.withAudioModel('gpt-live-custom-id', family: AudioModelFamily.realtime);
      expect(realtime.audioModelFamily, AudioModelFamily.realtime);
      expect(realtime.audioModel, 'gpt-live-custom-id');
      final live = realtime.withAudioModel('tenant-audio-id', family: AudioModelFamily.live);
      expect(live.audioModelFamily, AudioModelFamily.live);
      expect(live.audioModel, 'tenant-audio-id');
      expect(live.realtimeModel, 'gpt-live-custom-id');
      expect(AppSettings.fromJson(live.toJson()).audioModel, 'tenant-audio-id');
    });

    test('API and unavailable builds explain and reject live selections', () {
      final api = saved.withAuthMode(AuthMode.apiKey);
      expect(api.audioModelUnavailableReason(AudioModelFamily.live), contains('Codex login'));
      expect(() => api.withAudioModel('gpt-live-1.1', family: AudioModelFamily.live), throwsArgumentError);
      expect(saved.audioModelUnavailableReason(AudioModelFamily.live, liveAvailable: false), contains('not available'));
      expect(
        () => saved.withAudioModel('saved-custom-live', family: AudioModelFamily.live, liveAvailable: false),
        throwsArgumentError,
      );
      expect(api.audioModelUnavailableReason(AudioModelFamily.realtime, liveAvailable: false), isNull);
      expect(saved.audioModelUnavailableReason(AudioModelFamily.live), isNull);
    });

    test('empty models and known models paired with the wrong family are rejected', () {
      expect(() => saved.withAudioModel('  ', family: AudioModelFamily.live), throwsArgumentError);
      expect(() => saved.withAudioModel('', family: AudioModelFamily.realtime), throwsArgumentError);
      expect(() => saved.withAudioModel('gpt-realtime-2.1', family: AudioModelFamily.live), throwsArgumentError);
      expect(() => saved.withAudioModel('gpt-live-1.1', family: AudioModelFamily.realtime), throwsArgumentError);
    });

    test('voice choices change only the active voice and preserve model/login', () {
      final live = saved.withActiveVoice('cove');
      expect(live.toJson(), {...saved.toJson(), 'liveVoice': 'cove'});
      expect(live.audioModel, saved.audioModel);
      expect(live.authMode, saved.authMode);
      for (final mode in [BackendMode.direct, BackendMode.apiKey]) {
        final original = saved.copyWith(backendMode: mode);
        final changed = original.withActiveVoice('marin');
        expect(changed.toJson(), {...original.toJson(), 'voice': 'marin'});
        expect(changed.audioModel, original.audioModel);
        expect(changed.authMode, original.authMode);
      }
    });

    test('incompatible voices never switch family or silently replace a saved value', () {
      expect(() => saved.withActiveVoice('marin'), throwsArgumentError);
      expect(() => saved.withActiveVoice('echo'), throwsArgumentError);
      expect(() => saved.withAuthMode(AuthMode.apiKey).withActiveVoice('cove'), throwsArgumentError);
      expect(() => saved.withActiveVoice(''), throwsArgumentError);
      final legacy = AppSettings.fromJson(const {'backendMode': 'gptLive', 'liveVoice': 'legacy-voice-id'});
      expect(legacy.liveVoice, 'legacy-voice-id');
      expect(legacy.activeVoice, 'legacy-voice-id');
      expect(legacy.toJson()['liveVoice'], 'legacy-voice-id');
      expect(() => legacy.withActiveVoice('legacy-voice-id'), throwsArgumentError);
    });

    test('editing an inactive API key never reconnects either Codex backend', () {
      for (final mode in BackendMode.values) {
        final before = saved.copyWith(backendMode: mode);
        final edited = before.copyWith(apiKey: 'edited-api-key');
        expect(before.sessionDiffers(edited), mode == BackendMode.apiKey, reason: mode.name);
        expect(edited.sessionDiffers(before), mode == BackendMode.apiKey, reason: mode.name);
        expect(edited.apiKey, 'edited-api-key');
      }
      expect(saved.sessionDiffers(saved.withAuthMode(AuthMode.apiKey)), isTrue);
      expect(saved.sessionDiffers(saved.withAudioModel('gpt-realtime-2.1', family: AudioModelFamily.realtime)), isTrue);
      expect(saved.sessionDiffers(saved.withActiveVoice('cove')), isTrue);
      expect(saved.sessionDiffers(saved.withActiveVoice('juniper')), isFalse);
    });
  });
}
