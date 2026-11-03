import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../platform/audio_io.dart';
import '../../platform/linux/exec_util.dart' show which, x11Env;
import '../../platform/media_viewer.dart';
import '../theme.dart';
import '../widgets/code_highlight.dart';
import '../widgets/glass.dart';
import '../widgets/image_viewer.dart';

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
              Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 6), child: ViewerTitle(item: item)),
              Expanded(child: MediaBody(item: item, audio: audio)),
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
    final (icon, color) = switch (item.kind) {
      MediaKind.image => (Icons.image_outlined, WoiColors.cyan),
      MediaKind.audio => (Icons.graphic_eq, WoiColors.violet),
      MediaKind.video => (Icons.movie_outlined, WoiColors.magenta),
      MediaKind.text => (Icons.description_outlined, WoiColors.mint),
    };
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: display(16), overflow: TextOverflow.ellipsis),
              if (item.path != null)
                Text(item.path!, style: mono(11, color: WoiColors.textFaint), overflow: TextOverflow.ellipsis),
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
    MediaKind.image => ZoomableImage(file: File(item.path ?? '')),
    MediaKind.text => TextViewerBody(item: item),
    MediaKind.audio => AudioViewerBody(path: item.path ?? '', audio: audio),
    MediaKind.video => _VideoBody(path: item.path ?? ''),
  };
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: WoiColors.textDim),
          const SizedBox(height: 12),
          Text(text, style: body(14, color: WoiColors.textDim), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------- video

class _VideoBody extends StatefulWidget {
  const _VideoBody({required this.path});
  final String path;
  @override
  State<_VideoBody> createState() => _VideoBodyState();
}

class _VideoBodyState extends State<_VideoBody> {
  String? _status;

  Future<void> _open() async {
    final player = which('vlc') ?? which('mpv') ?? which('xdg-open');
    if (player == null) {
      setState(() => _status = 'No video player found. Install VLC.');
      return;
    }
    try {
      await Process.start(player, [widget.path], mode: ProcessStartMode.detached, environment: x11Env());
      setState(() => _status = 'Opened in ${player.split('/').last}');
    } catch (e) {
      setState(() => _status = 'Could not start $player: $e');
    }
  }

  @override
  Widget build(BuildContext context) => _Message(
    icon: Icons.movie_outlined,
    text: _status ?? 'Video plays in VLC (in-app video needs libmpv, which is not installed).',
    action: FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, kTouchTarget)),
      onPressed: _open,
      icon: const Icon(Icons.play_circle_outline),
      label: const Text('Open in VLC'),
    ),
  );
}

// -------------------------------------------------------------------- text

class TextViewerBody extends StatefulWidget {
  const TextViewerBody({super.key, required this.item});
  final MediaItem item;
  @override
  State<TextViewerBody> createState() => _TextViewerBodyState();
}

class _TextViewerBodyState extends State<TextViewerBody> {
  static const _maxBytes = 2 * 1024 * 1024;
  late final Future<String> _text = _load();
  bool _wrap = false;

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

  CodeLang get _lang {
    final l = widget.item.language;
    if (l != null && l.isNotEmpty) return langForPath('x.$l');
    return langForPath(widget.item.path ?? widget.item.title);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _text,
    builder: (context, snap) {
      if (snap.hasError) return _Message(icon: Icons.error_outline, text: '${snap.error}');
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      final lines = snap.data!.split('\n');
      final gutter = '${lines.length}'.length;
      final lang = lines.length > 20000 ? CodeLang.plain : _lang;
      final text = SelectableText.rich(
        TextSpan(
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              TextSpan(text: '${'${i + 1}'.padLeft(gutter)}   ', style: mono(12.5, color: WoiColors.textFaint, height: 1.55)),
              ...highlightLine(lines[i].replaceAll('\t', '    '), lang, size: 12.5),
              const TextSpan(text: '\n'),
            ],
          ],
          style: mono(12.5, height: 1.55),
        ),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: GlassPanel(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Text('${lines.length} lines', style: body(12, color: WoiColors.textFaint)),
                    const Spacer(),
                    Text('Wrap', style: body(12, color: WoiColors.textDim)),
                    Switch(value: _wrap, onChanged: (v) => setState(() => _wrap = v)),
                  ],
                ),
              ),
              const Divider(height: 1, color: WoiColors.stroke),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: _wrap
                        ? text
                        : SingleChildScrollView(scrollDirection: Axis.horizontal, child: text),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ------------------------------------------------------------------- audio

/// Peak envelope of a PCM WAV file (8/16/24/32-bit int, any channels), or
/// null if it is not a WAV we understand.
({List<double> peaks, Duration duration})? wavPeaks(Uint8List b, {int buckets = 160}) {
  if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(b.sublist(8, 12)) != 'WAVE') {
    return null;
  }
  final bd = ByteData.sublistView(b);
  var pos = 12;
  int? channels, rate, bits, dataStart, dataLen;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final len = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ' && body + 16 <= b.length) {
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataStart = body;
      dataLen = math.min(len, b.length - body);
      break;
    }
    pos = body + len + (len & 1);
  }
  if (channels == null || rate == null || bits == null || dataStart == null || dataLen == null) return null;
  if (channels <= 0 || rate <= 0 || bits % 8 != 0 || bits == 0 || bits > 32) return null;
  final bps = bits ~/ 8;
  final frame = bps * channels;
  final frames = dataLen ~/ frame;
  if (frames == 0) return (peaks: List.filled(buckets, 0.0), duration: Duration.zero);
  final per = math.max(1, frames ~/ buckets);
  final step = math.max(1, per ~/ 64); // sample ~64 frames per bucket
  final full = math.pow(2, bits - 1).toDouble();
  final peaks = <double>[];
  for (var k = 0; k < buckets; k++) {
    var peak = 0.0;
    final start = k * per;
    if (start >= frames) {
      peaks.add(0);
      continue;
    }
    final end = math.min(frames, start + per);
    for (var f = start; f < end; f += step) {
      final o = dataStart + f * frame;
      final v = switch (bps) {
        1 => (bd.getUint8(o) - 128).toDouble(),
        2 => bd.getInt16(o, Endian.little).toDouble(),
        3 => (((bd.getUint8(o + 2) << 24) | (bd.getUint8(o + 1) << 16) | (bd.getUint8(o) << 8)) >> 8).toSigned(24).toDouble(),
        _ => bd.getInt32(o, Endian.little).toDouble(),
      };
      final a = (v / full).abs();
      if (a > peak) peak = a;
    }
    peaks.add(peak.clamp(0.0, 1.0));
  }
  final top = peaks.fold(0.0, math.max);
  final norm = top > 0.05 ? peaks.map((p) => p / top).toList() : peaks;
  return (peaks: norm, duration: Duration(microseconds: frames * 1000000 ~/ rate));
}

class AudioViewerBody extends StatefulWidget {
  const AudioViewerBody({super.key, required this.path, required this.audio});
  final String path;
  final AudioIO audio;
  @override
  State<AudioViewerBody> createState() => _AudioViewerBodyState();
}

class _AudioViewerBodyState extends State<AudioViewerBody> with SingleTickerProviderStateMixin {
  ClipPlayback? _clip;
  String? _error;
  List<double>? _peaks;
  Duration? _duration;
  late final Ticker _ticker = createTicker((d) => setState(() => _elapsed = d));
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    try {
      final f = File(widget.path);
      if (await f.length() > 64 * 1024 * 1024) return;
      final r = wavPeaks(await f.readAsBytes());
      if (r != null && mounted) {
        setState(() {
          _peaks = r.peaks;
          _duration = r.duration;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggle() async {
    if (_clip != null) {
      await _clip!.stop();
      return;
    }
    try {
      final c = await widget.audio.playFile(widget.path);
      setState(() {
        _clip = c;
        _error = null;
        _elapsed = Duration.zero;
      });
      _ticker.start();
      unawaited(
        c.done.whenComplete(() {
          if (!mounted) return;
          _ticker.stop();
          setState(() {
            _clip = null;
            _elapsed = Duration.zero;
          });
        }),
      );
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _clip?.stop();
    _ticker.dispose();
    super.dispose();
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}.${(d.inMilliseconds % 1000 ~/ 100)}';

  @override
  Widget build(BuildContext context) {
    final dur = _duration;
    final playing = _clip != null;
    final progress = dur == null || dur == Duration.zero
        ? 0.0
        : (_elapsed.inMicroseconds / dur.inMicroseconds).clamp(0.0, 1.0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: GlassPanel(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            glow: playing ? WoiColors.violet : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 120,
                  child: Semantics(
                    label: 'Audio waveform',
                    value: dur == null ? null : '${_fmt(_elapsed)} of ${_fmt(dur)}',
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _WavePainter(peaks: _peaks, progress: progress, playing: playing),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Semantics(
                      button: true,
                      label: playing ? 'Stop' : 'Play',
                      excludeSemantics: true,
                      child: IconButton.filled(
                        iconSize: 32,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(64, 64),
                          backgroundColor: WoiColors.violet,
                          foregroundColor: WoiColors.bg0,
                        ),
                        onPressed: _toggle,
                        icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            playing ? 'Playing' : 'Ready',
                            style: display(15, color: playing ? WoiColors.violet : WoiColors.text),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _error ?? (dur == null ? 'Waveform unavailable for this format' : '${_fmt(_elapsed)} / ${_fmt(dur)}'),
                            style: mono(12.5, color: _error != null ? WoiColors.red : WoiColors.textDim)
                                .copyWith(fontFeatures: kTabular),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.peaks, required this.progress, required this.playing});
  final List<double>? peaks;
  final double progress;
  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    final p = peaks ?? List.generate(120, (i) => 0.15 + 0.1 * math.sin(i * 0.4).abs());
    final n = p.length;
    final w = size.width / n;
    final mid = size.height / 2;
    final played = Paint()
      ..shader = const LinearGradient(colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta])
          .createShader(Offset.zero & size);
    final rest = Paint()..color = WoiColors.textFaint.withValues(alpha: 0.45);
    for (var i = 0; i < n; i++) {
      final h = math.max(2.0, p[i] * (size.height - 4));
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(i * w + w / 2, mid), width: math.max(1.5, w * 0.6), height: h),
        const Radius.circular(2),
      );
      canvas.drawRRect(r, (i + 0.5) / n <= progress ? played : rest);
    }
    if (playing) {
      final x = progress * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress || old.peaks != peaks || old.playing != playing;
}

/// In-app overlay used when no secondary window is available.
Future<void> showMediaOverlay(BuildContext context, MediaItem item, AudioIO audio) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      final phone = size.width < 600;
      return Dialog(
        insetPadding: EdgeInsets.all(phone ? 8 : 24),
        backgroundColor: WoiColors.bg1.withValues(alpha: 0.96),
        child: SizedBox(
          width: size.width * (phone ? 1 : 0.85),
          height: size.height * (phone ? 0.92 : 0.85),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                child: ViewerTitle(
                  item: item,
                  trailing: IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
              Expanded(child: MediaBody(item: item, audio: audio)),
            ],
          ),
        ),
      );
    },
  );
}
