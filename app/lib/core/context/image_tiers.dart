import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import '../responses/responses_client.dart';

/// How a screenshot is currently represented in the model's context.
enum ImageTier {
  /// As captured.
  full,

  /// Downscaled to 1/[ImageTierPolicy.reduceFactor] of width and height.
  reduced,

  /// Replaced by a short text description (gpt-6-luna).
  described,
}

/// Message meta keys (persisted with the conversation).
abstract final class ImageMeta {
  static const tier = 'imageTier';
  static const sentPath = 'imageSentPath';
  static const sentWidth = 'imageSentW';
  static const sentHeight = 'imageSentH';
  static const description = 'imageDescription';

  /// Server item that carries the image (direct Realtime).
  static const serverItem = 'serverItemId';
}

ImageTier imageTierOf(Message m) => switch (m.meta[ImageMeta.tier]) {
  'reduced' => ImageTier.reduced,
  'described' => ImageTier.described,
  _ => ImageTier.full,
};

String? imageDescriptionOf(Message m) => m.meta[ImageMeta.description] as String?;

/// Context compaction rule (docs/PLAN.md): the last 3 user turns (with their
/// replies, tool calls and screenshots) are ALWAYS sent raw. Only older turns
/// are summarized, and only images in older turns change tier.
const kRawRecentTurns = 3;

/// Index of the first message of the [turns]-th last user turn that is still
/// in the context; everything from there on is sent raw. 0 when there are no
/// more than [turns] user turns (nothing is old yet), `messages.length` when
/// [turns] is 0.
int rawTurnsStart(List<Message> messages, [int turns = kRawRecentTurns]) {
  if (turns <= 0) return messages.length;
  var seen = 0;
  int? cut;
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m.kind != MessageKind.user || m.compacted) continue;
    if (cut != null) return cut; // an older user turn exists
    if (++seen == turns) cut = i;
  }
  return 0;
}

/// Newest [fullCount] screenshots stay as sent, the next [reducedCount] are
/// downscaled, everything older is described in words. Tiers only ever go
/// down; compacted messages are left alone (the summary covers them).
/// Screenshots in the last [rawRecentTurns] user turns are never lowered
/// (they still count towards the age of older ones).
class ImageTierPolicy {
  const ImageTierPolicy({
    this.fullCount = 3,
    this.reducedCount = 5,
    this.reduceFactor = 5,
    this.rawRecentTurns = kRawRecentTurns,
  });

  final int fullCount;
  final int reducedCount;
  final int reduceFactor;
  final int rawRecentTurns;

  ImageTier targetFor(int ageIndex) => ageIndex < fullCount
      ? ImageTier.full
      : ageIndex < fullCount + reducedCount
      ? ImageTier.reduced
      : ImageTier.described;

  /// Messages whose tier must be lowered, newest first, with the new tier.
  List<(Message, ImageTier)> plan(List<Message> messages) {
    final out = <(Message, ImageTier)>[];
    final raw = rawTurnsStart(messages, rawRecentTurns);
    var age = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.image == null || m.compacted) continue;
      final want = targetFor(age++);
      if (i >= raw) continue;
      if (want.index > imageTierOf(m).index) out.add((m, want));
    }
    return out;
  }
}

typedef Downscale = Future<Uint8List> Function(Uint8List png, int width, int height);
typedef Describe = Future<String> Function(Uint8List png, String? note);
typedef SaveVariant = Future<String> Function(String messageId, Uint8List png);

/// Swaps a screenshot in the live model context. [png] for a downscaled
/// copy, [text] for a description. Returns false if the backend cannot (the
/// local tier still changes: delegation and reconnect contexts use it).
typedef ApplyImage = Future<bool> Function(Message m, {Uint8List? png, String? text});

/// Lowers screenshot tiers per [policy]. Originals stay on disk and in the
/// UI; only what the model gets changes. Runs are serialized.
class ImageCompactor {
  ImageCompactor({
    this.policy = const ImageTierPolicy(),
    required this.downscale,
    required this.describe,
    required this.save,
  });

  final ImageTierPolicy policy;
  final Downscale downscale;
  final Describe describe;
  final SaveVariant save;

  Future<void> _tail = Future.value();
  int reduced = 0;
  int described = 0;
  int applied = 0;
  Object? lastError;

  /// Plans and applies tier changes for [messages]; [onChanged] after each.
  Future<void> run(List<Message> messages, {required ApplyImage apply, VoidCallback? onChanged}) {
    final next = _tail.then((_) => _run(messages, apply, onChanged));
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _run(List<Message> messages, ApplyImage apply, VoidCallback? onChanged) async {
    // Oldest first: the description of an old image is not urgent but the
    // downscale of a recent one is cheap, so both just go in order.
    for (final (m, tier) in policy.plan(List.of(messages)).reversed) {
      final img = m.image;
      if (img == null || m.compacted) continue;
      try {
        final original = await File(img.path).readAsBytes();
        final note = 'Screenshot from ${_clock(m.createdAt)}${m.text.isNotEmpty ? ' (${m.text})' : ''}.';
        if (tier == ImageTier.reduced) {
          final w = (img.width / policy.reduceFactor).round().clamp(1, 1 << 15);
          final h = (img.height / policy.reduceFactor).round().clamp(1, 1 << 15);
          final small = await downscale(original, w, h);
          final path = await save('${m.id}_r${policy.reduceFactor}', small);
          if (await apply(m, png: small, text: '$note Downscaled to ${w}x$h; do not click by its coordinates.')) {
            applied++;
          }
          m.meta
            ..[ImageMeta.tier] = 'reduced'
            ..[ImageMeta.sentPath] = path
            ..[ImageMeta.sentWidth] = w
            ..[ImageMeta.sentHeight] = h;
          reduced++;
        } else {
          final text = (await describe(original, m.text.isEmpty ? null : m.text)).trim();
          if (text.isEmpty) throw StateError('empty description');
          if (await apply(m, text: 'Earlier screenshot from ${_clock(m.createdAt)} (image removed): $text')) {
            applied++;
          }
          m.meta
            ..[ImageMeta.tier] = 'described'
            ..[ImageMeta.description] = text;
          described++;
        }
        lastError = null;
        onChanged?.call();
      } catch (e) {
        lastError = e;
        debugPrint('image tiers: ${m.id} -> ${tier.name} failed: $e');
      }
    }
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

/// PNG downscale with the engine's codec (bilinear-ish, good enough for a
/// thumbnail the model only needs for gist).
Future<Uint8List> uiDownscale(Uint8List png, int width, int height) async {
  final codec = await ui.instantiateImageCodec(png, targetWidth: width, targetHeight: height);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (data == null) throw StateError('png encode failed');
  return data.buffer.asUint8List();
}

const kDescribeInstructions = '''
Describe this screenshot for a voice assistant's memory in at most 40 words: the app or page, the document or
content shown, and any text, file names, numbers or errors that look important. Plain text, no preamble.''';

/// gpt-6-luna description through the Responses API.
Describe responsesDescriber(ResponsesClient client, {String Function()? model}) => (png, note) async {
  final r = await client.create(
    model: model?.call() ?? 'gpt-6-luna',
    instructions: kDescribeInstructions,
    input: [
      userMessage([inputImage(png), if (note != null) inputText('Context: $note')]),
    ],
  );
  return r.text;
};
