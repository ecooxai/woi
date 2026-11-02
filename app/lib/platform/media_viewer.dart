import 'package:path/path.dart' as p;

enum MediaKind { image, audio, video, text }

class MediaItem {
  const MediaItem({
    required this.kind,
    this.path,
    this.text,
    this.customTitle,
    this.language,
  });

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
enum ViewerSurface { window, overlay, external }

/// Presents an item inside the main window (fallback surface).
typedef OverlayPresenter = Future<void> Function(MediaItem item);

abstract class MediaViewer {
  /// Installed by the UI so the viewer can fall back to an in-app overlay.
  OverlayPresenter? overlayPresenter;

  Future<ViewerSurface> show(MediaItem item);
}
