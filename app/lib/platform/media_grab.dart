import 'dart:typed_data';

/// Pulls context out of media files for the model: a video frame at a
/// position, or an audio clip as PCM16. Linux: ffmpeg. Android later: fvp
/// snapshot / MediaExtractor.
abstract class MediaGrabber {
  /// JPEG of the frame at [at], at most [maxWidth] px wide.
  Future<Uint8List> videoFrame(String path, Duration at, {int maxWidth = 1280});

  /// Mono PCM16 at [sampleRate] Hz of [length] starting at [start].
  Future<Uint8List> audioPcm(
    String path, {
    Duration start = Duration.zero,
    required Duration length,
    int sampleRate = 24000,
  });

  /// Media duration, null when unknown.
  Future<Duration?> duration(String path);
}

class MediaGrabException implements Exception {
  MediaGrabException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Platforms without a grabber.
class NoMediaGrabber implements MediaGrabber {
  const NoMediaGrabber();
  @override
  Future<Uint8List> videoFrame(String path, Duration at, {int maxWidth = 1280}) =>
      throw MediaGrabException('video frames are not supported on this platform');
  @override
  Future<Uint8List> audioPcm(
    String path, {
    Duration start = Duration.zero,
    required Duration length,
    int sampleRate = 24000,
  }) => throw MediaGrabException('audio clips are not supported on this platform');
  @override
  Future<Duration?> duration(String path) async => null;
}
