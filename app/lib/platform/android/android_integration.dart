import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/app_controller.dart';
import '../../core/context/image_tiers.dart' show kAssistNotePrefix;
import '../../core/settings/settings.dart';
import '../media_viewer.dart';
import '../screen_capture.dart';
import 'android_bridge.dart';
import 'android_url_opener.dart';

/// Kind of viewer item for a shared file's MIME type (path extension as
/// fallback).
MediaKind mediaKindFor(String? mime, String path) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('image/')) return MediaKind.image;
  if (m.startsWith('audio/')) return MediaKind.audio;
  if (m.startsWith('video/')) return MediaKind.video;
  if (m.startsWith('text/')) return MediaKind.text;
  return MediaItem.kindForPath(path);
}

/// Turns Android OS events into app actions:
///  - assistant invocations attach the assist screenshot to the turn;
///  - "open with" / share opens the files in Woi's viewer;
///  - the voice foreground service runs while the session can listen;
///  - the sign-in foreground service stops once signed in.
class AndroidIntegration {
  AndroidIntegration(this.controller, {AndroidBridge? bridge}) : bridge = bridge ?? AndroidBridge.instance;

  final AppController controller;
  final AndroidBridge bridge;
  StreamSubscription<AndroidEvent>? _sub;
  final List<AndroidEvent> _early = [];
  bool _voiceOn = false;
  bool _overlay = false;
  bool _wasLogin = false;

  /// Last assist invocation (diagnostics / tests): shown -> attached ms.
  int? lastAssistLatencyMs;

  void start() {
    _sub = bridge.events.listen(_onEvent);
    for (final e in bridge.claimEarly()) {
      unawaited(_onEvent(e));
    }
    controller.addListener(_onController);
    unawaited(_permissions());
    _onController();
  }

  Future<void> _permissions() async {
    try {
      await bridge.requestPermissions(['android.permission.RECORD_AUDIO']);
      await bridge.requestPermissions(['android.permission.POST_NOTIFICATIONS']);
    } catch (e) {
      debugPrint('permissions: $e');
    }
    _onController();
  }

  void _onController() {
    if (!controller.ready) return;
    if (_early.isNotEmpty) {
      final queued = List.of(_early);
      _early.clear();
      for (final e in queued) {
        _onEvent(e);
      }
    }
    if (controller.needsLogin) {
      _wasLogin = true;
    } else if (_wasLogin) {
      _wasLogin = false;
      final o = controller.platform.urlOpener;
      if (o is AndroidUrlOpener) unawaited(o.done());
    }
    final wantVoice = !controller.needsLogin && controller.settings.micMode != MicMode.muted;
    // While the panel shows, keep the service even if muted: it can only be
    // restarted while Woi is visible.
    if (wantVoice != _voiceOn && (wantVoice || !_overlay || controller.needsLogin)) {
      _voiceOn = wantVoice;
      unawaited(bridge.call<bool>('voiceActive', {'on': wantVoice}).catchError((Object e) => false));
    }
  }

  Future<void> _onEvent(AndroidEvent e) async {
    if (e is OverlayEvent) {
      if (e.on) {
        // The panel started the microphone service natively (it may only
        // start while Woi is visible, and Android 14+ silences a background
        // mic without it). The assist event unmutes the mic; only a session
        // that can't listen (signed out) turns it off again.
        _overlay = true;
        _voiceOn = true;
        if (controller.ready && controller.needsLogin) _onController();
        if (controller.ready) unawaited(controller.assistantShown());
      } else {
        _overlay = false;
        controller.assistantDismissed();
        _onController();
      }
      return;
    }
    if (!controller.ready || controller.needsLogin) {
      if (e is AssistEvent || e is OpenEvent) _early.add(e);
      return;
    }
    try {
      switch (e) {
        case AssistEvent():
          await _assist(e);
        case OpenEvent():
          await _open(e);
        case StopAllEvent():
          await controller.setMicMode(MicMode.muted);
        default:
          break;
      }
    } catch (err, st) {
      debugPrint('android event $e failed: $err\n$st');
    }
  }

  Future<void> _assist(AssistEvent e) async {
    final path = e.pngPath;
    final app = e.app == null || e.app!.isEmpty ? 'the app they were using' : e.app!;
    if (path != null && File(path).existsSync()) {
      final png = await File(path).readAsBytes();
      final size = pngSize(png);
      final w = size?.$1 ?? e.width;
      final h = size?.$2 ?? e.height;
      final shot = Screenshot(
        png: png,
        width: w,
        height: h,
        originalWidth: e.originalWidth > 0 ? e.originalWidth : w,
        originalHeight: e.originalHeight > 0 ? e.originalHeight : h,
      );
      final text = (e.screenText ?? '').trim();
      final clipped = text.length > 1500 ? '${text.substring(0, 1500)}…' : text;
      await controller.pipeline.attachScreenshot(
        shot,
        note: e.overlay
            ? '$kAssistNotePrefix (long-press home) while in $app; this is that screen. '
                  'Woi floats as a bottom panel over that app, which is still open: click_screen, type_text and '
                  'send_keys act on it (the panel steps aside). '
            : '$kAssistNotePrefix (long-press home) while in $app; this is that screen. '
            '${clipped.isEmpty ? '' : 'Visible text: $clipped. '}',
        label: e.app == null || e.app!.isEmpty ? 'Assist screenshot' : 'Assist screenshot from ${e.app}',
        activation: true,
      );
      if (e.shownAtMs > 0) lastAssistLatencyMs = DateTime.now().millisecondsSinceEpoch - e.shownAtMs;
      debugPrint('assist screenshot attached ${w}x$h from $app, ${lastAssistLatencyMs ?? '?'} ms after the gesture');
    } else {
      controller.pipeline.notice('Assistant opened without a screenshot (enable "Use screenshot" in assist settings).');
    }
    if (controller.settings.micMode == MicMode.muted) await controller.setMicMode(MicMode.handsFree);
  }

  Future<void> _open(OpenEvent e) async {
    final viewer = controller.platform.viewer;
    var shown = 0;
    for (final f in e.files) {
      final path = f.path;
      if (path == null) {
        controller.pipeline.notice('Could not open ${f.name ?? 'a shared item'}: ${f.error ?? 'unreadable'}');
        continue;
      }
      await viewer.show(MediaItem(kind: mediaKindFor(f.mime, path), path: path, customTitle: f.name));
      shown++;
    }
    final text = (e.text ?? '').trim();
    if (shown == 0 && text.isNotEmpty) {
      await viewer.show(MediaItem(kind: MediaKind.text, text: text, customTitle: 'Shared text'));
    }
  }

  void dispose() {
    _sub?.cancel();
    controller.removeListener(_onController);
    if (_voiceOn) unawaited(bridge.call<bool>('voiceActive', {'on': false}).catchError((Object e) => false));
  }
}
