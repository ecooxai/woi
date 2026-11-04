import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models/message.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import '../widgets/edit_review_card.dart';
import '../widgets/input_bar.dart';
import '../widgets/message_tile.dart';

/// Panel height as a share of the screen height.
const kAssistPanelDefault = 0.6;
const kAssistPanelMin = 0.35;
const kAssistPanelMax = 0.95;

/// A downward fling faster than this (logical px/s) on the handle dismisses.
const kAssistDismissVelocity = 900.0;

/// The assistant floating over another app (Android, WoiOverlay.kt): a light
/// scrim (tap = dismiss) and a bottom panel with rounded top corners holding
/// the compact UI: header (screenshot thumbnail, open full app, close), the
/// recent transcript, a pending edit, and the input bar with status and mic.
///
/// The drag handle resizes it between [kAssistPanelMin] and [kAssistPanelMax];
/// dragging below the minimum or flinging down dismisses.
class AssistPanel extends StatefulWidget {
  const AssistPanel({
    super.key,
    required this.controller,
    required this.onDismiss,
    required this.onOpenApp,
    this.initialFraction = kAssistPanelDefault,
    this.onFractionChanged,
  });

  final AppController controller;
  final double initialFraction;

  /// After a resize, with the new height share (to remember it).
  final ValueChanged<double>? onFractionChanged;
  final VoidCallback onDismiss;
  final VoidCallback onOpenApp;

  @override
  State<AssistPanel> createState() => _AssistPanelState();
}

class _AssistPanelState extends State<AssistPanel> {
  late double _fraction = widget.initialFraction.clamp(kAssistPanelMin, kAssistPanelMax);

  /// Fraction while dragging (may dip below the minimum: about to dismiss).
  double? _drag;
  bool _dismissed = false;

  AppController get c => widget.controller;

  void _dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    widget.onDismiss();
  }

  void _onDragUpdate(DragUpdateDetails d, double h) {
    final f = (_drag ?? _fraction) - d.delta.dy / h;
    setState(() => _drag = f.clamp(kAssistPanelMin - 0.2, kAssistPanelMax));
  }

  void _onDragEnd(DragEndDetails d) {
    final f = _drag ?? _fraction;
    final v = d.velocity.pixelsPerSecond.dy;
    if (v > kAssistDismissVelocity || f < kAssistPanelMin - 0.06) {
      setState(() => _drag = null);
      _dismiss();
      return;
    }
    setState(() {
      _drag = null;
      _fraction = f.clamp(kAssistPanelMin, kAssistPanelMax);
    });
    widget.onFractionChanged?.call(_fraction);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight;
        final keyboard = mq.viewInsets.bottom;
        final top = mq.viewPadding.top;
        final share = (_drag ?? _fraction).clamp(0.0, kAssistPanelMax);
        // The keyboard lifts the panel; it never grows past the status bar.
        final room = (h - keyboard - top).clamp(0.0, h).toDouble();
        final panelH = (h * share).clamp(0.0, room).toDouble();
        // Dragged below the minimum (about to dismiss): the content keeps
        // its minimum layout and slides out of view instead of squeezing.
        final contentH = panelH < h * kAssistPanelMin ? (h * kAssistPanelMin).clamp(0.0, room).toDouble() : panelH;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('assist-scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: _dismiss,
                child: Semantics(
                  label: 'Close assistant',
                  button: true,
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.10)),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboard,
              height: panelH,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: contentH,
                  maxHeight: contentH,
                  child: _panel(context, h, bottomInset: keyboard > 0 ? 0 : mq.viewPadding.bottom),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context, double screenH, {required double bottomInset}) {
    return Material(
      key: const ValueKey('assist-panel'),
      color: WoiColors.bg0,
      elevation: 12,
      shadowColor: WoiColors.shadow,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      child: MediaQuery.removeViewPadding(
        context: context,
        removeTop: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              key: const ValueKey('assist-handle'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => _onDragUpdate(d, screenH),
              onVerticalDragEnd: _onDragEnd,
              child: Column(
                children: [
                  SizedBox(
                    height: 18,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: WoiColors.strokeStrong,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  _header(),
                ],
              ),
            ),
            Expanded(child: _body()),
            Padding(
              padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + bottomInset),
              child: _footer(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Text('Woi', style: display(17, weight: FontWeight.w700, spacing: -0.4)),
          const Spacer(),
          ListenableBuilder(
            listenable: c.ready ? c.pipeline : c,
            builder: (context, _) => _thumbnail(),
          ),
          IconButton(
            key: const ValueKey('assist-open-app'),
            tooltip: 'Open full app',
            icon: Icon(Icons.open_in_full_rounded, size: 20, color: WoiColors.textDim),
            onPressed: widget.onOpenApp,
          ),
          IconButton(
            key: const ValueKey('assist-close'),
            tooltip: 'Close',
            icon: Icon(Icons.close_rounded, size: 22, color: WoiColors.textDim),
            onPressed: _dismiss,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// The newest screenshot in the conversation (normally the assist one).
  Widget _thumbnail() {
    if (!c.ready) return const SizedBox.shrink();
    final img = latestScreenshot(c.pipeline.conversation.messages);
    if (img == null) return const SizedBox.shrink();
    final ratio = img.height > 0 ? img.width / img.height : 0.5;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: 'Attached screenshot',
        child: InkWell(
          key: const ValueKey('assist-thumbnail'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => c.platform.viewer.show(MediaItem(kind: MediaKind.image, path: img.path, customTitle: 'Screenshot')),
          child: Container(
            height: 36,
            width: (36 * ratio).clamp(16.0, 64.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: WoiColors.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.file(
              File(img.path),
              fit: BoxFit.cover,
              cacheHeight: 108,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => ColoredBox(color: WoiColors.bg2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (!c.ready) return _centered(c.initError == null ? 'Starting Woi…' : 'Woi failed to start: ${c.initError}');
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.pipeline]),
      builder: (context, _) {
        if (c.needsLogin) return _centered('Sign in to Woi first: open the full app.');
        final msgs = c.pipeline.conversation.messages;
        if (msgs.isEmpty) return _centered('Ask about this screen, or anything else.');
        return LayoutBuilder(
          builder: (context, box) => ListView.builder(
            key: const ValueKey('assist-transcript'),
            reverse: true,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            itemCount: msgs.length,
            itemBuilder: (context, i) {
              final m = msgs[msgs.length - 1 - i];
              return MessageTile(
                key: ValueKey(m.id),
                message: m,
                audio: c.platform.audio,
                viewer: c.platform.viewer,
                maxBubbleWidth: box.maxWidth * 0.86,
              );
            },
          ),
        );
      },
    );
  }

  Widget _footer() {
    if (!c.ready) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.needsLogin) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EditReviewCard(review: c.review, maxDiffHeight: 120),
            InputBar(controller: c, phone: true),
          ],
        );
      },
    );
  }

  Widget _centered(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center, style: body(14, color: WoiColors.textDim)),
    ),
  );
}

/// The newest image attached to the conversation, if any.
ImageAttachment? latestScreenshot(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final img = messages[i].image;
    if (img != null) return img;
  }
  return null;
}

/// Shows [AssistPanel] as the top route while [visible] is true.
///
/// The route is opaque (the full app below it is not painted, so the window
/// shows the app underneath) and has no transition (an opaque route only
/// hides the ones below once its transition ends). Dialogs and the viewer
/// still open above it. [onShown] runs after the first frame with the panel.
class AssistPanelPresenter {
  AssistPanelPresenter({required this.navigatorKey, required this.visible, required this.builder, this.onShown});

  final GlobalKey<NavigatorState> navigatorKey;
  final ValueListenable<bool> visible;
  final WidgetBuilder builder;
  final VoidCallback? onShown;

  Route<void>? _route;
  bool _started = false;

  @visibleForTesting
  bool get showing => _route != null;

  void start() {
    if (_started) return;
    _started = true;
    visible.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (!_started) return;
    final nav = navigatorKey.currentState;
    if (visible.value && _route == null) {
      if (nav == null) {
        // The navigator is built in the next frame (cold start).
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      final route = PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'assist-panel'),
        opaque: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => builder(context),
      );
      _route = route;
      nav.push(route);
      WidgetsBinding.instance.endOfFrame.then((_) {
        if (_route == route) onShown?.call();
      });
    } else if (!visible.value && _route != null) {
      final route = _route!;
      _route = null;
      if (route.isActive) nav?.removeRoute(route);
    }
  }

  void dispose() {
    _started = false;
    visible.removeListener(_sync);
  }
}
