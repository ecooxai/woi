import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/message.dart';
import '../../platform/audio_io.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import 'audio_button.dart';
import 'glass.dart';
import 'image_viewer.dart';

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.audio,
    required this.viewer,
    this.maxBubbleWidth = 640,
  });

  final Message message;
  final AudioIO audio;
  final MediaViewer viewer;
  final double maxBubbleWidth;

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
      MessageKind.tool => ToolCallCard(message: m, maxWidth: maxBubbleWidth),
      MessageKind.system => _SystemNote(message: m, viewer: viewer),
    };
    return Opacity(opacity: m.compacted ? 0.45 : 1, child: child);
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
    final r = const Radius.circular(20);
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
          _Thumbnail(image: m.image!, viewer: viewer),
          if (m.text.isNotEmpty || waiting) const SizedBox(height: 10),
        ],
        if (waiting)
          _TypingDots(color: accent, label: isUser ? 'listening' : null)
        else if (m.text.isNotEmpty)
          SelectableText(m.text, style: body(15, height: 1.45, color: WoiColors.text)),
        if (m.audio != null || m.interrupted || !m.streaming) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (m.audio != null) AudioClipButton(clip: m.audio!, audio: audio, color: accent),
              if (m.interrupted)
                const Pill(label: 'interrupted', color: WoiColors.amber, icon: Icons.content_cut, dense: true),
              Text(_time(m.createdAt), style: body(11, color: WoiColors.textFaint)),
            ],
          ),
        ],
      ],
    );

    final bubble = AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: isUser ? Alignment.topRight : Alignment.topLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isUser
                ? [WoiColors.cyan.withValues(alpha: 0.16), WoiColors.blue.withValues(alpha: 0.10)]
                : [WoiColors.violet.withValues(alpha: 0.13), WoiColors.magenta.withValues(alpha: 0.06)],
          ),
          border: Border.all(color: accent.withValues(alpha: 0.22)),
        ),
        child: content,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[const _Avatar(), const SizedBox(width: 10)],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar();
  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const RadialGradient(
        center: Alignment(-0.3, -0.4),
        colors: [Colors.white, WoiColors.magenta, WoiColors.violet],
        stops: [0, 0.35, 1],
      ),
      boxShadow: [BoxShadow(color: WoiColors.magenta.withValues(alpha: 0.5), blurRadius: 12)],
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.image, required this.viewer});
  final ImageAttachment image;
  final MediaViewer viewer;

  @override
  Widget build(BuildContext context) {
    final file = File(image.path);
    final aspect = image.width > 0 && image.height > 0 ? image.width / image.height : 16 / 9;
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: () => showImageLightbox(
          context,
          image.path,
          caption: 'Screenshot · ${image.originalWidth}×${image.originalHeight} (sent ${image.width}×${image.height})',
          onOpenWindow: () => viewer.show(MediaItem(kind: MediaKind.image, path: image.path)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: AspectRatio(
            aspectRatio: aspect,
            child: Hero(
              tag: image.path,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      file,
                      fit: BoxFit.cover,
                      cacheWidth: 600,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, e, s) => Container(
                        color: WoiColors.glass,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined),
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
    );
  }
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: body(13, color: widget.color.withValues(alpha: 0.8))),
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
};

String _toolTitle(String name) => switch (name) {
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
  _ => name,
};

String _argSummary(String name, String argsJson) {
  try {
    final a = (jsonDecode(argsJson) as Map).cast<String, Object?>();
    final s = switch (name) {
      'run_bash' => a['command'],
      'read_file' || 'list_dir' || 'write_file' || 'edit_file' || 'show_file' => a['path'],
      'type_text' => '"${a['text']}"',
      'key_combo' => a['keys'],
      'click_screen' =>
        '(${a['x']}, ${a['y']})${a['double'] == true ? ' ×2' : ''}${a['button'] != null && a['button'] != 'left' ? ' ${a['button']}' : ''}',
      'delegate_task' => a['task'],
      _ => a.isEmpty ? '' : argsJson,
    };
    return '${s ?? ''}';
  } catch (_) {
    return argsJson;
  }
}

class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.message, this.maxWidth = 640});
  final Message message;
  final double maxWidth;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _open = false;

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
    final summary = _argSummary(t.name, t.argsJson);
    final elapsed = t.finishedAt?.difference(t.startedAt);
    final busy = t.status == ToolStatus.running || t.status == ToolStatus.pending;

    return Padding(
      padding: const EdgeInsets.only(left: 38, top: 4, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              color: WoiColors.bg1.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: busy ? 0.55 : 0.25)),
              boxShadow: busy ? [BoxShadow(color: color.withValues(alpha: 0.15), blurRadius: 16)] : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: t.resultJson == null ? null : () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(_toolIcons[t.name] ?? Icons.extension, size: 16, color: color),
                          ),
                          const SizedBox(width: 10),
                          Text(_toolTitle(t.name), style: body(13, weight: FontWeight.w600)),
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
                                style: mono(11, color: WoiColors.textFaint),
                              ),
                            ),
                          if (icon == null)
                            SizedBox.square(
                              dimension: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
                            )
                          else
                            Pill(label: label, color: color, icon: icon, dense: true),
                          if (t.resultJson != null)
                            AnimatedRotation(
                              turns: _open ? 0.5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(Icons.expand_more, size: 18),
                            ),
                        ],
                      ),
                      AnimatedCrossFade(
                        duration: const Duration(milliseconds: 200),
                        crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                        firstChild: const SizedBox(width: double.infinity),
                        secondChild: _ResultView(json: t.resultJson ?? '', args: t.argsJson),
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

class _ResultView extends StatelessWidget {
  const _ResultView({required this.json, required this.args});
  final String json;
  final String args;

  @override
  Widget build(BuildContext context) {
    String pretty(String s) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(s));
      } catch (_) {
        return s;
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(10)),
      child: SingleChildScrollView(
        child: SelectableText(
          'args   ${pretty(args)}\nresult ${pretty(json)}',
          style: mono(11.5, color: WoiColors.textDim),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- system

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
      _ => (WoiColors.textDim, Icons.info_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
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
                      m.text,
                      style: body(12, weight: FontWeight.w500, color: color),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_time(m.createdAt), style: body(11, color: WoiColors.textFaint)),
                ],
              ),
            ),
            if (m.image != null) ...[const SizedBox(height: 8), _Thumbnail(image: m.image!, viewer: viewer)],
          ],
        ),
      ),
    );
  }
}
