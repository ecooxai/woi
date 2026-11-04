import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../platform/media_viewer.dart';
import '../perf.dart';
import '../theme.dart';
import 'viewer_commands.dart';

/// Whether the media viewer is fullscreen (the viewer chrome hides itself).
final viewerFullscreen = ValueNotifier<bool>(false);

/// Asks the runner to make the viewer window fullscreen ("woi/window").
/// Fails silently where the channel is missing (in-app overlay, tests): the
/// viewer then just fills its surface.
Future<void> setViewerWindowFullscreen(bool on) async {
  viewerFullscreen.value = on;
  try {
    await const MethodChannel('woi/window').invokeMethod<void>('setFullscreen', on);
  } catch (_) {}
}

/// Embedded video player (fvp/libmdk behind `video_player`): play/pause,
/// seek, volume, fullscreen and keys (Space, ←/→ seek 5 s, ↑/↓ volume,
/// F fullscreen, M mute, Esc leaves fullscreen).
class VideoViewerBody extends StatefulWidget {
  const VideoViewerBody({super.key, required this.path, this.autoplay = true, this.controllerFactory});

  final String path;
  final bool autoplay;

  /// Test seam; defaults to [VideoPlayerController.file].
  final VideoPlayerController Function(String path)? controllerFactory;

  @override
  State<VideoViewerBody> createState() => VideoViewerBodyState();
}

@visibleForTesting
class VideoViewerBodyState extends State<VideoViewerBody> implements PlaybackProbe {
  late final VideoPlayerController _c =
      widget.controllerFactory?.call(widget.path) ?? VideoPlayerController.file(File(widget.path));
  final _focus = FocusNode(debugLabel: 'video');
  String? _error;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  double _volumeBeforeMute = 1;
  double? _dragFraction;

  VideoPlayerController get controller => _c;
  StreamSubscription<(ViewerCommand, double)>? _commands;

  /// Voice control from the main window (viewer_commands.dart).
  void _onCommand((ViewerCommand, double) c) {
    final (cmd, secs) = c;
    final playing = _c.value.isPlaying;
    switch (cmd) {
      case ViewerCommand.pause when playing:
      case ViewerCommand.play when !playing:
        togglePlay();
      case ViewerCommand.seekBy:
        seekBy(Duration(milliseconds: (secs * 1000).round()));
      case ViewerCommand.seekTo:
        seekBy(Duration(milliseconds: (secs * 1000).round()) - _c.value.position);
      default:
    }
  }

  @override
  Duration get position => _c.value.position;
  @override
  Duration? get duration => _c.value.isInitialized ? _c.value.duration : null;
  @override
  bool get playing => _c.value.isPlaying;

  @override
  void initState() {
    super.initState();
    _commands = viewerCommands.stream.listen(_onCommand);
    activePlayback = this;
    _c.addListener(_onValue);
    // Real player: cap the texture at the video's own size first (no
    // upscaling, see videoTextureCap); fvp reads the cap when it creates the
    // texture in initialize().
    final ready = widget.controllerFactory == null
        ? probeVideoSize(widget.path).then((size) => registerVideoPlayer(video: size))
        : Future<void>.value();
    ready
        .then((_) => _c.initialize())
        .then((_) {
          if (!mounted) return;
          setState(() {});
          if (widget.autoplay) {
            _c.play();
            _scheduleHide();
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  String? _sig;
  int _posTick = -1;

  /// Rebuilds only when something visible changes: playback state, or the
  /// position at 10 Hz while the controls are shown. (The video frames
  /// themselves come through the texture, without rebuilds.)
  void _onValue() {
    if (!mounted) return;
    final v = _c.value;
    if (v.hasError && _error == null) {
      setState(() => _error = v.errorDescription ?? 'playback error');
      return;
    }
    final sig =
        '${v.isInitialized}|${v.isPlaying}|${v.isBuffering}|${v.isCompleted}|${v.size}|${v.volume}|${v.duration}';
    final tick = _controlsVisible || !v.isPlaying ? v.position.inMilliseconds ~/ 100 : -1;
    if (sig == _sig && tick == _posTick) return;
    _sig = sig;
    _posTick = tick;
    setState(() {});
  }

  @override
  void dispose() {
    _commands?.cancel();
    if (identical(activePlayback, this)) activePlayback = null;
    _hideTimer?.cancel();
    _c.removeListener(_onValue);
    _c.dispose();
    _focus.dispose();
    if (viewerFullscreen.value) unawaited(setViewerWindowFullscreen(false));
    super.dispose();
  }

  // ------------------------------------------------------------- actions

  void togglePlay() {
    if (!_c.value.isInitialized) return;
    if (_c.value.isPlaying) {
      _c.pause();
      _showControls(hideLater: false);
    } else {
      if (_c.value.duration > Duration.zero &&
          _c.value.position >= _c.value.duration - const Duration(milliseconds: 200)) {
        _c.seekTo(Duration.zero);
      }
      _c.play();
      _showControls();
    }
  }

  void seekBy(Duration d) {
    if (!_c.value.isInitialized) return;
    final dur = _c.value.duration;
    var t = _c.value.position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _c.seekTo(t);
    _showControls();
  }

  void setVolume(double v) {
    _c.setVolume(v.clamp(0.0, 1.0));
    _showControls();
  }

  void toggleMute() {
    final v = _c.value.volume;
    if (v > 0) {
      _volumeBeforeMute = v;
      setVolume(0);
    } else {
      setVolume(_volumeBeforeMute <= 0 ? 1 : _volumeBeforeMute);
    }
  }

  void toggleFullscreen() {
    unawaited(setViewerWindowFullscreen(!viewerFullscreen.value));
    _showControls();
  }

  void _showControls({bool hideLater = true}) {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (hideLater) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted && _c.value.isPlaying) setState(() => _controlsVisible = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) togglePlay();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      seekBy(const Duration(seconds: -5));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      seekBy(const Duration(seconds: 5));
    } else if (k == LogicalKeyboardKey.arrowUp) {
      setVolume(_c.value.volume + 0.1);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      setVolume(_c.value.volume - 0.1);
    } else if (k == LogicalKeyboardKey.keyF) {
      if (e is KeyDownEvent) toggleFullscreen();
    } else if (k == LogicalKeyboardKey.keyM) {
      if (e is KeyDownEvent) toggleMute();
    } else if (k == LogicalKeyboardKey.escape && viewerFullscreen.value) {
      unawaited(setViewerWindowFullscreen(false));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- view

  static String fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    return ValueListenableBuilder<bool>(
      valueListenable: viewerFullscreen,
      builder: (context, full, _) => Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(hideLater: v.isPlaying),
          cursor: _controlsVisible || !v.isPlaying ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: Padding(
            padding: full ? EdgeInsets.zero : const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(full ? 0 : WoiRadii.lg),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: full ? null : Border.all(color: WoiColors.stroke),
                ),
                child: _error != null
                    ? _errorView()
                    : !v.isInitialized
                    ? const Center(child: CircularProgressIndicator())
                    : _player(v, full),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: WoiColors.red),
          const SizedBox(height: 12),
          Text('Cannot play this video', style: display(16)),
          const SizedBox(height: 6),
          Text(
            _error!,
            style: mono(12, color: WoiColors.textDim),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _player(VideoPlayerValue v, bool full) {
    final aspect = v.aspectRatio > 0 ? v.aspectRatio : 16 / 9;
    final paused = !v.isPlaying;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focus.requestFocus();
            togglePlay();
          },
          onDoubleTap: toggleFullscreen,
          child: Center(
            child: AspectRatio(aspectRatio: aspect, child: VideoPlayer(_c)),
          ),
        ),
        // Big play button while paused.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: paused ? 1 : 0,
            duration: WoiMotion.medium,
            child: Center(
              child: Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.45),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1.5),
                ),
                child: const Icon(Icons.play_arrow_rounded, size: 52, color: Colors.white),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: _controlsVisible || paused ? Offset.zero : const Offset(0, 0.4),
            duration: WoiMotion.medium,
            curve: WoiMotion.emphasized,
            child: AnimatedOpacity(
              opacity: _controlsVisible || paused ? 1 : 0,
              duration: WoiMotion.medium,
              child: _controls(v, full),
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(VideoPlayerValue v, bool full) {
    final dur = v.duration;
    final pos = v.position;
    final frac =
        _dragFraction ?? (dur.inMilliseconds <= 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0));
    final buffered = v.buffered.isEmpty || dur.inMilliseconds <= 0
        ? 0.0
        : (v.buffered.last.end.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
    final vol = v.volume;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 26, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.78)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SeekBar(
            fraction: frac.toDouble(),
            buffered: buffered.toDouble(),
            onChanged: (f) => setState(() => _dragFraction = f),
            onChangeEnd: (f) {
              setState(() => _dragFraction = null);
              _c.seekTo(Duration(milliseconds: (dur.inMilliseconds * f).round()));
              _showControls();
            },
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _iconButton(
                v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                v.isPlaying ? 'Pause (Space)' : 'Play (Space)',
                togglePlay,
                key: const ValueKey('video-play'),
                big: true,
              ),
              _iconButton(Icons.replay_5_rounded, 'Back 5 s (←)', () => seekBy(const Duration(seconds: -5))),
              _iconButton(Icons.forward_5_rounded, 'Forward 5 s (→)', () => seekBy(const Duration(seconds: 5))),
              const SizedBox(width: 8),
              Text(
                '${fmt(_dragFraction == null ? pos : dur * _dragFraction!)} / ${fmt(dur)}',
                key: const ValueKey('video-time'),
                style: mono(12.5, color: WoiColors.text).copyWith(fontFeatures: kTabular),
              ),
              const Spacer(),
              _iconButton(
                vol <= 0 ? Icons.volume_off_rounded : (vol < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                vol <= 0 ? 'Unmute (M)' : 'Mute (M)',
                toggleMute,
              ),
              SizedBox(
                width: 96,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: WoiColors.magenta,
                    thumbColor: Colors.white,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    key: const ValueKey('video-volume'),
                    value: vol.clamp(0.0, 1.0),
                    onChanged: setVolume,
                    semanticFormatterCallback: (x) => 'Volume ${(x * 100).round()}%',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _iconButton(
                full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                full ? 'Exit fullscreen (Esc)' : 'Fullscreen (F)',
                toggleFullscreen,
                key: const ValueKey('video-fullscreen'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, String tip, VoidCallback onTap, {Key? key, bool big = false}) => IconButton(
    key: key,
    tooltip: tip,
    onPressed: () {
      _focus.requestFocus();
      onTap();
    },
    iconSize: big ? 30 : 22,
    color: Colors.white,
    style: IconButton.styleFrom(minimumSize: const Size(40, 40), foregroundColor: Colors.white),
    icon: Icon(icon),
  );
}

/// Gradient seek bar with a buffered track and a glowing thumb.
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.fraction,
    this.buffered = 0,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final double fraction;
  final double buffered;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  bool _hover = false;
  double _last = 0;

  double _at(Offset local, double width) => width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth;
      return Semantics(
        slider: true,
        label: 'Seek',
        value: '${(widget.fraction * 100).round()}%',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const ValueKey('video-seek'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => widget.onChanged(_last = _at(d.localPosition, w)),
            onTapUp: (_) => widget.onChangeEnd(_last),
            onHorizontalDragStart: (d) => widget.onChanged(_last = _at(d.localPosition, w)),
            onHorizontalDragUpdate: (d) => widget.onChanged(_last = _at(d.localPosition, w)),
            onHorizontalDragEnd: (_) => widget.onChangeEnd(_last),
            child: SizedBox(
              height: 22,
              width: double.infinity,
              child: CustomPaint(painter: _SeekPainter(widget.fraction, widget.buffered, _hover)),
            ),
          ),
        ),
      );
    },
  );
}

class _SeekPainter extends CustomPainter {
  _SeekPainter(this.f, this.buffered, this.hover);
  final double f;
  final double buffered;
  final bool hover;

  @override
  void paint(Canvas canvas, Size size) {
    final h = hover ? 5.0 : 3.5;
    final y = size.height / 2;
    final r = Radius.circular(h);
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, y - h / 2, size.width, h), r);
    canvas.drawRRect(track, Paint()..color = Colors.white.withValues(alpha: 0.18));
    if (buffered > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, y - h / 2, size.width * buffered, h), r),
        Paint()..color = Colors.white.withValues(alpha: 0.22),
      );
    }
    final px = size.width * f;
    final played = Rect.fromLTWH(0, y - h / 2, px, h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(played, r),
      Paint()
        ..shader = LinearGradient(colors: [WoiColors.cyan, WoiColors.violet, WoiColors.magenta])
            .createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    canvas.drawCircle(
      Offset(px, y),
      hover ? 8 : 6,
      Paint()
        ..color = WoiColors.magenta.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(Offset(px, y), hover ? 6.5 : 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter o) => o.f != f || o.buffered != buffered || o.hover != hover;
}
