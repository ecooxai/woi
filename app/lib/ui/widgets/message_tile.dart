import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/context/image_tiers.dart';
import '../../core/models/message.dart';
import '../../platform/audio_io.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import 'audio_button.dart';
import 'code_highlight.dart';
import 'context_meter.dart' show formatTokens;
import 'glass.dart';
import 'image_viewer.dart';

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.audio,
    required this.viewer,
    this.maxBubbleWidth = 640,
    this.screenshot,
  });

  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final double maxBubbleWidth;

  /// Latest screenshot before this message (click markers on tool cards).
  final ImageAttachment? screenshot;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final child = switch (m.kind) {
      MessageKind.user => _Bubble(message: m, audio: audio, viewer: viewer, maxWidth: maxBubbleWidth, isUser: true),
      MessageKind.assistant => _Bubble(
        message: m,
        audio: audio,
        viewer: viewer,
        maxWidth: maxBubbleWidth,
        isUser: false,
      ),
      MessageKind.tool => ToolCallCard(message: m, maxWidth: maxBubbleWidth, screenshot: screenshot, viewer: viewer),
      MessageKind.system => _SystemNote(message: m, viewer: viewer),
    };
    return EntryAnimation(
      animate: DateTime.now().difference(m.createdAt) < const Duration(seconds: 3),
      fromRight: m.kind == MessageKind.user,
      child: AnimatedOpacity(duration: WoiMotion.slow, opacity: m.compacted ? 0.45 : 1, child: child),
    );
  }
}

/// Fade + rise + slight scale on first build (new messages only).
class EntryAnimation extends StatelessWidget {
  const EntryAnimation({super.key, required this.child, this.animate = true, this.fromRight = false});
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
          Text('Voice message', style: body(14, weight: FontWeight.w500, color: WoiColors.textDim)),
        ],
      ),
    );
  }
}

String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.audio,
    required this.viewer,
    required this.maxWidth,
    required this.isUser,
  });

  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final double maxWidth;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final accent = isUser ? WoiColors.cyan : WoiColors.violet;
    final waiting = m.streaming && m.text.isEmpty;
    const r = Radius.circular(WoiRadii.lg);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: isUser ? r : const Radius.circular(6),
      bottomRight: isUser ? const Radius.circular(6) : r,
    );

    final content = Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.image != null) ...[
          ScreenshotThumb(image: m.image!, viewer: viewer, tier: imageTierOf(m), label: imageLabel(m)),
          if (m.text.isNotEmpty || waiting) const SizedBox(height: 10),
        ],
        if (waiting)
          _TypingDots(color: accent, label: isUser ? 'listening' : null)
        else if (isSpeechPlaceholder(m.text))
          _VoiceLabel(text: m.text, color: accent)
        else if (isUser && m.streaming && m.text.isNotEmpty)
          // Live partial transcript; finalized when the transcription completes.
          Text(m.text, style: body(15, height: 1.5, color: WoiColors.textDim).copyWith(fontStyle: FontStyle.italic))
        else if (m.text.isNotEmpty)
          SelectableText(m.text, style: body(15, height: 1.5, color: WoiColors.text)),
        if (m.audio != null || m.interrupted || !m.streaming) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (m.audio != null) AudioClipButton(clip: m.audio!, audio: audio, color: accent),
              if (m.interrupted)
                Pill(label: 'interrupted', color: WoiColors.amber, icon: Icons.content_cut, dense: true),
              Text(_time(m.createdAt), style: body(11, color: WoiColors.textFaint)),
            ],
          ),
        ],
      ],
    );

    final bubble = AnimatedSize(
      duration: WoiMotion.medium,
      curve: WoiMotion.curve,
      alignment: isUser ? Alignment.topRight : Alignment.topLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        decoration: BoxDecoration(
          borderRadius: radius,
          color: isUser ? WoiColors.cyan.withValues(alpha: WoiColors.palette.isDark ? 0.16 : 0.08) : WoiColors.bg2,
          border: Border.all(color: isUser ? WoiColors.cyan.withValues(alpha: 0.16) : WoiColors.stroke),
        ),
        child: content,
      ),
    );

    return Semantics(
      container: true,
      label: isUser ? 'You said' : 'Woi said',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isUser) ...[_Avatar(active: m.streaming), const SizedBox(width: 10)],
            Flexible(child: bubble),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.active = false});
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
      child: Text('W', style: display(12, weight: FontWeight.w700, color: WoiColors.bg1)),
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
    this.tier = ImageTier.full,
    this.label = 'Screenshot',
  });
  final ImageAttachment image;

  /// "Screenshot", "Camera frame", "Media image" ([imageLabel]).
  final String label;

  /// How the model currently has it; the thumbnail is always the original.
  final ImageTier tier;
  final MediaViewer viewer;
  final Offset? marker;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final file = File(image.path);
    final aspect = image.width > 0 && image.height > 0 ? image.width / image.height : 16 / 9;
    final mk = marker;
    return Semantics(
      button: true,
      image: true,
      label: mk == null ? '$label. Tap to enlarge' : '$label with click at ${mk.dx.round()}, ${mk.dy.round()}',
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          onTap: () => showImageLightbox(
            context,
            image.path,
            caption:
                '$label · ${image.originalWidth}×${image.originalHeight} (sent ${image.width}×${image.height})'
                '${mk != null ? ' · click (${mk.dx.round()}, ${mk.dy.round()})' : ''}',
            marker: mk == null || image.width <= 0 ? null : Offset(mk.dx / image.width, mk.dy / image.height),
            onOpenWindow: () => viewer.show(MediaItem(kind: MediaKind.image, path: image.path)),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: AspectRatio(
              aspectRatio: aspect,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WoiColors.strokeStrong),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        file,
                        fit: BoxFit.cover,
                        cacheWidth: 640,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, e, s) => Container(
                          color: WoiColors.glass,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                      if (mk != null && image.width > 0 && image.height > 0)
                        LayoutBuilder(
                          builder: (context, box) => ClickMarker(
                            position: Offset(
                              mk.dx / image.width * box.maxWidth,
                              mk.dy / image.height * box.maxHeight,
                            ),
                          ),
                        ),
                      if (tier != ImageTier.full)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Tooltip(
                            message: tier == ImageTier.reduced
                                ? 'Older ${label.toLowerCase()}: the model now has it at ⅕ size'
                                : 'Old ${label.toLowerCase()}: the model now has a text description',
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                              child: Text(
                                tier == ImageTier.reduced ? 'sent ⅕' : 'described',
                                style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                          child: const Icon(Icons.zoom_out_map, size: 14, color: Colors.white),
                        ),
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

/// Pulsing crosshair target drawn at a click position.
class ClickMarker extends StatefulWidget {
  const ClickMarker({super.key, required this.position, this.color, this.size = 26});
  final Offset position;
  final Color? color;
  final double size;

  @override
  State<ClickMarker> createState() => _ClickMarkerState();
}

class _ClickMarkerState extends State<ClickMarker> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
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
    builder: (context, _) => CustomPaint(painter: _MarkerPainter(widget.position, widget.color ?? WoiColors.amber, widget.size, _c.value)),
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
    canvas.drawCircle(p, r * (0.6 + 0.9 * t), stroke..color = color.withValues(alpha: 1 - t));
    stroke.color = color;
    canvas.drawCircle(p, r * 0.55, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawCircle(p, r * 0.55, stroke);
    canvas.drawCircle(p, 2.5, Paint()..color = color);
    for (final d in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]) {
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

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
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
            Text(widget.label!, style: body(13, color: widget.color.withValues(alpha: 0.85))),
            const SizedBox(width: 8),
          ],
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Row(
              children: List.generate(3, (i) {
                final v = ((_c.value * 3 - i) % 3);
                final a = v < 1 ? (1 - (v - 0.5).abs() * 2).clamp(0.25, 1.0) : 0.25;
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
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ tools

const _toolIcons = <String, IconData>{
  'take_screenshot': Icons.screenshot_monitor,
  'click_screen': Icons.ads_click,
  'type_text': Icons.keyboard,
  'key_combo': Icons.keyboard_command_key,
  'run_bash': Icons.terminal,
  'read_file': Icons.description_outlined,
  'list_dir': Icons.folder_open,
  'write_file': Icons.save_outlined,
  'edit_file': Icons.edit_note,
  'show_file': Icons.open_in_new,
  'delegate_task': Icons.hub_outlined,
  'read_note': Icons.sticky_note_2_outlined,
  'update_note': Icons.edit_note,
};

String toolTitle(String name) => switch (name) {
  'take_screenshot' => 'Screenshot',
  'click_screen' => 'Click',
  'type_text' => 'Type text',
  'key_combo' => 'Key combo',
  'run_bash' => 'Shell command',
  'read_file' => 'Read file',
  'list_dir' => 'List folder',
  'write_file' => 'Write file',
  'edit_file' => 'Edit file',
  'show_file' => 'Show file',
  'delegate_task' => 'Delegate task',
  'read_note' => 'Read note',
  'update_note' => 'Update note',
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
    'read_file' || 'list_dir' || 'write_file' || 'edit_file' || 'show_file' => a['path'],
    'type_text' => '"${a['text']}"',
    'key_combo' => a['keys'],
    'click_screen' =>
      '(${a['x']}, ${a['y']})${a['double'] == true ? ' ×2' : ''}${a['button'] != null && a['button'] != 'left' ? ' ${a['button']}' : ''}',
    'delegate_task' => a['task'],
    'read_note' => '',
    'update_note' => switch (a['mode']) {
      'check_item' => '${a['checked'] == false ? 'uncheck' : 'check'} "${a['item'] ?? ''}"',
      'replace_section' => 'section "${a['heading'] ?? ''}"',
      'replace_all' => 'rewrite note',
      _ => '${a['text'] ?? ''}'.split('\n').first,
    },
    _ => a.isEmpty ? '' : argsJson,
  };
  return '${s ?? ''}';
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
      ToolStatus.awaitingApproval => (WoiColors.amber, 'needs approval', Icons.front_hand_outlined),
      ToolStatus.running => (WoiColors.cyan, 'running', null),
      ToolStatus.success => (WoiColors.mint, 'done', Icons.check_rounded),
      ToolStatus.error => (WoiColors.red, 'failed', Icons.error_outline),
      ToolStatus.denied => (WoiColors.amber, 'rejected', Icons.block),
    };
    final summary = toolArgSummary(t.name, t.argsJson);
    final elapsed = t.finishedAt?.difference(t.startedAt);
    final busy = t.status == ToolStatus.running || t.status == ToolStatus.pending;
    final args = _decode(t.argsJson);
    final click = t.name == 'click_screen' && args['x'] is num && args['y'] is num
        ? Offset((args['x'] as num).toDouble(), (args['y'] as num).toDouble())
        : null;

    final statusBadge = AnimatedSwitcher(
      duration: WoiMotion.medium,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(a), child: c),
      ),
      child: icon == null
          ? SizedBox.square(
              key: const ValueKey('spin'),
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
            )
          : Pill(key: ValueKey(t.status), label: label, color: color, icon: icon, dense: true),
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
                border: Border.all(color: color.withValues(alpha: busy ? 0.6 : 0.25)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
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
                              child: Icon(_toolIcons[t.name] ?? Icons.extension, size: 16, color: color),
                            ),
                            const SizedBox(width: 10),
                            Text(toolTitle(t.name), style: body(13, weight: FontWeight.w600)),
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
                                  style: mono(11, color: WoiColors.textFaint).copyWith(fontFeatures: kTabular),
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
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                child: _ToolDetails(
                                  info: t,
                                  args: args,
                                  result: _decode(t.resultJson),
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

class _ProgressSweepState extends State<_ProgressSweep> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => FractionallySizedBox(
        alignment: Alignment(-1.5 + 3 * _c.value, 0),
        widthFactor: 0.4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [widget.color.withValues(alpha: 0), widget.color, widget.color.withValues(alpha: 0)]),
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
        children.add(_Terminal(command: '${args['command'] ?? ''}', result: result, cwd: args['cwd'] as String?));
      case 'click_screen':
        final shot = screenshot;
        if (click != null && shot != null && viewer != null) {
          children.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ScreenshotThumb(image: shot, viewer: viewer!, marker: click, maxWidth: 280),
                const SizedBox(width: 12),
                Expanded(child: _kvList({...args, ...result})),
              ],
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
                      icon: e['t'] == 'd' ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                      color: e['t'] == 'd' ? WoiColors.cyan : WoiColors.textDim,
                      dense: true,
                    ),
                if (result['more'] != null) Pill(label: '+${result['more']} more', color: WoiColors.textFaint, dense: true),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _kvList(Map<String, Object?> m) {
    final entries = m.entries.where((e) => e.key != 'ok' && e.key != 'raw' && e.value != null).toList();
    if (entries.isEmpty) {
      final raw = m['raw'];
      return Text(raw == null ? 'No details' : '$raw', style: mono(12, color: WoiColors.textDim));
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
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.32), borderRadius: BorderRadius.circular(10)),
      child: SingleChildScrollView(
        child: SelectableText.rich(
          TextSpan(
            children: [
              for (final e in entries) ...[
                TextSpan(text: '${e.key.padRight(10)} ', style: mono(12, color: WoiColors.textFaint)),
                TextSpan(text: '${fmt(e.value)}\n', style: mono(12, color: WoiColors.text)),
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
    final err = (result['stderr'] as String? ?? '') + (result['error'] != null ? '${result['error']}' : '');
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
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: WoiColors.stroke))),
            child: Row(
              children: [
                for (final c in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)])
                  Container(
                    margin: const EdgeInsets.only(right: 5),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: c.withValues(alpha: 0.7), shape: BoxShape.circle),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(cwd ?? 'bash', style: mono(11, color: WoiColors.textFaint), overflow: TextOverflow.ellipsis),
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
                      TextSpan(text: r'$ ', style: mono(12.5, color: WoiColors.mint)),
                      TextSpan(text: '$command\n', style: mono(12.5, color: const Color(0xFFE8EEF8))),
                      if (out.isNotEmpty) TextSpan(text: out.endsWith('\n') ? out : '$out\n', style: mono(12, color: const Color(0xFFC9D6EA))),
                      if (err.isNotEmpty) TextSpan(text: err, style: mono(12, color: WoiColors.red)),
                      if (out.isEmpty && err.isEmpty && code != null)
                        TextSpan(text: '(no output)', style: mono(12, color: WoiColors.textFaint)),
                      if (result['truncated'] == true)
                        TextSpan(text: '\n… output truncated', style: mono(12, color: WoiColors.amber)),
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
  const _CodeBlock({required this.text, required this.path, this.firstLine = 1, this.maxLines = 40});
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
      decoration: BoxDecoration(color: const Color(0xE6050810), borderRadius: BorderRadius.circular(10)),
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: SelectableText.rich(
            TextSpan(
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  TextSpan(text: '${'${firstLine + i}'.padLeft(gutter)}  ', style: mono(12, color: WoiColors.textFaint)),
                  ...highlightLine(lines[i], lang, size: 12),
                  const TextSpan(text: '\n'),
                ],
                if (all.length > maxLines)
                  TextSpan(text: '… ${all.length - maxLines} more lines', style: mono(12, color: WoiColors.textFaint)),
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
String humanizeTokenCounts(String text) =>
    text.replaceAllMapped(RegExp(r'\b\d{4,}\b'), (m) => formatTokens(int.parse(m[0]!)));

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
                Expanded(child: Container(height: 1, color: color.withValues(alpha: 0.12))),
                Flexible(
                  flex: 6,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: color.withValues(alpha: 0.28)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 14, color: color),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            type == 'compaction' ? humanizeTokenCounts(m.text) : m.text,
                            style: body(12, weight: FontWeight.w500, color: color),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_time(m.createdAt), style: body(11, color: WoiColors.textFaint)),
                      ],
                    ),
                  ),
                ),
                Expanded(child: Container(height: 1, color: color.withValues(alpha: 0.12))),
              ],
            ),
            if (m.image != null) ...[
              const SizedBox(height: 8),
              ScreenshotThumb(
                image: m.image!,
                viewer: viewer,
                tier: imageTierOf(m),
                label: imageLabel(m),
                maxWidth: type == 'camera' ? 200 : 300,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
