import 'dart:io';
import 'dart:ui' as ui;

String formatFileBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
  if (bytes < 1000000000) return '${(bytes / 1000000).toStringAsFixed(2)} MB';
  return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
}

String formatGenerationDuration(int milliseconds) {
  if (milliseconds < 60000) {
    return '${(milliseconds / 1000).toStringAsFixed(1)} s';
  }
  final minutes = milliseconds ~/ 60000;
  final seconds = (milliseconds % 60000) / 1000;
  return '$minutes min ${seconds.toStringAsFixed(1)} s';
}

class MediaMetadata {
  const MediaMetadata({required this.byteSize, this.width, this.height});
  final int byteSize;
  final int? width;
  final int? height;
  String get label => [
    if (width != null && height != null) '$width × $height px',
    formatFileBytes(byteSize),
  ].join(' · ');

  /// The encoded file size is read from the actual file. ImageDescriptor reads
  /// dimensions without creating a full-resolution decoded image in memory.
  static Future<MediaMetadata?> read(File file, {bool image = false}) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (!image) return MediaMetadata(byteSize: stat.size);
      ui.ImmutableBuffer? buffer;
      ui.ImageDescriptor? descriptor;
      try {
        buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        return MediaMetadata(
          byteSize: stat.size,
          width: descriptor.width,
          height: descriptor.height,
        );
      } catch (_) {
        return MediaMetadata(byteSize: stat.size);
      } finally {
        descriptor?.dispose();
        buffer?.dispose();
      }
    } catch (_) {
      return null;
    }
  }
}
