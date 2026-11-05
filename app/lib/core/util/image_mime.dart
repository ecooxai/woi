import 'dart:typed_data';

/// MIME type of encoded image [b], sniffed from its magic bytes (JPEG, WebP,
/// GIF; anything else is taken as PNG). Every place that sends an image to a
/// model (Realtime `input_image`, Responses, delegation) uses this, so the
/// data URL always matches the bytes.
String imageMimeOf(Uint8List b) {
  if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
  if (b.length > 12 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return 'image/webp';
  if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'image/gif';
  return 'image/png';
}

/// File extension (no dot) matching [imageMimeOf].
String imageExtOf(Uint8List b) => switch (imageMimeOf(b)) {
  'image/jpeg' => 'jpg',
  'image/webp' => 'webp',
  'image/gif' => 'gif',
  _ => 'png',
};
