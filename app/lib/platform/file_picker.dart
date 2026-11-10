import 'package:flutter/services.dart';

import 'android/android_bridge.dart';

const maxPickedFileBytes = 20 * 1024 * 1024;
const maxPickedFilesBytes = 32 * 1024 * 1024;
const maxPickedFiles = 8;

/// Bytes are app-owned so Android provider permissions may safely expire.
class PickedFile {
  const PickedFile({required this.bytes, required this.name, required this.mimeType});
  final Uint8List bytes;
  final String name;
  final String mimeType;
  bool get isImage => mimeType.startsWith('image/');
}

abstract interface class FilePicker {
  Future<List<PickedFile>> pickFiles();
}

class NativeFilePicker implements FilePicker {
  const NativeFilePicker({this.androidBridge});
  final AndroidBridge? androidBridge;
  static const _channel = MethodChannel('woi/files');

  @override
  Future<List<PickedFile>> pickFiles() async {
    final Object? value = androidBridge == null
        ? await _channel.invokeMethod<Object?>('pickFiles')
        : await androidBridge!.call<Object?>('pickFiles');
    if (value == null) return const [];
    if (value is! List) throw StateError('The file browser returned an invalid selection');
    final files = <PickedFile>[];
    var total = 0;
    for (final raw in value) {
      if (raw is! Map || raw['bytes'] is! Uint8List || raw['name'] is! String) {
        throw StateError('The file browser returned an unreadable file');
      }
      final bytes = raw['bytes'] as Uint8List;
      if (bytes.length > maxPickedFileBytes) throw StateError('Each attachment must be 20 MB or smaller');
      total += bytes.length;
      files.add(
        PickedFile(
          bytes: bytes,
          name: raw['name'] as String,
          mimeType: raw['mimeType'] as String? ?? 'application/octet-stream',
        ),
      );
    }
    if (files.length > maxPickedFiles) throw StateError('Choose up to 8 files at a time');
    if (total > maxPickedFilesBytes) throw StateError('Attachments must total 32 MB or less');
    return files;
  }
}
