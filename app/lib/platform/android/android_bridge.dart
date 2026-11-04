import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Device facts from the Kotlin side (MainActivity / WoiBridge.kt).
class AndroidInfo {
  const AndroidInfo({
    required this.filesDir,
    required this.cacheDir,
    required this.sdk,
    required this.model,
    required this.screenWidth,
    required this.screenHeight,
    required this.density,
    required this.packageName,
  });

  final String filesDir;
  final String cacheDir;
  final int sdk;
  final String model;
  final int screenWidth;
  final int screenHeight;
  final double density;
  final String packageName;

  factory AndroidInfo.fromMap(Map<Object?, Object?> m) => AndroidInfo(
    filesDir: m['filesDir']! as String,
    cacheDir: m['cacheDir']! as String,
    sdk: (m['sdk'] as num?)?.toInt() ?? 0,
    model: (m['model'] as String?) ?? 'Android',
    screenWidth: (m['screenWidth'] as num?)?.toInt() ?? 0,
    screenHeight: (m['screenHeight'] as num?)?.toInt() ?? 0,
    density: (m['density'] as num?)?.toDouble() ?? 1,
    packageName: (m['package'] as String?) ?? 'dev.woi.woi',
  );
}

/// What the OS started: an assistant invocation, files opened/shared with
/// Woi, screen-share state changes, finished audio clips.
sealed class AndroidEvent {
  const AndroidEvent();

  static AndroidEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    switch (m['type']) {
      case 'assist':
        return AssistEvent(
          pngPath: m['png'] as String?,
          width: (m['width'] as num?)?.toInt() ?? 0,
          height: (m['height'] as num?)?.toInt() ?? 0,
          originalWidth: (m['originalWidth'] as num?)?.toInt() ?? 0,
          originalHeight: (m['originalHeight'] as num?)?.toInt() ?? 0,
          app: m['app'] as String?,
          screenText: m['screenText'] as String?,
          shownAtMs: (m['shownAt'] as num?)?.toInt() ?? 0,
          overlay: m['overlay'] == true,
        );
      case 'overlay':
        return OverlayEvent(on: m['on'] == true, fraction: (m['fraction'] as num?)?.toDouble());
      case 'open':
        final files = <SharedFile>[];
        for (final f in (m['files'] as List?) ?? const []) {
          if (f is! Map) continue;
          files.add(
            SharedFile(
              path: f['path'] as String?,
              mime: f['mime'] as String?,
              name: f['name'] as String?,
              error: f['error'] as String?,
            ),
          );
        }
        return OpenEvent(files: files, text: m['text'] as String?, mime: m['mime'] as String?);
      case 'share':
        return ShareStateEvent(on: m['on'] == true, error: m['error'] as String?);
      case 'micState':
        return MicStateEvent(paused: m['paused'] == true, reason: m['reason'] as String?);
      case 'clipDone':
        return ClipDoneEvent((m['id'] as num).toInt());
      case 'stopAll':
        return const StopAllEvent();
      case 'camera':
        final jpeg = m['jpeg'];
        if (jpeg is! Uint8List) return null;
        return CameraFrameEvent(
          jpeg: jpeg,
          width: (m['width'] as num?)?.toInt() ?? 0,
          height: (m['height'] as num?)?.toInt() ?? 0,
        );
    }
    return null;
  }
}

class AssistEvent extends AndroidEvent {
  const AssistEvent({
    this.pngPath,
    this.width = 0,
    this.height = 0,
    this.originalWidth = 0,
    this.originalHeight = 0,
    this.app,
    this.screenText,
    this.shownAtMs = 0,
    this.overlay = false,
  });

  /// Assist screenshot (PNG, scaled to [width]x[height]); null when the
  /// system sent none (assist screenshots off, or `am start -a ASSIST`).
  final String? pngPath;
  final int width;
  final int height;
  final int originalWidth;
  final int originalHeight;

  /// Package of the app the user was in.
  final String? app;

  /// Visible text from the AssistStructure (may be empty).
  final String? screenText;

  /// When the system showed the session (epoch ms), for latency logs.
  final int shownAtMs;

  /// Delivered to the floating panel (Woi stays in the background).
  final bool overlay;
}

/// The assistant panel was put up over another app ([on]) or taken down.
/// [fraction]: the remembered panel height (share of the screen height).
class OverlayEvent extends AndroidEvent {
  const OverlayEvent({required this.on, this.fraction});
  final bool on;
  final double? fraction;
}

class SharedFile {
  const SharedFile({this.path, this.mime, this.name, this.error});
  final String? path;
  final String? mime;
  final String? name;
  final String? error;
}

class OpenEvent extends AndroidEvent {
  const OpenEvent({required this.files, this.text, this.mime});
  final List<SharedFile> files;
  final String? text;
  final String? mime;
}

class ShareStateEvent extends AndroidEvent {
  const ShareStateEvent({required this.on, this.error});
  final bool on;
  final String? error;
}

/// The mic paused for / resumed after another app's recording.
class MicStateEvent extends AndroidEvent {
  const MicStateEvent({required this.paused, this.reason});
  final bool paused;
  final String? reason;
}

class ClipDoneEvent extends AndroidEvent {
  const ClipDoneEvent(this.id);
  final int id;
}

/// A camera frame (JPEG, upright) while the camera is open.
class CameraFrameEvent extends AndroidEvent {
  const CameraFrameEvent({required this.jpeg, required this.width, required this.height});
  final Uint8List jpeg;
  final int width;
  final int height;
}

/// The notification's "Stop" action ended voice and sharing.
class StopAllEvent extends AndroidEvent {
  const StopAllEvent();
}

/// Channels to the Kotlin side. One instance per engine.
class AndroidBridge {
  AndroidBridge._();
  static final AndroidBridge instance = AndroidBridge._();

  static const method = MethodChannel('woi/android');
  static const _events = EventChannel('woi/android/events');
  static const micChannel = EventChannel('woi/android/mic');

  AndroidInfo? _info;
  AndroidInfo get info => _info ?? (throw StateError('AndroidBridge.init() first'));

  late final Stream<AndroidEvent> events = _events
      .receiveBroadcastStream()
      .map(AndroidEvent.parse)
      .where((e) => e != null)
      .cast<AndroidEvent>()
      .asBroadcastStream();

  /// Screen share on/off (also flipped by the system "stop" chip).
  final sharing = ValueNotifier<bool>(false);

  /// Woi's accessibility service is connected.
  final accessibility = ValueNotifier<bool>(false);

  /// The assistant floats as a panel over another app (WoiOverlay.kt).
  final overlayVisible = ValueNotifier<bool>(false);

  /// Remembered panel height while [overlayVisible] (share of the screen).
  double overlayFraction = 0.6;

  StreamSubscription<AndroidEvent>? _sub;

  // Assist/open events that arrived before AndroidIntegration listened
  // (cold start from the assist gesture): a broadcast stream would drop them.
  List<AndroidEvent>? _early = [];

  /// Events [AndroidIntegration] missed before it subscribed; call once,
  /// right after subscribing.
  List<AndroidEvent> claimEarly() {
    final e = _early ?? const <AndroidEvent>[];
    _early = null;
    return e;
  }

  Future<AndroidInfo> init() async {
    final m = await method.invokeMapMethod<Object?, Object?>('init');
    _info = AndroidInfo.fromMap(m!);
    _sub ??= events.listen(onEvent);
    unawaited(refreshStatus());
    return _info!;
  }

  /// Bridge-level state from OS events (also used by tests).
  @visibleForTesting
  void onEvent(AndroidEvent e) {
    switch (e) {
      case ShareStateEvent():
        sharing.value = e.on;
      case StopAllEvent():
        sharing.value = false;
      case OverlayEvent():
        if (e.fraction != null) overlayFraction = e.fraction!;
        overlayVisible.value = e.on;
      case AssistEvent() || OpenEvent():
        _early?.add(e);
      default:
        break;
    }
  }

  Future<Map<String, bool>> refreshStatus() async {
    try {
      final m = await method.invokeMapMethod<String, Object?>('status') ?? const {};
      final s = {for (final e in m.entries) e.key: e.value == true};
      accessibility.value = s['accessibility'] ?? false;
      sharing.value = s['sharing'] ?? false;
      return s;
    } catch (e) {
      debugPrint('android status: $e');
      return const {};
    }
  }

  Future<bool> requestPermissions(List<String> permissions) async =>
      await method.invokeMethod<bool>('requestPermissions', {'permissions': permissions}) ?? false;

  Future<T?> call<T>(String name, [Object? args]) => method.invokeMethod<T>(name, args);
}
