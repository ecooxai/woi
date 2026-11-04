import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../theme.dart';

/// What the voice side of Woi is doing. A superset of [AssistantPhase]: it
/// also covers the connection lifecycle and background context compaction.
enum VoiceMode { offline, connecting, reconnecting, idle, listening, hearing, thinking, speaking, tool, compacting }

/// Maps pipeline state to a voice mode. Compaction is shown only while idle
/// or listening, so it never hides speech, thinking or tool feedback.
VoiceMode voiceModeFor(
  AssistantPhase phase, {
  SessionStatus status = SessionStatus.connected,
  bool compacting = false,
  bool reconnecting = false,
}) {
  // Automatic reconnect after a drop: shown between attempts too.
  if (reconnecting && status != SessionStatus.connected) return VoiceMode.reconnecting;
  if (status == SessionStatus.connecting) return VoiceMode.connecting;
  if (status != SessionStatus.connected) return VoiceMode.offline;
  if (compacting && (phase == AssistantPhase.idle || phase == AssistantPhase.listening)) {
    return VoiceMode.compacting;
  }
  return switch (phase) {
    AssistantPhase.offline => VoiceMode.offline,
    AssistantPhase.idle => VoiceMode.idle,
    AssistantPhase.listening => VoiceMode.listening,
    AssistantPhase.userSpeaking => VoiceMode.hearing,
    AssistantPhase.thinking => VoiceMode.thinking,
    AssistantPhase.toolRunning => VoiceMode.tool,
    AssistantPhase.speaking => VoiceMode.speaking,
  };
}

String voiceModeLabel(VoiceMode m) => switch (m) {
  VoiceMode.offline => 'Offline',
  VoiceMode.connecting => 'Connecting…',
  VoiceMode.reconnecting => 'Reconnecting…',
  VoiceMode.idle => 'Mic muted',
  VoiceMode.listening => 'Listening',
  VoiceMode.hearing => 'Hearing you…',
  VoiceMode.thinking => 'Thinking…',
  VoiceMode.speaking => 'Speaking',
  VoiceMode.tool => 'Running tool…',
  VoiceMode.compacting => 'Compacting memory…',
};

Color voiceModeColor(VoiceMode m) => switch (m) {
  VoiceMode.offline => WoiColors.textFaint,
  VoiceMode.connecting => WoiColors.textDim,
  VoiceMode.reconnecting => WoiColors.amber,
  VoiceMode.idle => WoiColors.textFaint,
  VoiceMode.listening || VoiceMode.hearing => WoiColors.cyan,
  VoiceMode.thinking => WoiColors.violet,
  VoiceMode.speaking => WoiColors.magenta,
  VoiceMode.tool => WoiColors.amber,
  VoiceMode.compacting => WoiColors.violet,
};

// Phase-only helpers.
String phaseLabel(AssistantPhase p) => voiceModeLabel(voiceModeFor(p));
Color phaseColor(AssistantPhase p) => voiceModeColor(voiceModeFor(p));

/// Whether a mode shows motion. Idle, muted and offline are still, so an
/// idle window renders no frames at all.
bool voiceModeAnimates(VoiceMode m) =>
    m == VoiceMode.connecting ||
    m == VoiceMode.reconnecting ||
    m == VoiceMode.thinking ||
    m == VoiceMode.tool ||
    m == VoiceMode.compacting;

/// Whether a mode shows the live level waveform. Plain listening (mic open,
/// nobody talking) is a still dot: room noise would otherwise keep the
/// window repainting, and every frame is costly on software GL.
bool voiceModeShowsLevel(VoiceMode m) => m == VoiceMode.hearing || m == VoiceMode.speaking;

/// Re-publishes an audio level at most [hz] times per second, quantized to
/// [steps] levels, so a widget listening to it repaints only when the
/// visible bar height actually changes (silence = no repaints).
class ThrottledLevel extends ChangeNotifier implements ValueListenable<double> {
  ThrottledLevel({this.hz = 15, this.steps = 12});

  final int hz;
  final int steps;
  ValueListenable<double>? _source;
  double _value = 0;
  double _pending = 0;
  Timer? _timer;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  double get value => _value;

  ValueListenable<double>? get source => _source;

  set source(ValueListenable<double>? s) {
    if (identical(s, _source)) return;
    _source?.removeListener(_onSource);
    _source = s;
    s?.addListener(_onSource);
    _onSource();
  }

  /// Levels under [floor] (background noise) read as silence.
  static const floor = 0.06;

  double _quantize(double v) {
    final c = v.clamp(0.0, 1.0);
    return c < floor ? 0 : (c * steps).round() / steps;
  }

  void _onSource() {
    _pending = _quantize(_source?.value ?? 0);
    if (_pending == _value) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final period = Duration(microseconds: 1000000 ~/ hz);
    final since = DateTime.now().difference(_last);
    if (since >= period) {
      _publish();
    } else {
      _timer ??= Timer(period - since, _publish);
    }
  }

  void _publish() {
    _timer?.cancel();
    _timer = null;
    _last = DateTime.now();
    if (_pending == _value) return;
    _value = _pending;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _source?.removeListener(_onSource);
    super.dispose();
  }
}

/// Compact voice state: a dot (pulsing while busy) or a tiny 4-bar waveform
/// driven by the live audio level, plus an optional label. Motion runs on a
/// low-rate timer (12 fps) and only in active modes, inside its own
/// repaint boundary.
class VoiceStatusIndicator extends StatefulWidget {
  const VoiceStatusIndicator({
    super.key,
    required this.mode,
    this.micLevel,
    this.outputLevel,
    this.showLabel = true,
    this.animate,
  });

  final VoiceMode mode;

  /// Overrides [voiceModeAnimates] (e.g. no pulse while a reconnect waits
  /// out its backoff: up to 30 s of frames for nothing).
  final bool? animate;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? outputLevel;
  final bool showLabel;

  @override
  State<VoiceStatusIndicator> createState() => _VoiceStatusIndicatorState();
}

class _VoiceStatusIndicatorState extends State<VoiceStatusIndicator> {
  final _level = ThrottledLevel();
  final _phase = ValueNotifier<double>(0);
  Timer? _pulse;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceStatusIndicator old) {
    super.didUpdateWidget(old);
    _sync();
  }

  bool get _animates => widget.animate ?? voiceModeAnimates(widget.mode);

  void _sync() {
    final m = widget.mode;
    _level.source = !voiceModeShowsLevel(m)
        ? null
        : m == VoiceMode.speaking
        ? widget.outputLevel
        : widget.micLevel;
    if (_animates) {
      _pulse ??= Timer.periodic(const Duration(milliseconds: 83), (_) {
        _phase.value = (_phase.value + 1 / 18) % 1.0;
      });
    } else {
      _pulse?.cancel();
      _pulse = null;
      _phase.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse?.cancel();
    _level.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mode;
    final color = voiceModeColor(m);
    final label = voiceModeLabel(m);
    return Semantics(
      label: 'Voice: $label',
      liveRegion: true,
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: SizedBox(
              width: 18,
              height: 16,
              child: CustomPaint(
                key: const ValueKey('voice-indicator'),
                painter: _IndicatorPainter(
                  color: color,
                  bars: voiceModeShowsLevel(m),
                  pulsing: _animates,
                  level: _level,
                  phase: _phase,
                ),
              ),
            ),
          ),
          if (widget.showLabel) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                key: const ValueKey('voice-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: body(12, weight: FontWeight.w500, color: m == VoiceMode.idle ? WoiColors.textDim : color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _IndicatorPainter extends CustomPainter {
  _IndicatorPainter({
    required this.color,
    required this.bars,
    required this.pulsing,
    required this.level,
    required this.phase,
  }) : super(repaint: Listenable.merge([level, phase]));

  final Color color;
  final bool bars;
  final bool pulsing;
  final ValueListenable<double> level;
  final ValueListenable<double> phase;

  static const _shape = [0.55, 1.0, 0.8, 0.45];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (bars) {
      const w = 2.5;
      final gap = (size.width - w * _shape.length) / (_shape.length - 1);
      final l = level.value;
      for (var i = 0; i < _shape.length; i++) {
        final h = max(3.0, size.height * (0.2 + 0.8 * l * _shape[i]));
        final x = i * (w + gap);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), const Radius.circular(2)),
          paint,
        );
      }
      return;
    }
    final c = size.center(Offset.zero);
    if (pulsing) {
      final t = phase.value;
      canvas.drawCircle(c, 4 + 4 * t, Paint()..color = color.withValues(alpha: 0.35 * (1 - t)));
    }
    canvas.drawCircle(c, 4, paint);
  }

  @override
  bool shouldRepaint(_IndicatorPainter old) =>
      old.color != color || old.bars != bars || old.pulsing != pulsing || old.level != level || old.phase != phase;
}
