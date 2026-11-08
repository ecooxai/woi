import 'package:flutter/services.dart';

/// Explicit text clipboard access. Reading is never part of input preparation.
abstract interface class ClipboardAccess {
  Future<String?> readText();
  Future<void> writeText(String text);
}

/// Flutter's native clipboard on desktop. Android supplies its own bridge so
/// background access restrictions are reported instead of looking like empty text.
class SystemClipboardAccess implements ClipboardAccess {
  const SystemClipboardAccess();

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
