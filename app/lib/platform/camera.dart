import 'package:flutter/foundation.dart';

/// One camera frame as a JPEG (at most 1280 px wide).
class CameraFrame {
  const CameraFrame({required this.jpeg, required this.width, required this.height, required this.capturedAt});
  final Uint8List jpeg;
  final int width;
  final int height;
  final DateTime capturedAt;
}

/// Camera access (Linux: v4l2 through ffmpeg; Android later: CameraX).
///
/// While [active], [frames] carries the latest frame at a low rate (5–10 fps)
/// for the preview tile and for attaching to user turns. Nothing runs and the
/// device is free while off.
abstract class CameraService {
  /// Whether the camera is streaming.
  ValueListenable<bool> get active;

  /// Latest frame; null while off (or before the first frame).
  ValueListenable<CameraFrame?> get frames;

  /// Last open failure, for the UI and the tool result.
  String? get lastError;

  /// Starts streaming. Throws [CameraException] when the device cannot be
  /// opened. Opening an open camera does nothing.
  Future<void> open();

  /// Stops streaming and releases the device.
  Future<void> close();

  /// The newest frame if it is not older than [maxAge] (stale frames mean
  /// the stream stalled).
  CameraFrame? latest({Duration maxAge = const Duration(seconds: 5)}) {
    final f = frames.value;
    if (f == null || !active.value) return null;
    return DateTime.now().difference(f.capturedAt) > maxAge ? null : f;
  }

  /// Waits up to [timeout] for a frame (right after [open]).
  Future<CameraFrame?> nextFrame({Duration timeout = const Duration(seconds: 4)}) async {
    final now = latest();
    if (now != null) return now;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline) && active.value) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final f = latest();
      if (f != null) return f;
    }
    return latest();
  }
}

class CameraException implements Exception {
  CameraException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Platforms without a camera.
class NoCameraService extends CameraService {
  NoCameraService();
  final _active = ValueNotifier(false);
  final _frames = ValueNotifier<CameraFrame?>(null);
  @override
  ValueListenable<bool> get active => _active;
  @override
  ValueListenable<CameraFrame?> get frames => _frames;
  @override
  String? get lastError => 'no camera on this platform';
  @override
  Future<void> open() async => throw CameraException('No camera available on this platform');
  @override
  Future<void> close() async {}
}

/// Width/height from a JPEG's SOF marker; null if not a parsable JPEG.
(int, int)? jpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) return null;
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC).
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w, h);
    }
    if (m == 0xDA) return null; // scan data before any SOF
    i += 2 + len;
  }
  return null;
}

/// Splits a byte stream of concatenated JPEGs (ffmpeg `image2pipe`) into
/// frames. Walks the marker segments (so an embedded thumbnail's EOI does not
/// end a frame) and scans the entropy-coded data for the EOI marker.
/// Incremental: bytes already scanned are not rescanned.
class JpegStreamSplitter {
  JpegStreamSplitter({this.maxFrameBytes = 8 << 20});

  final int maxFrameBytes;
  Uint8List _buf = Uint8List(256 * 1024);
  int _len = 0;

  // Parse state for the frame starting at 0.
  int _pos = 0;
  bool _inScan = false;

  /// Appends [chunk]; returns the frames completed by it (oldest first).
  List<Uint8List> add(List<int> chunk) {
    _ensure(_len + chunk.length);
    _buf.setRange(_len, _len + chunk.length, chunk);
    _len += chunk.length;
    final out = <Uint8List>[];
    while (true) {
      final end = _scan();
      if (end == null) break;
      out.add(Uint8List.fromList(Uint8List.sublistView(_buf, 0, end)));
      _consume(end);
    }
    if (_len > maxFrameBytes) {
      // Garbage or a runaway frame: resync on the next SOI.
      final soi = _findSoi(1);
      _consume(soi ?? _len);
    }
    return out;
  }

  void _ensure(int n) {
    if (n <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < n) {
      cap *= 2;
    }
    _buf = Uint8List(cap)..setRange(0, _len, _buf);
  }

  void _consume(int n) {
    _buf.setRange(0, _len - n, _buf, n);
    _len -= n;
    _pos = 0;
    _inScan = false;
  }

  int? _findSoi(int from) {
    for (var i = from; i + 1 < _len; i++) {
      if (_buf[i] == 0xFF && _buf[i + 1] == 0xD8) return i;
    }
    return null;
  }

  /// End offset (exclusive) of a complete frame at 0, or null.
  int? _scan() {
    final b = _buf;
    if (_pos == 0) {
      if (_len < 2) return null;
      if (b[0] != 0xFF || b[1] != 0xD8) {
        final soi = _findSoi(0);
        _consume(soi ?? (_len > 0 && b[_len - 1] == 0xFF ? _len - 1 : _len));
        if (_len < 2) return null;
      }
      _pos = 2;
    }
    while (true) {
      if (!_inScan) {
        if (_pos + 4 > _len) return null;
        if (b[_pos] != 0xFF) {
          // Corrupt header: drop this frame.
          final soi = _findSoi(1);
          _consume(soi ?? _len);
          return null;
        }
        final m = b[_pos + 1];
        if (m == 0xFF) {
          _pos++;
          continue;
        }
        if (m == 0xD9) return _pos + 2;
        if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
          _pos += 2;
          continue;
        }
        final len = (b[_pos + 2] << 8) | b[_pos + 3];
        if (_pos + 2 + len > _len) return null;
        _pos += 2 + len;
        if (m == 0xDA) _inScan = true;
        continue;
      }
      // Entropy-coded data: FF 00 is a stuffed byte, FF D0-D7 restart
      // markers; any other marker ends the scan.
      var i = _pos;
      final n = _len - 1;
      while (i < n) {
        if (b[i] == 0xFF) {
          final m = b[i + 1];
          if (m == 0x00 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
            i += m == 0xFF ? 1 : 2;
            continue;
          }
          break;
        }
        i++;
      }
      if (i >= n) {
        _pos = i;
        return null;
      }
      _pos = i;
      _inScan = false; // the marker at _pos is handled above (EOI or another segment)
    }
  }
}
