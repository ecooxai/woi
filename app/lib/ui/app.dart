import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/settings/settings.dart';
import '../platform/android/android_bridge.dart';
import '../platform/android/android_integration.dart';
import '../platform/android/android_media_viewer.dart';
import '../platform/media_viewer.dart';
import '../platform/platform_services.dart';
import '../platform/window_attention.dart';
import 'assist/assist_panel.dart';
import 'confirmations.dart';
import 'login/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
import 'viewer/viewer_app.dart';
import 'widgets/glass.dart';
import 'widgets/input_bar.dart';

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
    confirmations: UiConfirmationService(
      _navigatorKey,
      onShow: Platform.isAndroid ? null : WindowAttention(audio: _platform.audio).request,
    ),
  );
  AndroidIntegration? _android;
  AssistPanelPresenter? _assistPanel;

  /// The last tab used in the assist panel (Chat at first; kept apart from
  /// the full app's tab for this run).
  HomeView _assistTab = HomeView.chat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final viewer = _platform.viewer;
    if (viewer is AndroidMediaViewer) {
      // Phones: the viewer is a full-screen route.
      viewer
        ..overlayPresenter = (item) async {
          final nav = _navigatorKey.currentState;
          if (nav != null) {
            await showMediaRoute(nav, item, _platform.audio, footer: InputBar(controller: _controller, phone: true));
          }
        }
        ..closer = (() => closeMediaRoute(_navigatorKey.currentState))
        ..commander = sendViewerCommand;
    } else {
      viewer.overlayPresenter = (item) async {
        final ctx = _navigatorKey.currentContext;
        if (ctx != null && ctx.mounted) await showMediaOverlay(ctx, item, _platform.audio);
      };
    }
    _controller.addListener(_syncTheme);
    _controller.init();
    if (Platform.isAndroid) {
      _android = AndroidIntegration(_controller)..start();
      _startAssistPanel(AndroidBridge.instance);
    } else if (Platform.environment['WOI_DEBUG_ASSIST_PANEL'] == '1') {
      _startDebugAssistPanel();
    }
    _debugShowFromEnv();
    _debugCameraFromEnv();
    _frameLogFromEnv();
  }

  /// The assistant gesture floats Woi as a bottom panel over the current app
  /// (WoiOverlay.kt renders this engine in the assistant session's window).
  void _startAssistPanel(AndroidBridge bridge) {
    void call(String method, [Map<String, Object?>? args]) =>
        unawaited(bridge.call<bool>(method, args).catchError((Object e) => false));
    _assistPanel = AssistPanelPresenter(
      navigatorKey: _navigatorKey,
      visible: bridge.overlayVisible,
      onShown: () => call('overlayReady'),
      builder: (context) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => AssistPanel(
          controller: _controller,
          initialFraction: bridge.overlayFraction,
          initialView: _assistTab,
          onViewChanged: (v) => _assistTab = v,
          onFractionChanged: (f) {
            bridge.overlayFraction = f;
            call('overlaySaveFraction', {'fraction': f});
          },
          onDismiss: () => call('overlayDismiss'),
          onOpenApp: () => call('overlayOpenApp'),
        ),
      ),
    )..start();
  }

  /// Debug hook: `WOI_DEBUG_ASSIST_PANEL=1` shows the Android assist panel
  /// over a plain background on desktop (layout checks at a phone-sized
  /// window); close / open app / dismiss take it down.
  void _startDebugAssistPanel() {
    final visible = ValueNotifier(true);
    _assistPanel = AssistPanelPresenter(
      navigatorKey: _navigatorKey,
      visible: visible,
      builder: (context) => ColoredBox(
        color: const Color(0xFF5C6B7A),
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => AssistPanel(
            controller: _controller,
            initialView: _assistTab,
            onViewChanged: (v) => _assistTab = v,
            onDismiss: () => visible.value = false,
            onOpenApp: () => visible.value = false,
          ),
        ),
      ),
    )..start();
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
  /// viewer shortly after start (used to verify the viewer window);
  /// `WOI_DEBUG_SHOW_DELAY` sets the delay in seconds (default 2).
  void _debugShowFromEnv() {
    final spec = Platform.environment['WOI_DEBUG_SHOW'] ?? '';
    final paths = spec.split(':').where((s) => s.trim().isNotEmpty).toList();
    if (paths.isEmpty) return;
    unawaited(() async {
      final delay = int.tryParse(Platform.environment['WOI_DEBUG_SHOW_DELAY'] ?? '') ?? 2;
      await Future<void>.delayed(Duration(seconds: delay));
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

  /// Debug hook: `WOI_DEBUG_CAMERA=1` opens the camera once the app is ready
  /// (perf scenario "camera").
  void _debugCameraFromEnv() {
    if (Platform.environment['WOI_DEBUG_CAMERA'] != '1') return;
    unawaited(() async {
      while (!_controller.ready) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      debugPrint('debug camera -> ${await _controller.setCamera(true)}');
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
  void didChangeAppLifecycleState(AppLifecycleState state) => _controller.onLifecycle(state);

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
    _assistPanel?.dispose();
    _android?.dispose();
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
          if (_controller.ready && _controller.needsLogin) {
            return LoginScreen(
              createFlow: _controller.createLoginFlow,
              onSignedIn: _controller.completeChatGptLogin,
              onApiKey: _controller.useApiKey,
            );
          }
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
