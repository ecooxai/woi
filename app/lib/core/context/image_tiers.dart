import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../platform/screen_capture.dart' show kDefaultScreenshotJpegQuality;
import '../../platform/screenshot_encode.dart';
import '../models/message.dart';
import '../responses/responses_client.dart';
import '../util/image_mime.dart';
import '../util/usage_limit.dart';

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
///
/// An activation screenshot (the Android "Assist screenshot" every
/// long-press adds, [isActivationScreenshot]) starts a turn of its own unless
/// the next turn boundary after it is a user message (then it belongs to that
/// turn: the user invoked Woi and spoke). Without this, activations without
/// speech piled screenshots into the "recent" window forever: nothing was
/// ever old enough to compact and the context grew past 100%.
int rawTurnsStart(List<Message> messages, [int turns = kRawRecentTurns]) {
  if (turns <= 0) return messages.length;
  var seen = 0;
  int? cut;
  var absorb = false; // the last boundary seen (newer) was a user message
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m.compacted) continue;
    final user = m.kind == MessageKind.user;
    if (!user && !isActivationScreenshot(m)) continue;
    if (!user && absorb) {
      absorb = false;
      if (seen == turns) cut = i; // keep the turn's screenshot with it
      continue;
    }
    if (cut != null) return cut; // an older turn exists
    absorb = user;
    if (++seen == turns) cut = i;
  }
  return 0;
}

/// Meta flag of a screenshot that opened an activation (Android assist).
const kActivationMeta = 'activation';

/// Start of the note the model gets with an assist screenshot; the Realtime
/// backend recognises activation image items by it.
const kAssistNotePrefix = 'The user invoked Woi as the phone assistant';

/// A screenshot added by an assist activation, which may never be followed
/// by speech. Tool screenshots in a turn are not (they belong to it). The
/// label check covers conversations saved before the meta flag existed.
bool isActivationScreenshot(Message m) =>
    m.kind == MessageKind.system &&
    m.image != null &&
    (m.meta[kActivationMeta] == true || m.text.startsWith('Assist screenshot'));

/// Newest [fullCount] screenshots stay as sent, the next [reducedCount] are
/// downscaled, everything older is described in words. Tiers only ever go
/// down; compacted messages are left alone (the summary covers them).
/// Screenshots in the last [rawRecentTurns] user turns are never lowered
/// (they still count towards the age of older ones).
class ImageTierPolicy {
  const ImageTierPolicy({
    this.fullCount = 3,
    this.reducedCount = 5,
    this.reduceFactor = 2,
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

/// Returns [image] (encoded, usually JPEG) resized to [width]x[height],
/// encoded as JPEG or PNG; the compactor sniffs which.
typedef Downscale = Future<Uint8List> Function(Uint8List image, int width, int height);
typedef Describe = Future<String> Function(Uint8List image, String? note);

/// Stores a tier variant; [ext] matches the bytes ('jpg', 'png').
typedef SaveVariant = Future<String> Function(String messageId, Uint8List image, {String ext});

/// Swaps a screenshot in the live model context. [png] for a downscaled
/// copy (any encoding, JPEG normally; the backend sniffs the MIME type),
/// [text] for a description. Returns false if the backend cannot (the
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

  /// Descriptions need the Responses API; after a usage limit (429) they are
  /// skipped until it resets (each retry is one more refused request).
  /// Downscaling is local and goes on.
  UsageLimit? describeLimit;
  DateTime? _describeLimitSeen;

  bool _describeBlocked(DateTime now) {
    final l = describeLimit;
    if (l == null) return false;
    if (l.activeAt(now, seenAt: _describeLimitSeen)) return true;
    describeLimit = null;
    return false;
  }

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
      if (tier == ImageTier.described && _describeBlocked(DateTime.now())) continue;
      try {
        final original = await File(img.path).readAsBytes();
        final label = imageLabel(m);
        final note = '$label from ${_clock(m.createdAt)}${m.text.isNotEmpty ? ' (${m.text})' : ''}.';
        if (tier == ImageTier.reduced) {
          final w = (img.width / policy.reduceFactor).round().clamp(1, 1 << 15);
          final h = (img.height / policy.reduceFactor).round().clamp(1, 1 << 15);
          final small = await downscale(original, w, h);
          final path = await save('${m.id}_r${policy.reduceFactor}', small, ext: imageExtOf(small));
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
          if (await apply(m, text: 'Earlier ${label.toLowerCase()} from ${_clock(m.createdAt)} (image removed): $text')) {
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
        final limit = tier == ImageTier.described ? UsageLimit.parse(e) : null;
        if (limit != null) {
          describeLimit = limit;
          _describeLimitSeen = DateTime.now();
          debugPrint('image tiers: descriptions paused: ${limit.message}');
        } else {
          debugPrint('image tiers: ${m.id} -> ${tier.name} failed: $e');
        }
      }
    }
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

/// Reduced-tier downscale: JPEG at the screenshot quality setting
/// ([quality], read on each call), off the UI thread. A PNG re-encode of a
/// JPEG screenshot was often bigger than the full-size original.
Downscale jpegDownscale({int Function()? quality}) =>
    (image, width, height) => reencodeJpeg(image, width, height, quality?.call() ?? kDefaultScreenshotJpegQuality);

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

/// "Screenshot", "Camera frame" or "Media image" (from the message's
/// `imageKind` meta, see ContextImageMeta).
String imageLabel(Message m) => switch (m.meta['imageKind']) {
  'camera' => 'Camera frame',
  'media' => 'Media image',
  _ => 'Screenshot',
};
