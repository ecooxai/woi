import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/context/image_tiers.dart';
import '../../core/models/message.dart';
import '../../core/auth/pkce_login.dart';
import '../../core/images/media_metadata.dart';
import '../../core/audio/clip_loudness.dart';
import '../../platform/audio_io.dart';
import '../../platform/downloads.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import 'audio_button.dart';
import 'code_highlight.dart';
import 'context_meter.dart' show formatTokens;
import 'glass.dart';
import 'image_viewer.dart';
import 'low_fps.dart';
import 'throttled_builder.dart';

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.audio,
    required this.viewer,
    this.urlOpener,
    this.maxBubbleWidth = 640,
    this.screenshot,
  });

  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final PlatformUrlOpener? urlOpener;
  final double maxBubbleWidth;

  /// Latest screenshot before this message (click markers on tool cards).
  final ImageAttachment? screenshot;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final child = switch (m.kind) {
      MessageKind.user => _Bubble(
        message: m,
        audio: audio,
        viewer: viewer,
        maxWidth: maxBubbleWidth,
        urlOpener: urlOpener,
        isUser: true,
      ),
      MessageKind.assistant => _Bubble(
        message: m,
        audio: audio,
        viewer: viewer,
        maxWidth: maxBubbleWidth,
        urlOpener: urlOpener,
        isUser: false,
      ),
      MessageKind.tool => ToolCallCard(
        message: m,
        maxWidth: maxBubbleWidth,
        screenshot: screenshot,
        viewer: viewer,
      ),
      MessageKind.system => _SystemNote(message: m, viewer: viewer),
    };
    return EntryAnimation(
      animate:
          DateTime.now().difference(m.createdAt) < const Duration(seconds: 3),
      fromRight: m.kind == MessageKind.user,
      child: AnimatedOpacity(
        duration: WoiMotion.slow,
        opacity: m.compacted ? 0.45 : 1,
        child: child,
      ),
    );
  }
}

/// Codex's internal citation handles are not browser links. Search messages keep
/// their durable source URLs in metadata and show those as accessible buttons.
String messageDisplayText(Message message) {
  if (message.meta['type'] == 'image_generation' &&
      message.meta['status'] == 'pending' &&
      RegExp(
        r'^(?:generating|editing) image(?:…|\.\.\.)?$',
        caseSensitive: false,
      ).hasMatch(message.text.trim())) {
    // The progress row already speaks and displays this placeholder. Keep
    // distinct prompt/details text, and never hide a failure explanation.
    return '';
  }
  return message.meta['type'] == 'web_search'
      ? message.text.replaceAll(RegExp(r'cite[^]*'), '')
      : message.text;
}

/// Everything of [m] that a [MessageTile] shows and that can change after
/// the message is added (messages are mutated in place while a turn runs).
Object messageRenderSignature(Message m) {
  final t = m.tool;
  return (
    m.text,
    m.streaming,
    m.interrupted,
    m.compacted,
    m.audio,
    m.image,
    t?.status,
    t?.resultJson,
    t?.finishedAt,
    m.meta.length,
    Object.hashAll(m.meta.values),
  );
}

/// A [MessageTile] that follows [listenable] (the pipeline) itself and
/// rebuilds only when its own message changed ([messageRenderSignature]), in
/// its own repaint boundary: while a reply streams, the other bubbles are
/// neither rebuilt nor repainted.
class LiveMessageTile extends StatelessWidget {
  const LiveMessageTile({
    super.key,
    required this.listenable,
    required this.message,
    required this.audio,
    required this.viewer,
    this.urlOpener,
    this.maxBubbleWidth = 640,
    this.screenshot,
  });

  final Listenable listenable;
  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final PlatformUrlOpener? urlOpener;
  final double maxBubbleWidth;
  final ImageAttachment? screenshot;

  @override
  Widget build(BuildContext context) => SelectorBuilder<Object>(
    listenable: listenable,
    selector: () => messageRenderSignature(message),
    builder: (context, _) => RepaintBoundary(
      child: MessageTile(
        message: message,
        audio: audio,
        viewer: viewer,
        maxBubbleWidth: maxBubbleWidth,
        urlOpener: urlOpener,
        screenshot: screenshot,
      ),
    ),
  );
}

/// Fade + rise + slight scale on first build (new messages only).
class EntryAnimation extends StatelessWidget {
  const EntryAnimation({
    super.key,
    required this.child,
    this.animate = true,
    this.fromRight = false,
  });
  final Widget child;
  final bool animate;
  final bool fromRight;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: WoiMotion.slow,
      curve: WoiMotion.emphasized,
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset((fromRight ? 18 : -18) * (1 - v), 14 * (1 - v)),
          child: Transform.scale(scale: 0.97 + 0.03 * v, child: child),
        ),
      ),
    );
  }
}

// Message surfaces stay light in both app themes. Their text and controls use
// dark foregrounds rather than inheriting light text from the dark app palette.
const _bubblePalette = WoiPalette.light;
const _assistantBubbleFill = Color(0xFFF4FAF2);
const _userBubbleAccent = Color(0xFF1D4ED8);
const _assistantBubbleAccent = Color(0xFF6D28D9);
const _bubbleWarning = Color(0xFF92400E);

final _placeholder = RegExp(r'^\[(\d+(?:\.\d+)?) s of speech\]$');

/// Voice turns without a transcript are stored as "[2.6 s of speech]".
bool isSpeechPlaceholder(String text) => _placeholder.hasMatch(text.trim());

class _VoiceLabel extends StatelessWidget {
  const _VoiceLabel({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final secs = _placeholder.firstMatch(text.trim())?.group(1);
    return Semantics(
      label: 'Voice message${secs != null ? ', $secs seconds' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            'Voice message',
            style: body(
              14,
              weight: FontWeight.w500,
              color: _bubblePalette.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

String _time(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.audio,
    required this.viewer,
    required this.maxWidth,
    required this.isUser,
    this.urlOpener,
  });

  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final double maxWidth;
  final bool isUser;
  final PlatformUrlOpener? urlOpener;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final accent = isUser ? _userBubbleAccent : _assistantBubbleAccent;
    final imageJob = m.meta['type'] == 'image_generation';
    final imageStatus = imageJob ? m.meta['status'] as String? : null;
    final generatingImage = imageStatus == 'pending';
    final visibleText = messageDisplayText(m);
    final waiting = m.streaming && m.text.isEmpty && !generatingImage;
    const r = Radius.circular(WoiRadii.lg);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: isUser ? r : const Radius.circular(6),
      bottomRight: isUser ? const Radius.circular(6) : r,
    );

    Widget? textContent;
    if (waiting) {
      textContent = _TypingDots(
        color: accent,
        label: isUser ? 'listening' : null,
      );
    } else if (isSpeechPlaceholder(visibleText)) {
      textContent = _VoiceLabel(text: visibleText, color: accent);
    } else if (visibleText.isNotEmpty) {
      // The transcript's SelectionArea makes plain Text selectable across
      // messages. A live partial transcript stays italic until finalized.
      textContent = Text(
        visibleText,
        style: isUser && m.streaming
            ? body(
                15,
                height: 1.5,
                color: _bubblePalette.textDim,
              ).copyWith(fontStyle: FontStyle.italic)
            : body(15, height: 1.5, color: _bubblePalette.text),
      );
    }

    final content = Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (imageStatus == 'pending' ||
            imageStatus == 'failed' ||
            imageStatus == 'interrupted') ...[
          _ImageGenerationProgress(
            status: imageStatus!,
            editing: m.meta['action'] == 'edit',
          ),
          if (visibleText.isNotEmpty) const SizedBox(height: 8),
        ],
        if (isUser && textContent != null) textContent,
        if (m.image != null) ...[
          if (isUser && textContent != null) const SizedBox(height: 10),
          ScreenshotThumb(
            image: m.image!,
            viewer: viewer,
            tier: imageTierOf(m),
            label: m.image!.generated ? 'Generated image' : imageLabel(m),
            palette: _bubblePalette,
          ),
          if (m.image!.generated)
            _GeneratedImageInfo(image: m.image!, color: _bubblePalette.textDim),
          if (!isUser && textContent != null) const SizedBox(height: 10),
        ],
        if (!isUser && textContent != null) textContent,
        if (m.meta['type'] == 'web_search')
          _SearchSources(sources: m.meta['sources'], opener: urlOpener),
        if (!isUser) ...[
          const SizedBox(height: 6),
          Text(
            m.meta['model'] as String? ?? 'Model not recorded',
            key: ValueKey('reply-model-${m.id}'),
            style: body(11, color: _bubblePalette.textDim),
          ),
        ],
        if (m.audio != null || m.interrupted || !m.streaming) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (m.audio != null)
                AudioClipButton(clip: m.audio!, audio: audio, color: accent),
              _MessageActions(message: m, color: accent, isUser: isUser),
              if (m.interrupted)
                Pill(
                  label: 'interrupted',
                  color: _bubbleWarning,
                  icon: Icons.content_cut,
                  dense: true,
                ),
              Text(
                _time(m.createdAt),
                style: body(11, color: _bubblePalette.textFaint),
              ),
            ],
          ),
        ],
      ],
    );

    final box = Container(
      key: ValueKey('message-bubble-${m.id}'),
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        borderRadius: radius,
        color: isUser ? Colors.white : _assistantBubbleFill,
        border: Border.all(
          color: isUser ? _bubblePalette.stroke : const Color(0xFFD9E7D4),
        ),
      ),
      child: content,
    );
    // Only live (or just finished) messages change size; old ones skip the
    // AnimatedSize render object and its animation controller.
    final live =
        m.streaming ||
        DateTime.now().difference(m.createdAt) < const Duration(minutes: 1);
    final bubble = live
        ? AnimatedSize(
            duration: WoiMotion.medium,
            curve: WoiMotion.curve,
            alignment: isUser ? Alignment.topRight : Alignment.topLeft,
            child: box,
          )
        : box;

    return Semantics(
      container: true,
      label: isUser ? 'You said' : 'Woi said',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: isUser
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: isUser
                  ? bubble
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Avatar(
                          key: ValueKey('reply-avatar-${m.id}'),
                          active: m.streaming,
                        ),
                        const SizedBox(height: 6),
                        bubble,
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copy and "more" (download audio, ...) controls next to a message's
/// play button.
class _MessageActions extends StatelessWidget {
  const _MessageActions({
    required this.message,
    required this.color,
    required this.isUser,
  });

  final Message message;
  final Color color;
  final bool isUser;

  String get _copyText => isSpeechPlaceholder(message.text)
      ? ''
      : messageDisplayText(message).trim();

  void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _copyText));
    if (context.mounted) _snack(context, 'Copied');
  }

  Future<void> _download(BuildContext context) async {
    final clip = message.audio;
    if (clip == null) return;
    final t = message.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'woi-${isUser ? 'you' : 'reply'}-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.wav';
    try {
      // The same (boosted when quiet) audio the play button plays.
      final where = await saveToDownloads(
        await loudPlaybackPath(clip.path),
        name,
      );
      if (context.mounted) _snack(context, 'Saved to $where');
    } catch (e) {
      if (context.mounted) _snack(context, 'Download failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _copyText;
    final hasAudio = message.audio != null;
    if (text.isEmpty && !hasAudio) return const SizedBox.shrink();
    final iconColor = color.withValues(alpha: 0.85);
    const box = BoxConstraints.tightFor(width: 30, height: 30);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text.isNotEmpty)
          IconButton(
            tooltip: 'Copy text',
            constraints: box,
            padding: EdgeInsets.zero,
            iconSize: 16,
            color: iconColor,
            icon: const Icon(Icons.content_copy_rounded),
            onPressed: () => _copy(context),
          ),
        PopupMenuButton<String>(
          tooltip: 'More',
          constraints: const BoxConstraints(minWidth: 180),
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: Icon(Icons.more_horiz_rounded, color: iconColor),
          style: IconButton.styleFrom(
            minimumSize: const Size(30, 30),
            fixedSize: const Size(30, 30),
          ),
          onSelected: (v) => switch (v) {
            'download' => _download(context),
            'copy' => _copy(context),
            _ => null,
          },
          itemBuilder: (_) => [
            if (hasAudio)
              const PopupMenuItem(
                value: 'download',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.download_rounded),
                  title: Text('Download audio'),
                ),
              ),
            if (text.isNotEmpty)
              const PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.content_copy_rounded),
                  title: Text('Copy text'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({super.key, this.active = false});
  final bool active;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? WoiColors.cyan : WoiColors.text,
      ),
      child: Text(
        'W',
        style: display(12, weight: FontWeight.w700, color: WoiColors.bg1),
      ),
    ),
  );
}

class _ImageGenerationProgress extends StatelessWidget {
  const _ImageGenerationProgress({required this.status, this.editing = false});
  final String status;
  final bool editing;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status == 'pending')
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _userBubbleAccent,
            ),
          )
        else
          Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: _bubbleWarning,
          ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            switch (status) {
              'pending' => editing ? 'Editing image…' : 'Generating image…',
              'interrupted' => 'Image generation interrupted',
              _ => 'Image generation failed',
            },
            key: ValueKey('image-generation-$status'),
            style: body(14, color: _bubblePalette.textDim),
          ),
        ),
      ],
    ),
  );
}

class _SearchSources extends StatelessWidget {
  const _SearchSources({required this.sources, this.opener});
  final Object? sources;
  final PlatformUrlOpener? opener;

  @override
  Widget build(BuildContext context) {
    final links = <Uri, String>{};
    if (sources is List) {
      for (final source in sources as List) {
        if (source is! Map || source['url'] is! String) continue;
        final url = Uri.tryParse(source['url'] as String);
        if (url == null ||
            !const {'http', 'https'}.contains(url.scheme) ||
            url.host.isEmpty) {
          continue;
        }
        final title = source['title'];
        links[url] = title is String && title.trim().isNotEmpty
            ? title
            : url.host;
      }
    }
    if (links.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sources',
            style: body(
              11,
              weight: FontWeight.w600,
              color: _bubblePalette.textDim,
            ),
          ),
          const SizedBox(height: 4),
          for (final source in links.entries)
            Tooltip(
              message: source.key.toString(),
              child: TextButton.icon(
                key: ValueKey('search-source-${source.key}'),
                onPressed: () async {
                  final opened = await (opener ?? defaultUrlOpener()).open(
                    source.key,
                    keepAlive: false,
                  );
                  if (!opened && context.mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Could not open the source in your browser.',
                        ),
                      ),
                    );
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: _userBubbleAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 36),
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: Text(
                  '${source.value} · ${source.key.host}',
                  style: body(12, color: _userBubbleAccent),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GeneratedImageInfo extends StatelessWidget {
  const _GeneratedImageInfo({required this.image, this.color});
  final ImageAttachment image;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      [
        if (image.generationDurationMs != null)
          'Generated in ${formatGenerationDuration(image.generationDurationMs!)}',
        if (image.byteSize != null) formatFileBytes(image.byteSize!),
        if (image.generationQuality != null)
          '${image.generationQuality} quality',
      ].join(' · '),
      key: ValueKey('generated-image-time-${image.path}'),
      style: body(11.5, color: color ?? WoiColors.textDim),
    ),
  );
}

/// Screenshot thumbnail; tap for the zoomable lightbox. [marker] (in
/// image-pixel coordinates) draws a click target on top.
class ScreenshotThumb extends StatelessWidget {
  const ScreenshotThumb({
    super.key,
    required this.image,
    required this.viewer,
    this.marker,
    this.maxWidth = 300,
    this.maxHeight = 220,
    this.tier = ImageTier.full,
    this.label = 'Screenshot',
    this.palette,
  });
  final ImageAttachment image;

  /// "Screenshot", "Camera frame", "Media image" ([imageLabel]).
  final String label;

  /// How the model currently has it; the thumbnail is always the original.
  final ImageTier tier;

  /// Optional local surface palette; defaults to the current app theme.
  final WoiPalette? palette;
  final MediaViewer viewer;
  final Offset? marker;
  final double maxWidth;

  /// Tall images (phone screenshots) are cropped to this height from the
  /// top, where the app bar and title are: a full-height portrait tile was
  /// 600 px tall, and after the chat auto-scrolled only its (often empty,
  /// dark) bottom half was visible, which looked like a black thumbnail.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final known = image.width > 0 && image.height > 0;
    final aspect = known ? image.width / image.height : 16 / 9;
    return LayoutBuilder(
      builder: (context, box) {
        final w = math.min(
          maxWidth,
          box.maxWidth.isFinite ? box.maxWidth : maxWidth,
        );
        final h = math.min(w / aspect, maxHeight);
        // BoxFit.cover with top-center alignment: where the marker lands.
        final scale = known ? math.max(w / image.width, h / image.height) : 1.0;
        final dx = known ? (w - image.width * scale) / 2 : 0.0;
        final mk = marker;
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        return _thumb(
          context,
          w,
          h,
          mk == null || !known
              ? null
              : Offset(mk.dx * scale + dx, mk.dy * scale),
          (w * dpr).ceil(),
        );
      },
    );
  }

  Widget _thumb(
    BuildContext context,
    double w,
    double h,
    Offset? markerAt,
    int decodeWidth,
  ) {
    final file = File(image.path);
    final mk = marker;
    final colors = palette ?? WoiColors.palette;
    return Semantics(
      button: true,
      image: true,
      label: mk == null
          ? '$label. Tap to enlarge'
          : '$label with click at ${mk.dx.round()}, ${mk.dy.round()}',
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => showImageLightbox(
            context,
            image.path,
            caption: image.generated
                ? 'Generated image'
                : '$label · sent ${image.width}×${image.height}'
                      '${mk != null ? ' · click (${mk.dx.round()}, ${mk.dy.round()})' : ''}',
            generationDurationMs: image.generationDurationMs,
            generationModel: image.generationModel,
            generationQuality: image.generationQuality,
            marker: mk == null || image.width <= 0
                ? null
                : Offset(mk.dx / image.width, mk.dy / image.height),
            onOpenWindow: () => viewer.show(
              MediaItem(
                kind: MediaKind.image,
                path: image.path,
                generationDurationMs: image.generationDurationMs,
                generationModel: image.generationModel,
                generationQuality: image.generationQuality,
              ),
            ),
          ),
          child: SizedBox(
            width: w,
            height: h,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.strokeStrong),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      file,
                      fit: image.generated ? BoxFit.contain : BoxFit.cover,
                      alignment: Alignment.topCenter,
                      // Decode at the tile's size, not the image's.
                      cacheWidth: decodeWidth.clamp(64, 1280),
                      // Decoded at about the tile size: bilinear is enough
                      // (medium builds mipmaps, costly on software GL).
                      filterQuality: FilterQuality.low,
                      errorBuilder: (context, e, s) => Container(
                        color: colors.glass,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: colors.textDim,
                        ),
                      ),
                    ),
                    if (markerAt != null && markerAt.dy <= h)
                      ClickMarker(position: markerAt),
                    if (tier != ImageTier.full)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Tooltip(
                          message: tier == ImageTier.reduced
                              ? 'Older ${label.toLowerCase()}: the model now has it at ⅕ size'
                              : 'Old ${label.toLowerCase()}: the model now has a text description',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tier == ImageTier.reduced
                                  ? 'sent ⅕'
                                  : 'described',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.zoom_out_map,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pulsing crosshair target drawn at a click position.
class ClickMarker extends StatefulWidget {
  const ClickMarker({
    super.key,
    required this.position,
    this.color,
    this.size = 26,
  });
  final Offset position;
  final Color? color;
  final double size;

  @override
  State<ClickMarker> createState() => _ClickMarkerState();
}

class _ClickMarkerState extends State<ClickMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        )
        // A few pulses to draw the eye, then still (no idle frames).
        ..repeat(count: 3);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => CustomPaint(
      painter: _MarkerPainter(
        widget.position,
        widget.color ?? WoiColors.amber,
        widget.size,
        _c.value,
      ),
    ),
  );
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter(this.p, this.color, this.size, this.t);
  final Offset p;
  final Color color;
  final double size;
  final double t;

  @override
  void paint(Canvas canvas, Size s) {
    final r = size / 2;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    canvas.drawCircle(
      p,
      r * (0.6 + 0.9 * t),
      stroke..color = color.withValues(alpha: 1 - t),
    );
    stroke.color = color;
    canvas.drawCircle(
      p,
      r * 0.55,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(p, r * 0.55, stroke);
    canvas.drawCircle(p, 2.5, Paint()..color = color);
    for (final d in const [
      Offset(1, 0),
      Offset(-1, 0),
      Offset(0, 1),
      Offset(0, -1),
    ]) {
      canvas.drawLine(p + d * r * 0.75, p + d * r * 1.15, stroke);
    }
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => old.t != t || old.p != p;
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color, this.label});
  final Color color;
  final String? label;
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

/// Three dots stepping at 5 fps (not a 60 fps controller: each frame is a
/// full raster on software GL), in their own repaint boundary. They stop
/// after [_maxRun]: a transcript that never arrives must not keep an idle
/// window rendering.
class _TypingDotsState extends State<_TypingDots> {
  static const _step = Duration(milliseconds: 200);
  static const _maxRun = Duration(seconds: 20);
  final _tick = ValueNotifier<int>(0);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_step, (t) {
      if (t.tick * _step.inMilliseconds >= _maxRun.inMilliseconds) {
        t.cancel();
        _tick.value = -1; // still: all dots half lit
        return;
      }
      _tick.value = t.tick;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label ?? 'Woi is responding',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.label != null) ...[
            Text(
              widget.label!,
              style: body(13, color: widget.color.withValues(alpha: 0.85)),
            ),
            const SizedBox(width: 8),
          ],
          RepaintBoundary(
            child: ValueListenableBuilder<int>(
              valueListenable: _tick,
              builder: (context, tick, _) => Row(
                children: List.generate(3, (i) {
                  // One bright dot walking left to right (6 steps per cycle).
                  final p = tick < 0 ? -1 : tick % 6;
                  final a = tick < 0
                      ? 0.5
                      : (p == i * 2 || p == i * 2 + 1 ? 1.0 : 0.3);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: a),
                      shape: BoxShape.circle,
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ tools

const _toolIcons = <String, IconData>{
  'take_screenshot': Icons.screenshot_monitor,
  'click_screen': Icons.ads_click,
  'control_pointer': Icons.mouse_outlined,
  'type_text': Icons.keyboard,
  'key_combo': Icons.keyboard_command_key,
  'send_keys': Icons.keyboard_command_key,
  'run_bash': Icons.terminal,
  'read_file': Icons.description_outlined,
  'list_dir': Icons.folder_open,
  'write_file': Icons.save_outlined,
  'edit_file': Icons.edit_note,
  'show_file': Icons.open_in_new,
  'delegate_task': Icons.hub_outlined,
  'read_note': Icons.sticky_note_2_outlined,
  'update_note': Icons.edit_note,
  'note_control': Icons.sticky_note_2_outlined,
  'app_control': Icons.tune_rounded,
};

String toolTitle(String name) => switch (name) {
  'take_screenshot' => 'Screenshot',
  'click_screen' => 'Click',
  'control_pointer' => 'Pointer',
  'type_text' => 'Type text',
  'key_combo' => 'Key combo',
  'send_keys' => 'Send keys',
  'run_bash' => 'Shell command',
  'read_file' => 'Read file',
  'list_dir' => 'List folder',
  'write_file' => 'Write file',
  'edit_file' => 'Edit file',
  'show_file' => 'Show file',
  'delegate_task' => 'Delegate task',
  'read_note' => 'Read note',
  'update_note' => 'Update note',
  'note_control' => 'Note',
  'app_control' => 'Woi',
  _ => name,
};

Map<String, Object?> _decode(String? s) {
  if (s == null || s.isEmpty) return const {};
  try {
    final v = jsonDecode(s);
    return v is Map ? v.cast<String, Object?>() : {'value': v};
  } catch (_) {
    return {'raw': s};
  }
}

String toolArgSummary(String name, String argsJson) {
  final a = _decode(argsJson);
  if (a.containsKey('raw')) return argsJson;
  final s = switch (name) {
    'run_bash' => a['command'],
    'control_pointer' => a['request'],
    'read_file' ||
    'list_dir' ||
    'write_file' ||
    'edit_file' ||
    'show_file' => a['path'],
    'type_text' => '"${a['text']}"',
    'key_combo' => a['keys'],
    'send_keys' => [
      a['keys'] ?? a['action'],
      if (a['window'] != null) '→ ${a['window']}',
    ].join(' '),
    'click_screen' =>
      '(${a['x']}, ${a['y']})${a['double'] == true ? ' ×2' : ''}${a['button'] != null && a['button'] != 'left' ? ' ${a['button']}' : ''}',
    'delegate_task' => a['task'],
    'read_note' => '',
    'note_control' || 'app_control' => [
      '${a['action'] ?? ''}'.replaceAll('_', ' '),
      for (final k in [
        'view',
        'key',
        'value',
        'name',
        'title',
        'command',
        'tab',
        'path',
        'find',
        'text',
        'seconds',
      ])
        if (a[k] != null) '${a[k]}',
    ].join(' '),
    'update_note' => switch (a['mode']) {
      'check_item' =>
        '${a['checked'] == false ? 'uncheck' : 'check'} "${a['item'] ?? ''}"',
      'replace_section' => 'section "${a['heading'] ?? ''}"',
      'replace_all' => 'rewrite note',
      _ => '${a['text'] ?? ''}'.split('\n').first,
    },
    _ => a.isEmpty ? '' : argsJson,
  };
  return '${s ?? ''}';
}

Offset? _executedClickPoint(
  ToolCallInfo info,
  Map<String, Object?> args,
  Map<String, Object?> result,
) {
  if (info.status != ToolStatus.success || result['clicked'] == false) {
    return null;
  }
  if (info.name != 'click_screen' && info.name != 'control_pointer') {
    return null;
  }
  if (info.name == 'control_pointer' && result['action'] != 'click') {
    return null;
  }
  final point = result['image_xy'];
  if (point is List &&
      point.length == 2 &&
      point[0] is num &&
      point[1] is num) {
    final x = (point[0] as num).toDouble(), y = (point[1] as num).toDouble();
    return x.isFinite && y.isFinite ? Offset(x, y) : null;
  }
  // Older direct click results did not record image coordinates.
  if (info.name == 'click_screen' &&
      !result.containsKey('image_xy') &&
      args['x'] is num &&
      args['y'] is num) {
    final x = (args['x'] as num).toDouble(), y = (args['y'] as num).toDouble();
    return x.isFinite && y.isFinite ? Offset(x, y) : null;
  }
  return null;
}

/// Tool call row. Status changes animate; tap to expand args/results
/// (bash output in a terminal block, clicks as a marker on the screenshot).
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({
    super.key,
    required this.message,
    this.maxWidth = 640,
    this.screenshot,
    this.viewer,
    this.initiallyExpanded = false,
  });
  final Message message;
  final double maxWidth;
  final ImageAttachment? screenshot;
  final MediaViewer? viewer;
  final bool initiallyExpanded;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final t = widget.message.tool!;
    final (color, label, icon) = switch (t.status) {
      ToolStatus.pending => (WoiColors.textDim, 'queued', Icons.schedule),
      ToolStatus.awaitingApproval => (
        WoiColors.amber,
        'needs approval',
        Icons.front_hand_outlined,
      ),
      ToolStatus.running => (WoiColors.cyan, 'running', null),
      ToolStatus.success => (WoiColors.mint, 'done', Icons.check_rounded),
      ToolStatus.error => (WoiColors.red, 'failed', Icons.error_outline),
      ToolStatus.denied => (WoiColors.amber, 'rejected', Icons.block),
    };
    final summary = toolArgSummary(t.name, t.argsJson);
    final elapsed = t.finishedAt?.difference(t.startedAt);
    final busy =
        t.status == ToolStatus.running || t.status == ToolStatus.pending;
    final args = _decode(t.argsJson);
    final result = _decode(t.resultJson);
    final click = _executedClickPoint(t, args, result);

    final statusBadge = AnimatedSwitcher(
      duration: WoiMotion.medium,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.7, end: 1.0).animate(a),
          child: c,
        ),
      ),
      child: icon == null
          ? LowFpsSpinner(key: const ValueKey('spin'), color: color)
          : Pill(
              key: ValueKey(t.status),
              label: label,
              color: color,
              icon: icon,
              dense: true,
            ),
    );

    return Semantics(
      container: true,
      button: true,
      expanded: _open,
      label: '${toolTitle(t.name)} $summary, $label',
      child: Padding(
        padding: const EdgeInsets.only(left: 38, top: 4, bottom: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: AnimatedContainer(
              duration: WoiMotion.slow,
              curve: WoiMotion.curve,
              decoration: BoxDecoration(
                color: WoiColors.bg1,
                borderRadius: BorderRadius.circular(WoiRadii.md),
                border: Border.all(
                  color: color.withValues(alpha: busy ? 0.6 : 0.25),
                ),
              ),
              // Clip only while the progress sweep runs along the bottom
              // edge; the ink splash is shaped by the InkWell's radius.
              clipBehavior: busy ? Clip.antiAlias : Clip.none,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(WoiRadii.md),
                  onTap: () => setState(() => _open = !_open),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                        child: Row(
                          children: [
                            AnimatedContainer(
                              duration: WoiMotion.medium,
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.13),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(
                                _toolIcons[t.name] ?? Icons.extension,
                                size: 16,
                                color: color,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              toolTitle(t.name),
                              style: body(13, weight: FontWeight.w600),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                summary,
                                style: mono(12, color: WoiColors.textDim),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (elapsed != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text(
                                  '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
                                  style: mono(
                                    11,
                                    color: WoiColors.textFaint,
                                  ).copyWith(fontFeatures: kTabular),
                                ),
                              ),
                            statusBadge,
                            const SizedBox(width: 2),
                            AnimatedRotation(
                              turns: _open ? 0.5 : 0,
                              duration: WoiMotion.medium,
                              child: const Icon(Icons.expand_more, size: 18),
                            ),
                          ],
                        ),
                      ),
                      if (busy) _ProgressSweep(color: color),
                      AnimatedSize(
                        duration: WoiMotion.medium,
                        curve: WoiMotion.curve,
                        alignment: Alignment.topCenter,
                        child: _open
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                child: _ToolDetails(
                                  info: t,
                                  args: args,
                                  result: result,
                                  click: click,
                                  screenshot: widget.screenshot,
                                  viewer: widget.viewer,
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressSweep extends StatefulWidget {
  const _ProgressSweep({required this.color});
  final Color color;
  @override
  State<_ProgressSweep> createState() => _ProgressSweepState();
}

class _ProgressSweepState extends State<_ProgressSweep> {
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: LowFpsBuilder(
      period: const Duration(milliseconds: 1200),
      builder: (context, v) => FractionallySizedBox(
        alignment: Alignment(-1.5 + 3 * v, 0),
        widthFactor: 0.4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                widget.color.withValues(alpha: 0),
                widget.color,
                widget.color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ToolDetails extends StatelessWidget {
  const _ToolDetails({
    required this.info,
    required this.args,
    required this.result,
    required this.click,
    required this.screenshot,
    required this.viewer,
  });
  final ToolCallInfo info;
  final Map<String, Object?> args;
  final Map<String, Object?> result;
  final Offset? click;
  final ImageAttachment? screenshot;
  final MediaViewer? viewer;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final err = result['error'];
    switch (info.name) {
      case 'run_bash':
        children.add(
          _Terminal(
            command: '${args['command'] ?? ''}',
            result: result,
            cwd: args['cwd'] as String?,
          ),
        );
      case 'click_screen':
      case 'control_pointer':
        final shot = screenshot;
        if (click != null && shot != null && viewer != null) {
          children.add(
            LayoutBuilder(
              builder: (context, box) {
                final thumb = ScreenshotThumb(
                  image: shot,
                  viewer: viewer!,
                  marker: click,
                  maxWidth: 280,
                );
                final details = _kvList({...args, ...result});
                return box.maxWidth < 520
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [thumb, const SizedBox(height: 8), details],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          thumb,
                          const SizedBox(width: 12),
                          Expanded(child: details),
                        ],
                      );
              },
            ),
          );
        } else {
          children.add(_kvList({...args, ...result}));
        }
      case 'read_file':
        final content = result['content'];
        if (content is String) {
          children.add(
            _CodeBlock(
              text: content,
              path: '${args['path'] ?? ''}',
              firstLine: (result['from_line'] as num?)?.toInt() ?? 1,
              maxLines: 40,
            ),
          );
        } else {
          children.add(_kvList(result));
        }
      case 'list_dir':
        final entries = result['entries'];
        if (entries is List) {
          children.add(
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in entries.take(80))
                  if (e is Map)
                    Pill(
                      label: '${e['name']}${e['t'] == 'd' ? '/' : ''}',
                      icon: e['t'] == 'd'
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      color: e['t'] == 'd' ? WoiColors.cyan : WoiColors.textDim,
                      dense: true,
                    ),
                if (result['more'] != null)
                  Pill(
                    label: '+${result['more']} more',
                    color: WoiColors.textFaint,
                    dense: true,
                  ),
              ],
            ),
          );
        } else {
          children.add(_kvList(result));
        }
      case 'delegate_task':
        children.add(_kvList({'task': args['task']}));
        final text = result['result'] ?? result['text'] ?? result['answer'];
        if (text != null) {
          children.add(const SizedBox(height: 8));
          children.add(SelectableText('$text', style: body(13, height: 1.45)));
        } else {
          children.add(_kvList(result));
        }
      default:
        children.add(_kvList({...args, ...result}));
    }
    if (err != null && info.name != 'run_bash') {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('$err', style: mono(12, color: WoiColors.red)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _kvList(Map<String, Object?> m) {
    final entries = m.entries
        .where((e) => e.key != 'ok' && e.key != 'raw' && e.value != null)
        .toList();
    if (entries.isEmpty) {
      final raw = m['raw'];
      return Text(
        raw == null ? 'No details' : '$raw',
        style: mono(12, color: WoiColors.textDim),
      );
    }
    String fmt(Object? v) {
      if (v is String) return v;
      try {
        return const JsonEncoder.withIndent('  ').convert(v);
      } catch (_) {
        return '$v';
      }
    }

    return Container(
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        child: SelectableText.rich(
          TextSpan(
            children: [
              for (final e in entries) ...[
                TextSpan(
                  text: '${e.key.padRight(10)} ',
                  style: mono(12, color: WoiColors.textFaint),
                ),
                TextSpan(
                  text: '${fmt(e.value)}\n',
                  style: mono(12, color: WoiColors.text),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Terminal-style block for run_bash: prompt line, stdout, stderr, exit.
class _Terminal extends StatelessWidget {
  const _Terminal({required this.command, required this.result, this.cwd});
  final String command;
  final Map<String, Object?> result;
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    final out = result['stdout'] as String? ?? '';
    final err =
        (result['stderr'] as String? ?? '') +
        (result['error'] != null ? '${result['error']}' : '');
    final code = result['exit_code'];
    final ms = result['ms'];
    final ok = code == 0;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xE6050810),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WoiColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: WoiColors.stroke)),
            ),
            child: Row(
              children: [
                for (final c in const [
                  Color(0xFFFF5F57),
                  Color(0xFFFEBC2E),
                  Color(0xFF28C840),
                ])
                  Container(
                    margin: const EdgeInsets.only(right: 5),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.withValues(alpha: 0.7),
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cwd ?? 'bash',
                    style: mono(11, color: WoiColors.textFaint),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (code != null)
                  Pill(
                    label: 'exit $code',
                    color: ok ? WoiColors.mint : WoiColors.red,
                    dense: true,
                  ),
                if (result['timed_out'] == true) ...[
                  const SizedBox(width: 6),
                  Pill(label: 'timed out', color: WoiColors.amber, dense: true),
                ],
                if (ms != null) ...[
                  const SizedBox(width: 8),
                  Text('${ms}ms', style: mono(11, color: WoiColors.textFaint)),
                ],
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: r'$ ',
                        style: mono(12.5, color: WoiColors.mint),
                      ),
                      TextSpan(
                        text: '$command\n',
                        style: mono(12.5, color: const Color(0xFFE8EEF8)),
                      ),
                      if (out.isNotEmpty)
                        TextSpan(
                          text: out.endsWith('\n') ? out : '$out\n',
                          style: mono(12, color: const Color(0xFFC9D6EA)),
                        ),
                      if (err.isNotEmpty)
                        TextSpan(
                          text: err,
                          style: mono(12, color: WoiColors.red),
                        ),
                      if (out.isEmpty && err.isEmpty && code != null)
                        TextSpan(
                          text: '(no output)',
                          style: mono(12, color: WoiColors.textFaint),
                        ),
                      if (result['truncated'] == true)
                        TextSpan(
                          text: '\n… output truncated',
                          style: mono(12, color: WoiColors.amber),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only code preview with line numbers and syntax colours.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.text,
    required this.path,
    this.firstLine = 1,
    this.maxLines = 40,
  });
  final String text;
  final String path;
  final int firstLine;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final all = text.split('\n');
    final lines = all.take(maxLines).toList();
    final lang = langForPath(path);
    final gutter = '${firstLine + lines.length}'.length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: const Color(0xE6050810),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: SelectableText.rich(
            TextSpan(
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  TextSpan(
                    text: '${'${firstLine + i}'.padLeft(gutter)}  ',
                    style: mono(12, color: WoiColors.textFaint),
                  ),
                  ...highlightLine(lines[i], lang, size: 12),
                  const TextSpan(text: '\n'),
                ],
                if (all.length > maxLines)
                  TextSpan(
                    text: '… ${all.length - maxLines} more lines',
                    style: mono(12, color: WoiColors.textFaint),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- system

/// Rewrites raw token counts ("46212 → 44778 tokens") as "46.2k → 44.8k tokens".
String humanizeTokenCounts(String text) => text.replaceAllMapped(
  RegExp(r'\b\d{4,}\b'),
  (m) => formatTokens(int.parse(m[0]!)),
);

class _SystemNote extends StatelessWidget {
  const _SystemNote({required this.message, required this.viewer});
  final Message message;
  final MediaViewer viewer;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final type = m.meta['type'];
    final (color, icon) = switch (type) {
      'compaction' => (WoiColors.violet, Icons.compress),
      'error' => (WoiColors.red, Icons.warning_amber_rounded),
      'notice' => (WoiColors.amber, Icons.info_outline),
      'screenshot' => (WoiColors.cyan, Icons.screenshot_monitor),
      'camera' => (WoiColors.cyan, Icons.videocam_outlined),
      'media' => (WoiColors.cyan, Icons.perm_media_outlined),
      _ => (WoiColors.textDim, Icons.info_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 1,
                    color: color.withValues(alpha: 0.12),
                  ),
                ),
                Flexible(
                  flex: 6,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      // A pill on one line; a rounded box (not an oval) when it wraps on a phone.
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color.withValues(alpha: 0.28)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 14, color: color),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            type == 'compaction'
                                ? humanizeTokenCounts(m.text)
                                : m.text,
                            style: body(
                              12,
                              weight: FontWeight.w500,
                              color: color,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _time(m.createdAt),
                          style: body(11, color: WoiColors.textFaint),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 1,
                    color: color.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
            if (m.image != null) ...[
              const SizedBox(height: 8),
              ScreenshotThumb(
                image: m.image!,
                viewer: viewer,
                tier: imageTierOf(m),
                label: m.image!.generated ? 'Generated image' : imageLabel(m),
                maxWidth: type == 'camera' ? 200 : 300,
              ),
              if (m.image!.generated) _GeneratedImageInfo(image: m.image!),
            ],
          ],
        ),
      ),
    );
  }
}
