import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'glass.dart';
import 'message_tile.dart' show ClickMarker;

/// Full-window zoomable image (tap a screenshot thumbnail).
/// [marker] is a fractional (0..1) position drawn as a click target.
Future<void> showImageLightbox(
  BuildContext context,
  String path, {
  String? caption,
  Offset? marker,
  VoidCallback? onOpenWindow,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.86),
    transitionDuration: WoiMotion.medium,
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: a, curve: WoiMotion.emphasized)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) => ZoomableImage(
      file: File(path),
      caption: caption,
      marker: marker,
      onOpenWindow: onOpenWindow,
      onClose: () => Navigator.of(context).pop(),
    ),
  );
}

/// Pan/zoom image with a control cluster (zoom in/out, fit, 1:1) and
/// keyboard: +/- zoom, 0 fit, Esc close.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.file,
    this.caption,
    this.marker,
    this.onOpenWindow,
    this.onClose,
  });
  final File file;
  final String? caption;
  final Offset? marker;
  final VoidCallback? onOpenWindow;
  final VoidCallback? onClose;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  final _ctl = TransformationController();
  Size _viewport = Size.zero;
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(() {
      final s = _ctl.value.getMaxScaleOnAxis();
      if ((s - _scale).abs() > 0.005) setState(() => _scale = s);
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _zoomBy(double f) {
    final next = (_scale * f).clamp(1.0, 8.0);
    final c = _viewport.center(Offset.zero);
    final focal = _ctl.toScene(c);
    final ratio = next / _scale;
    final m = _ctl.value.clone()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _ctl.value = m;
  }

  void _fit() => _ctl.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    final close = widget.onClose;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.equal): () => _zoomBy(1.4),
        const SingleActivator(LogicalKeyboardKey.equal, shift: true): () => _zoomBy(1.4),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): () => _zoomBy(1.4),
        const SingleActivator(LogicalKeyboardKey.minus): () => _zoomBy(1 / 1.4),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): () => _zoomBy(1 / 1.4),
        const SingleActivator(LogicalKeyboardKey.digit0): _fit,
        const SingleActivator(LogicalKeyboardKey.escape): ?close,
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              _viewport = box.biggest;
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onDoubleTap: () => _scale > 1.05 ? _fit() : _zoomBy(2.5),
                      child: InteractiveViewer(
                        transformationController: _ctl,
                        maxScale: 8,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: _ImageWithMarker(file: widget.file, marker: widget.marker),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: GlassPanel(
                      radius: 18,
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GlassIconButton(icon: Icons.remove, tooltip: 'Zoom out (−)', onPressed: () => _zoomBy(1 / 1.4)),
                          SizedBox(
                            width: 52,
                            child: Text(
                              '${(_scale * 100).round()}%',
                              textAlign: TextAlign.center,
                              style: mono(12, color: WoiColors.textDim).copyWith(fontFeatures: kTabular),
                            ),
                          ),
                          GlassIconButton(icon: Icons.add, tooltip: 'Zoom in (+)', onPressed: () => _zoomBy(1.4)),
                          GlassIconButton(icon: Icons.fit_screen, tooltip: 'Fit (0)', onPressed: _fit),
                          if (widget.onOpenWindow != null)
                            GlassIconButton(
                              icon: Icons.open_in_new,
                              tooltip: 'Open in window',
                              onPressed: () {
                                close?.call();
                                widget.onOpenWindow!();
                              },
                            ),
                          if (close != null) GlassIconButton(icon: Icons.close, tooltip: 'Close (Esc)', onPressed: close),
                        ],
                      ),
                    ),
                  ),
                  if (widget.caption != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: Center(
                        child: GlassPanel(
                          radius: 99,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          child: Text(widget.caption!, style: body(12.5, color: WoiColors.textDim)),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ImageWithMarker extends StatelessWidget {
  const _ImageWithMarker({required this.file, this.marker});
  final File file;
  final Offset? marker;

  @override
  Widget build(BuildContext context) {
    final img = Image.file(
      file,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, e, s) => const Icon(Icons.broken_image_outlined, size: 48),
    );
    final mk = marker;
    if (mk == null) return img;
    return Stack(
      children: [
        img,
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, box) =>
                ClickMarker(position: Offset(mk.dx * box.maxWidth, mk.dy * box.maxHeight), size: 34),
          ),
        ),
      ],
    );
  }
}
