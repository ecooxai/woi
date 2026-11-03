import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../platform/media_viewer.dart';
import '../platform/platform_services.dart';
import 'confirmations.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
import 'viewer/viewer_app.dart';
import 'widgets/glass.dart';
import 'widgets/voice_orb.dart';

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
    confirmations: UiConfirmationService(_navigatorKey),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _platform.viewer.overlayPresenter = (item) async {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) await showMediaOverlay(ctx, item, _platform.audio);
    };
    OrbShader.preload();
    _controller.init();
    _debugShowFromEnv();
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

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _controller.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Woi',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: buildWoiTheme(),
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
                      VoiceOrb(
                        mode: _controller.initError == null ? OrbMode.connecting : OrbMode.offline,
                        size: 180,
                      ),
                      const SizedBox(height: 18),
                      ShaderMask(
                        shaderCallback: (r) => const LinearGradient(
                          colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta],
                        ).createShader(r),
                        child: Text('WOI', style: display(30, weight: FontWeight.w700, color: Colors.white, spacing: 8)),
                      ),
                      const SizedBox(height: 10),
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
