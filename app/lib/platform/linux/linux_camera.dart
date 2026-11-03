import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../camera.dart';

/// V4L2 camera through ffmpeg. The camera's own MJPEG stream is copied
/// without decoding (`-c:v copy`), thinned to [fps] with the `noise` bitstream
/// filter and made self-contained with `mjpeg2jpeg` (webcam MJPEG omits the
/// Huffman tables). ffmpeg therefore costs close to nothing; the UI decodes
/// only the preview at [previewWidth]. Devices without MJPEG fall back to
/// YUYV at 640x480, encoded to JPEG by ffmpeg.
class LinuxCameraService extends CameraService {
  LinuxCameraService({
    this.device = '/dev/video0',
    this.width = 1280,
    this.height = 720,
    this.sourceFps = 30,
    this.fps = 6,
    this.ffmpeg = 'ffmpeg',
  });

  final String device;
  final int width;
  final int height;

  /// Frame rate the device delivers (MJPEG 1280x720 is 30 fps on most webcams).
  final int sourceFps;

  /// Frames kept per second.
  final int fps;
  final String ffmpeg;

  final _active = ValueNotifier(false);
  final _frames = ValueNotifier<CameraFrame?>(null);
  Process? _proc;
  StreamSubscription<List<int>>? _out;
  String? _error;
  Future<void>? _opening;
  int _gen = 0;

  @override
  ValueListenable<bool> get active => _active;
  @override
  ValueListenable<CameraFrame?> get frames => _frames;
  @override
  String? get lastError => _error;

  /// ffmpeg arguments for the MJPEG copy path.
  @visibleForTesting
  List<String> mjpegArgs() {
    final keepEvery = (sourceFps / fps).round().clamp(1, 30);
    return [
      '-hide_banner', '-loglevel', 'error', '-nostdin', //
      '-f', 'v4l2', '-input_format', 'mjpeg', '-video_size', '${width}x$height', '-framerate', '$sourceFps',
      '-i', device, '-an', '-c:v', 'copy',
      '-bsf:v', keepEvery > 1 ? 'noise=drop=mod(n\\,$keepEvery),mjpeg2jpeg' : 'mjpeg2jpeg',
      '-f', 'image2pipe', 'pipe:1',
    ];
  }

  /// Fallback: raw YUYV at 640x480 encoded to JPEG at [fps].
  @visibleForTesting
  List<String> yuyvArgs() => [
    '-hide_banner', '-loglevel', 'error', '-nostdin', //
    '-f', 'v4l2', '-input_format', 'yuyv422', '-video_size', '640x480',
    '-i', device, '-an', '-vf', 'fps=$fps', '-c:v', 'mjpeg', '-q:v', '5',
    '-f', 'image2pipe', 'pipe:1',
  ];

  @override
  Future<void> open() => _opening ??= _open().whenComplete(() => _opening = null);

  Future<void> _open() async {
    if (_proc != null) return;
    if (!File(device).existsSync()) {
      _error = 'No camera at $device';
      throw CameraException(_error!);
    }
    _error = null;
    for (final args in [mjpegArgs(), yuyvArgs()]) {
      if (await _start(args)) return;
    }
    throw CameraException(_error ?? 'Camera $device did not deliver frames');
  }

  /// Starts ffmpeg; true once the first frame arrived.
  Future<bool> _start(List<String> args) async {
    final gen = ++_gen;
    final Process p;
    try {
      p = await Process.start(ffmpeg, args);
    } catch (e) {
      _error = 'ffmpeg not available: $e';
      return false;
    }
    _proc = p;
    final first = Completer<bool>();
    final splitter = JpegStreamSplitter();
    final stderr = StringBuffer();
    p.stderr.transform(utf8.decoder).listen((s) {
      if (stderr.length < 2000) stderr.write(s);
    });
    _out = p.stdout.listen((chunk) {
      final got = splitter.add(chunk);
      if (got.isEmpty || gen != _gen) return;
      final jpeg = got.last;
      final size = jpegSize(jpeg) ?? (width, height);
      _frames.value = CameraFrame(jpeg: jpeg, width: size.$1, height: size.$2, capturedAt: DateTime.now());
      if (!first.isCompleted) {
        _active.value = true;
        first.complete(true);
      }
    });
    unawaited(
      p.exitCode.then((code) {
        if (gen != _gen) return;
        final msg = stderr.toString().trim();
        if (!first.isCompleted) {
          _error = msg.isEmpty ? 'camera stream ended (ffmpeg exit $code)' : msg.split('\n').last;
          first.complete(false);
        } else if (_proc == p) {
          debugPrint('camera stream ended (exit $code) $msg');
        }
        if (_proc == p) _release();
      }),
    );
    final ok = await first.future.timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!ok) {
      _error ??= 'Camera $device did not deliver frames';
      if (_proc == p) {
        p.kill();
        _release();
      }
    }
    return ok;
  }

  void _release() {
    _gen++;
    _out?.cancel();
    _out = null;
    _proc = null;
    _active.value = false;
    _frames.value = null;
  }

  @override
  Future<void> close() async {
    await _opening?.catchError((Object _) {});
    final p = _proc;
    if (p == null) return;
    _release();
    p.kill(ProcessSignal.sigterm);
    // ffmpeg exits at once on SIGTERM; make sure the device is free.
    final code = await p.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
    debugPrint('camera closed (ffmpeg exit $code)');
  }
}
