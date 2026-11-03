import 'package:path/path.dart' as p;

enum MediaKind { image, audio, video, text }

class MediaItem {
  const MediaItem({required this.kind, this.path, this.text, this.customTitle, this.language});

  final MediaKind kind;
  final String? path;

  /// Inline text when there is no file.
  final String? text;
  final String? language;
  final String? customTitle;

  String get title => customTitle ?? (path != null ? p.basename(path!) : kind.name);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (path != null) 'path': path,
    if (text != null) 'text': text,
    'title': title,
    if (language != null) 'language': language,
  };

  factory MediaItem.fromJson(Map<String, Object?> j) => MediaItem(
    kind: MediaKind.values.asNameMap()[j['kind']] ?? MediaKind.text,
    path: j['path'] as String?,
    text: j['text'] as String?,
    customTitle: j['title'] as String?,
    language: j['language'] as String?,
  );

  static const _image = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};
  static const _audio = {'.wav', '.mp3', '.ogg', '.oga', '.flac', '.m4a', '.opus'};
  static const _video = {'.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v'};

  static MediaKind kindForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    if (_image.contains(ext)) return MediaKind.image;
    if (_audio.contains(ext)) return MediaKind.audio;
    if (_video.contains(ext)) return MediaKind.video;
    return MediaKind.text;
  }
}

/// How an item ended up being shown.
enum ViewerSurface { window, overlay }

/// Presents an item inside the main window (fallback surface).
typedef OverlayPresenter = Future<void> Function(MediaItem item);

/// Voice/tool control of the open viewer.
enum ViewerCommand { close, pause, play, seekBy, seekTo }

abstract class MediaViewer {
  /// Installed by the UI so the viewer can fall back to an in-app overlay.
  OverlayPresenter? overlayPresenter;

  Future<ViewerSurface> show(MediaItem item);

  /// Controls the open viewer ([seconds] for seekBy / seekTo). Returns false
  /// when no viewer is open or it cannot do that (e.g. pause on an image).
  Future<bool> control(ViewerCommand command, {double seconds = 0}) async => false;

  /// What the viewer shows right now (null when it is closed), with the
  /// playing position for audio/video. The default knows nothing.
  Future<ViewerState?> state() async => null;
}

/// The item open in the viewer and, for audio/video, where playback is.
class ViewerState {
  const ViewerState({required this.item, this.position, this.duration, this.playing = false});
  final MediaItem item;
  final Duration? position;
  final Duration? duration;
  final bool playing;

  Map<String, Object?> toJson() => {
    'item': item.toJson(),
    if (position != null) 'positionMs': position!.inMilliseconds,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    'playing': playing,
  };

  static ViewerState? fromJson(Object? j) {
    if (j is! Map || j['item'] is! Map) return null;
    Duration? ms(Object? v) => v is num ? Duration(milliseconds: v.toInt()) : null;
    return ViewerState(
      item: MediaItem.fromJson((j['item'] as Map).cast()),
      position: ms(j['positionMs']),
      duration: ms(j['durationMs']),
      playing: j['playing'] == true,
    );
  }
}

/// Playback position source, registered by the video/audio body that is
/// playing in this engine (the viewer window or the in-app overlay).
abstract class PlaybackProbe {
  Duration get position;
  Duration? get duration;
  bool get playing;
}

/// The probe of the player currently on screen in this engine.
PlaybackProbe? activePlayback;
