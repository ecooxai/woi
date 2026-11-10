import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/thumbnail_image_provider.dart';

final _markdownImageLink = RegExp(r'(!?)\[[^\]\n]*\]\(([^)\s]+)\)');
final _bareImageLink = RegExp(r'(?:https?://|file:///)[^\s<>()]+');
final _imageSuffix = RegExp(r'\.(?:png|jpe?g|gif|webp|bmp)$', caseSensitive: false);

/// Image extensions are checked against the URI path, so query strings and
/// fragments do not stop ordinary image links from displaying a preview.
List<String> noteImageTargets(String text) {
  final found = <String>[];
  void add(String target, {bool explicit = false}) {
    final uri = Uri.tryParse(target);
    if (uri == null || (!target.startsWith('/') && !const ['http', 'https', 'file'].contains(uri.scheme))) return;
    if (!explicit && !_imageSuffix.hasMatch(uri.path)) return;
    if (!found.contains(target)) found.add(target);
  }

  var inFence = false;
  for (final line in text.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    for (final match in _markdownImageLink.allMatches(line)) {
      add(match.group(2)!, explicit: match.group(1) == '!');
    }
    for (final match in _bareImageLink.allMatches(line)) {
      add(match.group(0)!.replaceFirst(RegExp(r'[,.;]+$'), ''));
    }
    if (line.trim().startsWith('/')) add(line.trim());
  }
  return found;
}

class NoteImagePreview extends StatelessWidget {
  const NoteImagePreview({super.key, required this.target, this.showLink = false, this.lineNumber});
  final String target;
  final bool showLink;
  final int? lineNumber;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(target);
    Widget unavailable(BuildContext _, Object _, StackTrace? _) => Container(
      width: 144,
      height: 84,
      alignment: Alignment.center,
      child: Text('Image unavailable', style: body(11, color: WoiColors.textFaint)),
    );
    final ImageProvider provider;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      provider = NetworkImage(target);
    } else {
      final path = uri?.scheme == 'file' ? uri!.toFilePath() : target;
      provider = FileImage(File(path));
    }
    // Bound both dimensions: a narrow portrait must not decode its full height
    // merely because the thumbnail has a small width.
    final image = Image(
      image: ThumbnailImage(provider, width: 288, height: 168),
      width: 144,
      height: 84,
      fit: BoxFit.contain,
      errorBuilder: unavailable,
    );
    return SelectionContainer.disabled(
      child: IgnorePointer(
        child: Container(
          width: showLink ? 196 : 148,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: WoiColors.bg1,
            border: Border.all(color: WoiColors.stroke),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lineNumber != null) Text('Line $lineNumber', style: body(10, color: WoiColors.textDim)),
              if (showLink)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    target,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: body(10, color: WoiColors.textDim),
                  ),
                ),
              ClipRRect(borderRadius: BorderRadius.circular(4), child: image),
            ],
          ),
        ),
      ),
    );
  }
}
