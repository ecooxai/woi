import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../platform/camera.dart';
import '../theme.dart';

/// Small live camera tile. Decodes each frame at [decodeWidth] px (the JPEG
/// decoder scales while decoding, so a 1280x720 frame costs a fraction of a
/// full decode), drops frames while a decode is in flight, and disposes the
/// previous image. Builds nothing and listens to nothing while the camera is
/// off.
class CameraPreviewTile extends StatefulWidget {
  const CameraPreviewTile({super.key, required this.camera, this.width = 176, this.decodeWidth = 320, this.onClose});
  final CameraService camera;
  final double width;
  final int decodeWidth;
  final VoidCallback? onClose;

  @override
  State<CameraPreviewTile> createState() => _CameraPreviewTileState();
}

class _CameraPreviewTileState extends State<CameraPreviewTile> {
  ui.Image? _image;
  bool _decoding = false;
  CameraFrame? _pending;

  /// Frames decoded (tests/diagnostics).
  int decoded = 0;

  @override
  void initState() {
    super.initState();
    widget.camera.frames.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(CameraPreviewTile old) {
    super.didUpdateWidget(old);
    if (old.camera != widget.camera) {
      old.camera.frames.removeListener(_onFrame);
      widget.camera.frames.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    widget.camera.frames.removeListener(_onFrame);
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _onFrame() {
    final f = widget.camera.frames.value;
    if (f == null) {
      if (_image != null) {
        _image!.dispose();
        setState(() => _image = null);
      }
      return;
    }
    _pending = f;
    if (!_decoding) unawaited(_decodeLoop());
  }

  Future<void> _decodeLoop() async {
    _decoding = true;
    try {
      while (_pending != null && mounted) {
        final f = _pending!;
        _pending = null;
        try {
          final codec = await ui.instantiateImageCodec(f.jpeg, targetWidth: widget.decodeWidth);
          final frame = await codec.getNextFrame();
          codec.dispose();
          if (!mounted) {
            frame.image.dispose();
            return;
          }
          final old = _image;
          setState(() => _image = frame.image);
          old?.dispose();
          decoded++;
        } catch (e) {
          debugPrint('camera preview decode failed: $e');
        }
      }
    } finally {
      _decoding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final aspect = img == null ? 16 / 9 : img.width / img.height;
    return Semantics(
      label: 'Camera preview',
      image: true,
      child: SizedBox(
        width: widget.width,
        child: AspectRatio(
          aspectRatio: aspect,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: WoiColors.strokeStrong),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (img == null)
                      const Center(
                        child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    else
                      RawImage(image: img, fit: BoxFit.cover, filterQuality: FilterQuality.low),
                    const Positioned(
                      left: 6,
                      top: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                        child: SizedBox.square(dimension: 7),
                      ),
                    ),
                    if (widget.onClose != null)
                      Positioned(
                        right: 2,
                        top: 2,
                        child: IconButton(
                          key: const ValueKey('camera-preview-close'),
                          tooltip: 'Close camera',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          color: Colors.white,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Input-bar camera toggle.
class CameraToggle extends StatelessWidget {
  const CameraToggle({
    super.key,
    required this.on,
    required this.busy,
    required this.onPressed,
    this.pending = false,
    this.size = 28,
    this.visualSize,
  });
  final bool on;
  final bool busy;
  final bool pending;
  final VoidCallback onPressed;
  final double size;
  final double? visualSize;

  @override
  Widget build(BuildContext context) {
    final discSize = visualSize ?? size;
    final background = on ? const Color(0xFF27824F) : const Color(0xFFDFF3E5);
    final foreground = on ? Colors.white : const Color(0xFF32704A);
    return Semantics(
      button: true,
      toggled: on,
      enabled: !busy || pending,
      label: pending
          ? 'Cancel camera request'
          : on
          ? 'Close camera'
          : 'Open camera',
      child: Tooltip(
        message: pending
            ? 'Cancel camera request'
            : on
            ? 'Close camera'
            : 'Open camera (frames go with every turn)',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            key: const ValueKey('camera-toggle'),
            onTap: busy && !pending ? null : onPressed,
            radius: size / 2,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: size,
              child: Center(
                child: AnimatedContainer(
                  duration: WoiMotion.fast,
                  width: discSize,
                  height: discSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: background,
                    border: Border.all(color: foreground.withValues(alpha: on ? 0.0 : 0.16)),
                  ),
                  child: Center(
                    child: busy
                        ? SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                          )
                        : Icon(
                            on ? Icons.videocam_rounded : Icons.videocam_outlined,
                            size: discSize * 0.52,
                            color: foreground,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
