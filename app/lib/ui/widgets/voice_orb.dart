import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../theme.dart';

class _Palette {
  const _Palette(this.a, this.b, this.glow);
  final Color a;
  final Color b;
  final Color glow;

  static _Palette lerp(_Palette x, _Palette y, double t) =>
      _Palette(Color.lerp(x.a, y.a, t)!, Color.lerp(x.b, y.b, t)!, Color.lerp(x.glow, y.glow, t)!);
}

_Palette _paletteFor(AssistantPhase p) => switch (p) {
  AssistantPhase.offline => const _Palette(Color(0xFF4A5670), Color(0xFF2A3247), Color(0xFF3A4660)),
  AssistantPhase.idle => const _Palette(Color(0xFF3F6BD8), Color(0xFF2A2F6E), Color(0xFF3050A0)),
  AssistantPhase.listening => const _Palette(WoiColors.cyan, WoiColors.blue, WoiColors.cyan),
  AssistantPhase.userSpeaking => const _Palette(Color(0xFF7DF9FF), WoiColors.cyan, Color(0xFF6AF3FF)),
  AssistantPhase.thinking => const _Palette(WoiColors.violet, WoiColors.blue, WoiColors.violet),
  AssistantPhase.toolRunning => const _Palette(WoiColors.amber, WoiColors.magenta, WoiColors.amber),
  AssistantPhase.speaking => const _Palette(WoiColors.magenta, WoiColors.violet, WoiColors.magenta),
};

/// Animated orb that breathes with mic input and assistant speech.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.phase, this.micLevel, this.outputLevel, this.size = 260});

  final AssistantPhase phase;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? outputLevel;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _OrbState extends ChangeNotifier {
  double t = 0;
  double mic = 0;
  double out = 0;
  double spin = 0;
  _Palette palette = _paletteFor(AssistantPhase.offline);
  AssistantPhase phase = AssistantPhase.offline;
  void tick() => notifyListeners();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _s = _OrbState();
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _s.phase = widget.phase;
    _s.palette = _paletteFor(widget.phase);
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    _s.t += dt;
    final micTarget = widget.phase == AssistantPhase.offline ? 0.0 : (widget.micLevel?.value ?? 0);
    final outTarget = widget.outputLevel?.value ?? 0;
    // Ease levels; meter values are ~0.4 at room noise, so emphasise the top.
    double shape(double v) => pow(((v - 0.35) / 0.65).clamp(0.0, 1.0), 1.4).toDouble();
    _s.mic += (shape(micTarget) - _s.mic) * min(1, dt * 14);
    _s.out += (shape(outTarget) - _s.out) * min(1, dt * 14);
    final spinSpeed = switch (widget.phase) {
      AssistantPhase.thinking => 2.6,
      AssistantPhase.toolRunning => 3.4,
      AssistantPhase.offline => 0.15,
      _ => 0.35,
    };
    _s.spin += dt * spinSpeed;
    _s.phase = widget.phase;
    _s.palette = _Palette.lerp(_s.palette, _paletteFor(widget.phase), min(1, dt * 5));
    _s.tick();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _OrbPainter(_s)),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.s) : super(repaint: s);
  final _OrbState s;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.shortestSide * 0.27;
    final energy = max(s.mic, s.out);
    final breathe = 0.03 * sin(s.t * 1.6);
    final r = base * (1 + breathe + 0.22 * energy);
    final p = s.palette;

    // Outer halo
    final haloR = r * (2.0 + 0.6 * energy);
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.glow.withValues(alpha: 0.30 + 0.25 * energy),
            p.glow.withValues(alpha: 0.08),
            p.glow.withValues(alpha: 0),
          ],
          stops: const [0.25, 0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: haloR)),
    );

    // Orbit ring with ticks
    final ringR = r * 1.55;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = p.a.withValues(alpha: 0.18);
    canvas.drawCircle(c, ringR, ring);
    final tick = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 72; i++) {
      final a = i / 72 * 2 * pi + s.spin * 0.3;
      final major = i % 6 == 0;
      final len = major ? 7.0 : 3.5;
      tick.color = p.a.withValues(alpha: major ? 0.45 : 0.18);
      final d = Offset(cos(a), sin(a));
      canvas.drawLine(c + d * (ringR + 4), c + d * (ringR + 4 + len), tick);
    }

    // Spinner arc for thinking / tool use
    if (s.phase == AssistantPhase.thinking || s.phase == AssistantPhase.toolRunning) {
      final arcRect = Rect.fromCircle(center: c, radius: ringR);
      canvas.drawArc(
        arcRect,
        s.spin,
        pi * 0.7,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            colors: [p.a.withValues(alpha: 0), p.a, p.b],
            stops: const [0, 0.6, 1],
            transform: GradientRotation(s.spin),
          ).createShader(arcRect),
      );
    }

    // Liquid layers
    for (var layer = 0; layer < 4; layer++) {
      final k = layer * 1.7;
      final amp = (0.025 + 0.20 * energy) * (1 - layer * 0.18);
      final lr = r * (1.0 + layer * 0.07);
      final path = Path();
      const n = 120;
      for (var i = 0; i <= n; i++) {
        final th = i / n * 2 * pi;
        final w =
            sin(3 * th + s.t * 1.3 + k) * 0.5 +
            sin(5 * th - s.t * 1.9 + 2 * k) * 0.3 +
            sin(8 * th + s.t * 3.1 + k) * 0.2 * (0.3 + energy);
        final rr = lr * (1 + amp * w);
        final pt = c + Offset(cos(th), sin(th)) * rr;
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      path.close();
      final rect = Rect.fromCircle(center: c, radius: lr * 1.3);
      if (layer == 0) {
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.35, -0.4),
              colors: [Colors.white.withValues(alpha: 0.95), p.a, p.b, p.b.withValues(alpha: 0.6)],
              stops: const [0, 0.25, 0.75, 1],
            ).createShader(rect),
        );
      } else {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6 - layer * 0.25
            ..shader = SweepGradient(
              colors: [
                p.a.withValues(alpha: 0.0),
                p.a.withValues(alpha: 0.7),
                p.b.withValues(alpha: 0.7),
                p.a.withValues(alpha: 0.0),
              ],
              transform: GradientRotation(s.t * (0.6 + layer * 0.3) + k),
            ).createShader(rect),
        );
      }
    }

    // Inner sheen
    canvas.drawCircle(
      c + Offset(-r * 0.28, -r * 0.32),
      r * 0.42,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.35), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c + Offset(-r * 0.28, -r * 0.32), radius: r * 0.42)),
    );

    // Orbiting particles
    final dot = Paint();
    for (var i = 0; i < 9; i++) {
      final a = s.spin * (0.8 + i * 0.07) + i * 2 * pi / 9;
      final pr = ringR * (0.92 + 0.08 * sin(s.t * 0.7 + i));
      final pos = c + Offset(cos(a), sin(a)) * pr;
      dot.color = (i.isEven ? p.a : p.b).withValues(alpha: 0.5 + 0.4 * energy);
      canvas.drawCircle(pos, 1.6 + 1.6 * energy, dot);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.s != s;
}

String phaseLabel(AssistantPhase p) => switch (p) {
  AssistantPhase.offline => 'Offline',
  AssistantPhase.idle => 'Mic muted',
  AssistantPhase.listening => 'Listening',
  AssistantPhase.userSpeaking => 'Hearing you…',
  AssistantPhase.thinking => 'Thinking…',
  AssistantPhase.toolRunning => 'Working…',
  AssistantPhase.speaking => 'Speaking',
};

Color phaseColor(AssistantPhase p) => switch (p) {
  AssistantPhase.offline => WoiColors.textFaint,
  AssistantPhase.idle => WoiColors.textDim,
  AssistantPhase.listening => WoiColors.cyan,
  AssistantPhase.userSpeaking => WoiColors.cyan,
  AssistantPhase.thinking => WoiColors.violet,
  AssistantPhase.toolRunning => WoiColors.amber,
  AssistantPhase.speaking => WoiColors.magenta,
};
