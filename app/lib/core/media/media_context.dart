import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../platform/camera.dart';
import '../../platform/media_grab.dart';
import '../../platform/media_viewer.dart';
import '../../platform/screen_capture.dart';
import 'audio_describer.dart';

export 'audio_describer.dart' show AudioDescriber;

/// An image given to the model as context that is not a screenshot (camera
/// frame, image or video frame from the viewer). Click coordinates never
/// refer to it.
class ContextImage {
  ContextImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.note,
    required this.kind,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();

  /// JPEG or PNG.
  final Uint8List bytes;
  final int width;
  final int height;

  /// Text sent next to the image.
  final String note;

  /// [ContextImageKind.camera] or [ContextImageKind.media].
  final String kind;
  final DateTime capturedAt;

  bool get isJpeg => bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

  factory ContextImage.camera(CameraFrame f, {String? when}) => ContextImage(
    bytes: f.jpeg,
    width: f.width,
    height: f.height,
    kind: ContextImageKind.camera,
    capturedAt: f.capturedAt,
    note:
        'Live camera frame (webcam: the user and their surroundings, not the screen)${when == null ? '' : ' $when'}. '
        'Do not use it for click coordinates.',
  );
}

abstract final class ContextImageKind {
  static const camera = 'camera';
  static const media = 'media';
}

/// "what's on my screen?", "what am I looking at", "describe the screen",
/// "what app is this", "read the screenshot": a question about the current
/// screenshot (assist gesture / screen share), which only a delegation can see.
bool isScreenQuestion(String text) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return false;
  return RegExp(
    r"\b(?:what'?s|whats|what\s+is|what\s+do\s+you\s+see|anything)\s+(?:on|in)\s+(?:my|the|this)\s+(?:screen|display|phone)\b|"
    r"\bwhat\s+(?:do|can)\s+you\s+see\b|\bwhat\s+am\s+i\s+(?:looking\s+at|seeing)\b|"
    r"\b(?:describe|read|explain|summari[sz]e|look\s+at|check)\s+(?:my|the|this)\s+(?:screen|screenshot|display)\b|"
    r"\bwhat\s+(?:app|application|screen|page|site|website)\s+(?:is\s+(?:this|that|open|shown|it)|am\s+i\s+(?:in|on|using))\b|"
    r"\b(?:in|on)\s+(?:the|my|this)\s+(?:screenshot|assist\s+screenshot)\b",
  ).hasMatch(t);
}

/// "what's in this image", "what is this song", "what are they saying",
/// "what's happening in the video now"... A question about the item open in
/// the viewer (only meaningful while one is open).
bool isMediaQuestion(String text) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return false;
  final asks =
      t.contains('?') ||
      RegExp(
        r"^(?:(?:ok(?:ay)?|hey|so|and|now|woi|please)[\s,]+)*"
        r"(?:what|what's|whats|who|who's|which|where|how|why|when|describe|explain|summari[sz]e|tell|identify|"
        r"transcribe|is|are|does|do|can you|could you)\b",
      ).hasMatch(t);
  if (!asks) return false;
  return RegExp(
    r"\b(?:this|the|that|current|open)\s+(?:image|picture|photo|pic|screenshot in the viewer|video|clip|movie|film|"
    r"frame|scene|song|track|music|tune|audio|recording|sound|podcast)\b|"
    r"\bwhat\s+(?:are\s+they|is\s+(?:he|she|it|this|that)|'?s\s+(?:he|she|it))\s+saying\b|"
    r"\b(?:what'?s|whats|what\s+is)\s+(?:happening|going\s+on|playing)\b|"
    r"\bin\s+the\s+(?:video|viewer|image|picture|photo|clip|song|audio)\b|"
    r"\bwhat\s+(?:song|track|music)\b|\bwho\s+is\s+(?:singing|speaking|talking)\b",
  ).hasMatch(t);
}

/// "open camera" → true, "close camera" → false, otherwise null.
bool? cameraCommand(String text) {
  final t = text.trim().toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '');
  final m = RegExp(
    r"^(?:(?:ok(?:ay)?|hey|woi|please|now|so|and|then|can you|could you)[\s,]+)*"
    r"(open|start|turn on|switch on|enable|activate|show|close|stop|turn off|switch off|disable|deactivate|hide)"
    r"\s+(?:the\s+|my\s+)?(?:camera|webcam|cam)(?:\s+(on|off))?(?:\s+please)?$",
  ).firstMatch(t);
  if (m == null) {
    final alt = RegExp(r"^(?:turn|switch)\s+(?:the\s+)?(?:camera|webcam)\s+(on|off)$").firstMatch(t);
    return alt == null ? null : alt.group(1) == 'on';
  }
  final verb = m.group(1)!;
  if (m.group(2) == 'off') return false;
  return const {'open', 'start', 'turn on', 'switch on', 'enable', 'activate', 'show'}.contains(verb);
}

/// What [MediaContextService.grab] found: an image for images and videos
/// (the current frame), text for audio (description/transcript) and text.
class MediaContext {
  MediaContext({required this.state, this.image, this.text, required this.summary});
  final ViewerState state;
  final ContextImage? image;

  /// Transcript / description (audio) or file excerpt (text).
  final String? text;

  /// One line for the tool result and the transcript.
  final String summary;

  Map<String, Object?> toToolResult() => {
    'ok': true,
    'kind': state.item.kind.name,
    'title': state.item.title,
    if (state.item.path != null) 'path': state.item.path,
    if (state.position != null) 'position': formatClock(state.position!),
    if (state.duration != null) 'duration': formatClock(state.duration!),
    if (state.item.kind == MediaKind.video || state.item.kind == MediaKind.audio) 'playing': state.playing,
    if (image != null) 'image': '${image!.width}x${image!.height} attached to the conversation',
    if (text != null) 'content': text,
    'summary': summary,
  };
}

String formatClock(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
}

/// Grabs the content of the item open in the viewer for the model.
class MediaContextService {
  MediaContextService({
    required this.viewer,
    required this.grabber,
    this.describeAudio,
    this.maxImageWidth = 1280,
    this.maxWholeAudio = const Duration(seconds: 90),
    this.audioBefore = const Duration(seconds: 20),
    this.audioAfter = const Duration(seconds: 10),
  });

  final MediaViewer viewer;
  final MediaGrabber grabber;
  final AudioDescriber? describeAudio;
  final int maxImageWidth;

  /// Audio up to this long is described whole; longer audio around the
  /// current position ([audioBefore] .. [audioAfter]).
  final Duration maxWholeAudio;
  final Duration audioBefore;
  final Duration audioAfter;

  /// The open item, or null when the viewer is closed.
  Future<ViewerState?> current() => viewer.state();

  /// Content of the open item; null when nothing is open.
  Future<MediaContext?> grab({String? question, ViewerState? state}) async {
    final s = state ?? await viewer.state();
    if (s == null) return null;
    final item = s.item;
    final path = item.path;
    switch (item.kind) {
      case MediaKind.image:
        if (path == null) throw MediaGrabException('the image has no file');
        final img = await _image(path);
        return MediaContext(
          state: s,
          image: ContextImage(
            bytes: img.$1,
            width: img.$2,
            height: img.$3,
            kind: ContextImageKind.media,
            note: 'Image "${item.title}" open in Woi\'s viewer (what the user asks about). Not the screen.',
          ),
          summary: 'Image ${item.title} (${img.$2}x${img.$3}) attached.',
        );
      case MediaKind.video:
        if (path == null) throw MediaGrabException('the video has no file');
        final at = s.position ?? Duration.zero;
        final jpeg = await grabber.videoFrame(path, at, maxWidth: maxImageWidth);
        final size = jpegSize(jpeg) ?? pngSize(jpeg) ?? (0, 0);
        final when = '${formatClock(at)}${s.duration == null ? '' : ' of ${formatClock(s.duration!)}'}';
        return MediaContext(
          state: s,
          image: ContextImage(
            bytes: jpeg,
            width: size.$1,
            height: size.$2,
            kind: ContextImageKind.media,
            note:
                'Current frame of the video "${item.title}" playing in Woi\'s viewer, at $when '
                '(${s.playing ? 'playing' : 'paused'}). Not the screen.',
          ),
          summary: 'Video frame at $when attached.',
        );
      case MediaKind.audio:
        if (path == null) throw MediaGrabException('the audio has no file');
        final d = s.duration ?? await grabber.duration(path);
        final pos = s.position ?? Duration.zero;
        var start = Duration.zero;
        var len = d ?? maxWholeAudio;
        if (d == null || d > maxWholeAudio) {
          start = pos - audioBefore;
          if (start < Duration.zero) start = Duration.zero;
          len = audioBefore + audioAfter;
        }
        final pcm = await grabber.audioPcm(path, start: start, length: len);
        final describe = describeAudio;
        if (describe == null) throw MediaGrabException('no audio describer available');
        final text = (await describe(pcm, title: item.title, question: question)).trim();
        final span = '${formatClock(start)}–${formatClock(start + Duration(milliseconds: pcm.length ~/ 48))}';
        return MediaContext(
          state: s,
          text: text,
          summary:
              'Audio "${item.title}" ($span${d == null ? '' : ' of ${formatClock(d)}'}, position ${formatClock(pos)}): $text',
        );
      case MediaKind.text:
        final body = item.text ?? (path == null ? '' : await _readText(path));
        final clipped = body.length > 6000 ? '${body.substring(0, 6000)}…' : body;
        return MediaContext(state: s, text: clipped, summary: 'Text "${item.title}" (${body.length} chars).');
    }
  }

  Future<String> _readText(String path) async {
    final f = File(path);
    final bytes = await f.openRead(0, 64 * 1024).fold<List<int>>([], (a, b) => a..addAll(b));
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Image bytes for the model: small PNG/JPEG files as they are, anything
  /// else (large, webp, gif, bmp) re-encoded to a ≤[maxImageWidth] JPEG.
  Future<(Uint8List, int, int)> _image(String path) async {
    final f = File(path);
    if (!await f.exists()) throw MediaGrabException('image not found: $path');
    final len = await f.length();
    if (len <= 4 << 20) {
      final b = await f.readAsBytes();
      final size = pngSize(b) ?? jpegSize(b);
      if (size != null && size.$1 <= maxImageWidth * 2) return (b, size.$1, size.$2);
    }
    final jpeg = await grabber.videoFrame(path, Duration.zero, maxWidth: maxImageWidth);
    final size = jpegSize(jpeg) ?? (0, 0);
    return (jpeg, size.$1, size.$2);
  }
}
