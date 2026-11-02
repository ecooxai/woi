import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../platform/platform_services.dart';
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
    _controller.init();
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
                child: _controller.initError == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Woi failed to start:\n${_controller.initError}',
                          textAlign: TextAlign.center,
                          style: body(14, color: WoiColors.red),
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
