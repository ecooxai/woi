import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../platform/audio_io.dart';
import '../../platform/media_viewer.dart';
import '../theme.dart';
import '../widgets/glass.dart';

/// App shown in a secondary desktop window (desktop_multi_window).
class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key, required this.item, required this.audio});
  final MediaItem item;
  final AudioIO audio;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Woi · ${item.title}',
    theme: buildWoiTheme(),
    home: Scaffold(
      body: WoiBackdrop(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: ViewerTitle(item: item),
              ),
              Expanded(
                child: MediaBody(item: item, audio: audio),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class ViewerTitle extends StatelessWidget {
  const ViewerTitle({super.key, required this.item, this.trailing});
  final MediaItem item;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      MediaKind.image => Icons.image_outlined,
      MediaKind.audio => Icons.graphic_eq,
      MediaKind.video => Icons.movie_outlined,
      MediaKind.text => Icons.description_outlined,
    };
    return Row(
      children: [
        Icon(icon, color: WoiColors.cyan, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: display(16), overflow: TextOverflow.ellipsis),
              if (item.path != null)
                Text(
                  item.path!,
                  style: mono(11, color: WoiColors.textFaint),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Renders a [MediaItem]; shared by the secondary window and the overlay.
class MediaBody extends StatelessWidget {
  const MediaBody({super.key, required this.item, required this.audio});
  final MediaItem item;
  final AudioIO audio;

  @override
  Widget build(BuildContext context) => switch (item.kind) {
    MediaKind.image => _ImageBody(path: item.path ?? ''),
    MediaKind.text => _TextBody(item: item),
    MediaKind.audio => _AudioBody(path: item.path ?? '', audio: audio),
    MediaKind.video => _Message(
      icon: Icons.movie_outlined,
      text: 'Videos open in VLC (mpv/libmpv is not installed, so in-app video is disabled).',
    ),
  };
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: WoiColors.textDim),
          const SizedBox(height: 12),
          Text(
            text,
            style: body(14, color: WoiColors.textDim),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _ImageBody extends StatelessWidget {
  const _ImageBody({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => InteractiveViewer(
    maxScale: 8,
    child: Center(
      child: Image.file(
        File(path),
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, e, s) => _Message(icon: Icons.broken_image_outlined, text: 'Cannot open $path'),
      ),
    ),
  );
}

class _TextBody extends StatefulWidget {
  const _TextBody({required this.item});
  final MediaItem item;
  @override
  State<_TextBody> createState() => _TextBodyState();
}

class _TextBodyState extends State<_TextBody> {
  static const _maxBytes = 2 * 1024 * 1024;
  late final Future<String> _text = _load();

  Future<String> _load() async {
    if (widget.item.text != null) return widget.item.text!;
    final f = File(widget.item.path ?? '');
    final len = await f.length();
    final raf = await f.open();
    try {
      final bytes = await raf.read(len > _maxBytes ? _maxBytes : len);
      final s = String.fromCharCodes(bytes.where((b) => b != 0));
      return len > _maxBytes ? '$s\n\n… (truncated, ${len ~/ 1024} KiB total)' : s;
    } finally {
      await raf.close();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _text,
    builder: (context, snap) {
      if (snap.hasError) return _Message(icon: Icons.error_outline, text: '${snap.error}');
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      final lines = snap.data!.split('\n');
      final gutter = '${lines.length}'.length;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: GlassPanel(
          padding: EdgeInsets.zero,
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    for (var i = 0; i < lines.length; i++) ...[
                      TextSpan(
                        text: '${'${i + 1}'.padLeft(gutter)}  ',
                        style: mono(12.5, color: WoiColors.textFaint),
                      ),
                      TextSpan(text: '${lines[i]}\n', style: mono(12.5, height: 1.5)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _AudioBody extends StatefulWidget {
  const _AudioBody({required this.path, required this.audio});
  final String path;
  final AudioIO audio;
  @override
  State<_AudioBody> createState() => _AudioBodyState();
}

class _AudioBodyState extends State<_AudioBody> {
  ClipPlayback? _clip;
  String? _error;

  Future<void> _toggle() async {
    if (_clip != null) {
      await _clip!.stop();
      return;
    }
    try {
      final c = await widget.audio.playFile(widget.path);
      setState(() => _clip = c);
      unawaited(
        c.done.whenComplete(() {
          if (mounted) setState(() => _clip = null);
        }),
      );
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _clip?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          iconSize: 40,
          style: IconButton.styleFrom(minimumSize: const Size(88, 88)),
          onPressed: _toggle,
          icon: Icon(_clip == null ? Icons.play_arrow_rounded : Icons.stop_rounded),
        ),
        const SizedBox(height: 12),
        Text(_error ?? (_clip == null ? 'Play' : 'Playing…'), style: body(13, color: WoiColors.textDim)),
      ],
    ),
  );
}

/// In-app overlay used when no secondary window is available.
Future<void> showMediaOverlay(BuildContext context, MediaItem item, AudioIO audio) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: size.width * 0.85,
          height: size.height * 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                child: ViewerTitle(
                  item: item,
                  trailing: IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ),
              ),
              Expanded(
                child: MediaBody(item: item, audio: audio),
              ),
            ],
          ),
        ),
      );
    },
  );
}
