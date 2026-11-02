import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Full-window zoomable image (tap a screenshot thumbnail).
Future<void> showImageLightbox(BuildContext context, String path, {String? caption, VoidCallback? onOpenWindow}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.82),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: child),
    ),
    pageBuilder: (context, _, _) => SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Hero(
                  tag: path,
                  child: Image.file(File(path), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Row(
              children: [
                if (onOpenWindow != null)
                  IconButton.filledTonal(
                    tooltip: 'Open in window',
                    onPressed: () {
                      Navigator.of(context).pop();
                      onOpenWindow();
                    },
                    icon: const Icon(Icons.open_in_new),
                  ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (caption != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: WoiColors.bg1.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(caption, style: body(12, color: WoiColors.textDim)),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
