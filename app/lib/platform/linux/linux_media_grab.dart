import 'dart:io';
import 'dart:typed_data';

import '../media_grab.dart';

/// ffmpeg / ffprobe based [MediaGrabber].
class FfmpegMediaGrabber implements MediaGrabber {
  const FfmpegMediaGrabber({this.ffmpeg = 'ffmpeg', this.ffprobe = 'ffprobe'});
  final String ffmpeg;
  final String ffprobe;

  static String seconds(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);

  Future<Uint8List> _run(List<String> args) async {
    final r = await Process.run(ffmpeg, args, stdoutEncoding: null).timeout(const Duration(seconds: 20));
    final out = r.stdout as List<int>;
    if (r.exitCode != 0 || out.isEmpty) {
      final err = '${r.stderr}'.trim().split('\n').last;
      throw MediaGrabException('ffmpeg failed (${r.exitCode}): $err');
    }
    return Uint8List.fromList(out);
  }

  @override
  Future<Uint8List> videoFrame(String path, Duration at, {int maxWidth = 1280}) => _run([
    '-hide_banner', '-loglevel', 'error', '-nostdin', //
    '-ss', seconds(at), '-i', path, '-frames:v', '1', '-an',
    '-vf', "scale='min($maxWidth,iw)':-2", '-q:v', '3', '-f', 'image2', '-c:v', 'mjpeg', 'pipe:1',
  ]);

  @override
  Future<Uint8List> audioPcm(
    String path, {
    Duration start = Duration.zero,
    required Duration length,
    int sampleRate = 24000,
  }) => _run([
    '-hide_banner', '-loglevel', 'error', '-nostdin', //
    '-ss', seconds(start), '-t', seconds(length), '-i', path, '-vn',
    '-ac', '1', '-ar', '$sampleRate', '-f', 's16le', 'pipe:1',
  ]);

  @override
  Future<Duration?> duration(String path) async {
    try {
      final r = await Process.run(ffprobe, [
        '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', path, //
      ]).timeout(const Duration(seconds: 10));
      final s = double.tryParse('${r.stdout}'.trim());
      return s == null ? null : Duration(microseconds: (s * 1e6).round());
    } catch (_) {
      return null;
    }
  }
}
