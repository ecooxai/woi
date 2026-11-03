import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/settings/settings.dart';
import '../platform/media_viewer.dart';
import '../platform/platform_services.dart';
import '../platform/window_attention.dart';
import 'confirmations.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
import 'viewer/viewer_app.dart';
import 'widgets/glass.dart';

/// Root widget of the main window.
class WoiApp extends StatefulWidget {
  const WoiApp({super.key, this.platform});

  /// Defaults to [PlatformServices.forCurrentPlatform].
  final PlatformServices? platform;

  @override
  State<WoiApp> createState() => _WoiAppState();
}

class _WoiAppState extends State<WoiApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final PlatformServices _platform = widget.platform ?? PlatformServices.forCurrentPlatform();
  late final AppController _controller = AppController(
    platform: _platform,
    confirmations: UiConfirmationService(_navigatorKey, onShow: WindowAttention(audio: _platform.audio).request),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _platform.viewer.overlayPresenter = (item) async {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) await showMediaOverlay(ctx, item, _platform.audio);
    };
    _controller.addListener(_syncTheme);
    _controller.init();
    _debugShowFromEnv();
    _frameLogFromEnv();
  }

  /// Perf hook: `WOI_FRAME_LOG=1` prints the frame count every 5 s (only when
  /// frames were drawn), to find what keeps an idle window repainting.
  void _frameLogFromEnv() {
    if (Platform.environment['WOI_FRAME_LOG'] != '1') return;
    var frames = 0;
    WidgetsBinding.instance.addTimingsCallback((t) => frames += t.length);
    Timer.periodic(const Duration(seconds: 5), (_) {
      if (frames > 0) debugPrint('frames/5s: $frames');
      frames = 0;
    });
  }

  /// Debug hook: `WOI_DEBUG_SHOW=/a.png:/b.txt` opens each file in the media
  /// viewer shortly after start (used to verify the viewer window).
  void _debugShowFromEnv() {
    final spec = Platform.environment['WOI_DEBUG_SHOW'] ?? '';
    final paths = spec.split(':').where((s) => s.trim().isNotEmpty).toList();
    if (paths.isEmpty) return;
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      for (final path in paths) {
        try {
          final s = await _platform.viewer.show(MediaItem(kind: MediaItem.kindForPath(path), path: path));
          debugPrint('debug show $path -> ${s.name}');
        } catch (e) {
          debugPrint('debug show $path failed: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }());
  }

  AppTheme? _theme;

  /// Applies the theme setting. Widgets read [WoiColors] while building, so
  /// a switch marks every element dirty (like hot reload does) instead of
  /// rebuilding the app from scratch: routes, scroll offsets and text
  /// selections survive.
  void _syncTheme() {
    final t = _controller.ready ? _controller.settings.theme : AppTheme.light;
    if (t == _theme && t != AppTheme.system) return;
    _theme = t;
    final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (!WoiColors.use(paletteFor(t, brightness)) || !mounted) return;
    setState(() {});
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  void didChangePlatformBrightness() {
    if (_theme == AppTheme.system) _syncTheme();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _controller.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_syncTheme);
    _controller.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Woi',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: buildWoiTheme(WoiColors.palette),
      themeAnimationDuration: Duration.zero,
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (_controller.ready) return HomeScreen(controller: _controller);
          return Scaffold(
            body: WoiBackdrop(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Woi', style: display(32, weight: FontWeight.w700, spacing: -0.5)),
                      const SizedBox(height: 12),
                      if (_controller.initError == null)
                        Text('Starting up…', style: body(13, color: WoiColors.textDim))
                      else
                        Text(
                          'Woi failed to start:\n${_controller.initError}',
                          textAlign: TextAlign.center,
                          style: body(14, color: WoiColors.red),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
