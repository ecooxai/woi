import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/images/media_metadata.dart';
import '../theme.dart';

/// File facts shared by the dialog, detached desktop viewer and mobile viewer.
class MediaMetadataLabel extends StatefulWidget {
  const MediaMetadataLabel({
    super.key,
    required this.path,
    this.image = false,
    this.generationDurationMs,
    this.generationModel,
    this.generationQuality,
    this.centered = false,
  });
  final String path;
  final bool image;
  final int? generationDurationMs;
  final String? generationModel;
  final String? generationQuality;
  final bool centered;
  @override
  State<MediaMetadataLabel> createState() => _MediaMetadataLabelState();
}

class _MediaMetadataLabelState extends State<MediaMetadataLabel> {
  late Future<MediaMetadata?> _metadata = MediaMetadata.read(
    File(widget.path),
    image: widget.image,
  );

  @override
  void didUpdateWidget(MediaMetadataLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.image != widget.image) {
      _metadata = MediaMetadata.read(File(widget.path), image: widget.image);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaMetadata?>(
    future: _metadata,
    builder: (context, snapshot) {
      final parts = <String>[
        if (snapshot.data != null) snapshot.data!.label,
        if (widget.generationDurationMs != null)
          'Generated in ${formatGenerationDuration(widget.generationDurationMs!)}',
        if (widget.generationQuality != null)
          '${widget.generationQuality} quality',
      ];
      if (parts.isEmpty) return const SizedBox.shrink();
      return Text(
        parts.join(' · '),
        key: const ValueKey('media-file-metadata'),
        textAlign: widget.centered ? TextAlign.center : TextAlign.start,
        style: body(12, color: WoiColors.textDim),
      );
    },
  );
}
