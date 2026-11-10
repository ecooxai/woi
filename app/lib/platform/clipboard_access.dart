import 'dart:async';

import 'package:flutter/services.dart';

/// Clipboard image data is copied into app-owned memory before a provider's
/// temporary URI grant can expire. History and paste never depend on that URI.
class ClipboardImage {
  const ClipboardImage({required this.bytes, this.mimeType = 'image/png', this.name = 'clipboard.png'});
  final Uint8List bytes;
  final String mimeType;
  final String name;

  Map<String, Object?> toMap() => {'bytes': bytes, 'mimeType': mimeType, 'name': name};
}

class ClipboardContent {
  const ClipboardContent({this.text, this.image});
  final String? text;
  final ClipboardImage? image;
  bool get isEmpty => (text == null || text!.isEmpty) && image == null;

  Map<String, Object?> toMap() => {'text': text, if (image != null) 'image': image!.toMap()};

  static ClipboardContent? fromMap(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw StateError('The system returned invalid clipboard content');
    final text = value['text'];
    if (text != null && text is! String) throw StateError('The clipboard text is invalid');
    ClipboardImage? image;
    final raw = value['image'];
    if (raw != null) {
      if (raw is! Map || raw['bytes'] is! Uint8List || (raw['bytes'] as Uint8List).isEmpty) {
        throw StateError('The clipboard image is invalid');
      }
      image = ClipboardImage(
        bytes: raw['bytes'] as Uint8List,
        mimeType: raw['mimeType'] as String? ?? 'image/png',
        name: raw['name'] as String? ?? 'clipboard.png',
      );
    }
    final result = ClipboardContent(text: text as String?, image: image);
    return result.isEmpty ? null : result;
  }
}

/// Explicit text clipboard access. Reading is never part of input preparation.
abstract interface class ClipboardAccess {
  Future<String?> readText();
  Future<void> writeText(String text);
}

/// Optional rich capability keeps existing text adapters and test doubles valid.
/// Passive reads (`allowFocus: false`) may return null for unchanged content.
/// Explicit reads always request the current system clipboard.
abstract interface class RichClipboardAccess {
  Future<ClipboardContent?> readContent({bool allowFocus = true});
  Future<void> writeContent(ClipboardContent content);
}

/// Optional native change notifications. Events contain no clipboard data;
/// consumers read immediately and keep a bounded local snapshot. Desktop
/// adapters explicitly opt in to reads while the window is hidden.
abstract interface class ClipboardChangeEvents {
  Stream<void> get changes;
  bool get supportsBackgroundCapture;
}

extension ClipboardContentAccess on ClipboardAccess {
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async {
    final source = this;
    if (source is RichClipboardAccess) return (source as RichClipboardAccess).readContent(allowFocus: allowFocus);
    final text = await readText();
    return text == null || text.isEmpty ? null : ClipboardContent(text: text);
  }

  Future<void> writeContent(ClipboardContent content) async {
    final source = this;
    if (source is RichClipboardAccess) return (source as RichClipboardAccess).writeContent(content);
    if (content.image != null) throw UnsupportedError('Image clipboard access is unavailable on this device');
    await writeText(content.text ?? '');
  }
}

/// The Linux runner supplies GTK image data; text-only hosts retain Flutter's
/// standard clipboard. Android uses its focused bridge for both formats.
class SystemClipboardAccess implements ClipboardAccess, RichClipboardAccess {
  const SystemClipboardAccess();
  static const _channel = MethodChannel('woi/clipboard');

  @override
  Future<String?> readText() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> writeText(String text) => Clipboard.setData(ClipboardData(text: text));

  @override
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async {
    try {
      return ClipboardContent.fromMap(await _channel.invokeMethod<Object?>('read', {'allowFocus': allowFocus}));
    } on MissingPluginException {
      final text = await readText();
      return text == null || text.isEmpty ? null : ClipboardContent(text: text);
    }
  }

  @override
  Future<void> writeContent(ClipboardContent content) async {
    if (content.image == null) return writeText(content.text ?? '');
    try {
      if (await _channel.invokeMethod<Object?>('write', content.toMap()) != true) {
        throw StateError('The system did not acknowledge the image copy');
      }
    } on MissingPluginException {
      throw UnsupportedError('Image clipboard access is unavailable on this device');
    }
  }
}
