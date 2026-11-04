import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// Image cache budget for the main window. Thumbnails are decoded at
/// `cacheWidth` (≤640 px, ~1.6 MB each), the camera preview bypasses the
/// cache, so 40 MB holds every visible image with room to scroll back; the
/// default (100 MB / 1000 images) let a long history pin ~100 MB.
const kMainImageCacheBytes = 40 << 20;
const kMainImageCacheCount = 150;

/// The viewer window shows one image at a time (full resolution).
const kViewerImageCacheBytes = 64 << 20;
const kViewerImageCacheCount = 8;

void configureImageCache({int maxBytes = kMainImageCacheBytes, int maxCount = kMainImageCacheCount}) {
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = maxBytes
    ..maximumSize = maxCount;
}

/// Largest texture worth decoding video into: the display size (a 4K video
/// on a 1080p screen never needs more), or 1920x1080 when unknown.
(int, int) videoTextureLimit([Iterable<Display>? displays]) {
  var w = 0, h = 0;
  for (final d in displays ?? PlatformDispatcher.instance.displays) {
    final s = d.size;
    if (s.width > w) w = s.width.round();
    if (s.height > h) h = s.height.round();
  }
  if (w < 640 || h < 360) return (1920, 1080);
  return (w, h);
}

/// libmdk video decoders for this session, or null for fvp's default
/// (hardware first: VAAPI, CUDA, VDPAU, then FFmpeg).
///
/// Hardware frames reach the screen through GL interop (VA-API surface ->
/// EGL image), which needs a direct-rendering X server. Without DRI3
/// (Xephyr / Xvfb / VNC, software GL) the VAAPI decoder still opens through
/// the DRM render node but every frame fails to map ("invalid VADisplay",
/// "map native buffer ... error"), so the video stays black. The runner sets
/// `WOI_SOFTWARE_GL=1` when the display has no DRI3; then decoding stays on
/// the CPU (FFmpeg, frames uploaded as plain textures).
/// `WOI_VIDEO_DECODERS=FFmpeg,dav1d` overrides either way.
List<String>? videoDecoders([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  final custom = e['WOI_VIDEO_DECODERS']?.split(',').map((d) => d.trim()).where((d) => d.isNotEmpty).toList();
  if (custom != null && custom.isNotEmpty) return custom;
  if (e['WOI_SOFTWARE_GL'] == '1' || e['LIBGL_ALWAYS_SOFTWARE'] == '1') return const ['FFmpeg', 'dav1d'];
  return null;
}

/// `WOI_FRAME_STATS=1`: logs frame count and build/raster time every 10 s
/// (perf work in release builds, where DevTools is not available).
void maybeLogFrameStats(String tag) {
  if (Platform.environment['WOI_FRAME_STATS'] == null) return;
  var frames = 0;
  var build = Duration.zero, raster = Duration.zero, worst = Duration.zero;
  var since = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      frames++;
      build += t.buildDuration;
      raster += t.rasterDuration;
      if (t.totalSpan > worst) worst = t.totalSpan;
    }
    final now = DateTime.now();
    if (now.difference(since) < const Duration(seconds: 10)) return;
    final n = frames == 0 ? 1 : frames;
    debugPrint(
      'frames[$tag] ${frames}f/${now.difference(since).inSeconds}s '
      'build ${(build.inMicroseconds / n / 1000).toStringAsFixed(1)}ms '
      'raster ${(raster.inMicroseconds / n / 1000).toStringAsFixed(1)}ms '
      'worst ${worst.inMilliseconds}ms',
    );
    frames = 0;
    build = raster = worst = Duration.zero;
    since = now;
  });
}
