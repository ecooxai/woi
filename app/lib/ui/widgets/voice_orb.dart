import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../theme.dart';

/// Visual state of the orb. A superset of [AssistantPhase]: it also covers
/// the connection lifecycle and background context compaction.
enum OrbMode { offline, connecting, idle, listening, hearing, thinking, speaking, tool, compacting }

/// Maps pipeline state to an orb mode. Compaction is shown only while
/// nobody is talking, so it never hides speech feedback.
OrbMode orbModeFor(AssistantPhase phase, {SessionStatus status = SessionStatus.connected, bool compacting = false}) {
  if (status == SessionStatus.connecting) return OrbMode.connecting;
  if (status != SessionStatus.connected) return OrbMode.offline;
  if (compacting && phase != AssistantPhase.userSpeaking && phase != AssistantPhase.speaking) {
    return OrbMode.compacting;
  }
  return switch (phase) {
    AssistantPhase.offline => OrbMode.offline,
    AssistantPhase.idle => OrbMode.idle,
    AssistantPhase.listening => OrbMode.listening,
    AssistantPhase.userSpeaking => OrbMode.hearing,
    AssistantPhase.thinking => OrbMode.thinking,
    AssistantPhase.toolRunning => OrbMode.tool,
    AssistantPhase.speaking => OrbMode.speaking,
  };
}

String orbModeLabel(OrbMode m) => switch (m) {
  OrbMode.offline => 'Offline',
  OrbMode.connecting => 'Connecting…',
  OrbMode.idle => 'Mic muted',
  OrbMode.listening => 'Listening',
  OrbMode.hearing => 'Hearing you…',
  OrbMode.thinking => 'Thinking…',
  OrbMode.speaking => 'Speaking',
  OrbMode.tool => 'Working…',
  OrbMode.compacting => 'Compacting memory…',
};

Color orbModeColor(OrbMode m) => switch (m) {
  OrbMode.offline => WoiColors.textFaint,
  OrbMode.connecting => WoiColors.textDim,
  OrbMode.idle => WoiColors.textDim,
  OrbMode.listening || OrbMode.hearing => WoiColors.cyan,
  OrbMode.thinking => WoiColors.violet,
  OrbMode.speaking => WoiColors.magenta,
  OrbMode.tool => WoiColors.amber,
  OrbMode.compacting => WoiColors.violet,
};

// Back-compat helpers for code that still thinks in phases.
String phaseLabel(AssistantPhase p) => orbModeLabel(orbModeFor(p));
Color phaseColor(AssistantPhase p) => orbModeColor(orbModeFor(p));

class _Palette {
  const _Palette(this.a, this.b, this.c);

  /// Primary, deep, highlight.
  final Color a;
  final Color b;
  final Color c;

  static _Palette lerp(_Palette x, _Palette y, double t) =>
      _Palette(Color.lerp(x.a, y.a, t)!, Color.lerp(x.b, y.b, t)!, Color.lerp(x.c, y.c, t)!);
}

_Palette _paletteFor(OrbMode m) => switch (m) {
  OrbMode.offline => const _Palette(Color(0xFF4A5670), Color(0xFF151B2B), Color(0xFF7D8AA6)),
  OrbMode.connecting => const _Palette(Color(0xFF4F6DB8), Color(0xFF141C38), Color(0xFF9DB4FF)),
  OrbMode.idle => const _Palette(Color(0xFF3F6BD8), Color(0xFF14183E), Color(0xFF8FB0FF)),
  OrbMode.listening => const _Palette(WoiColors.cyan, Color(0xFF0B2A6B), Color(0xFFB8FBFF)),
  OrbMode.hearing => const _Palette(Color(0xFF6AF6FF), Color(0xFF0E3C8A), Color(0xFFE4FEFF)),
  OrbMode.thinking => const _Palette(WoiColors.violet, Color(0xFF1C1257), Color(0xFFD9D2FF)),
  OrbMode.speaking => const _Palette(WoiColors.magenta, Color(0xFF3A0F6B), Color(0xFFFFC8F4)),
  OrbMode.tool => const _Palette(WoiColors.amber, Color(0xFF5A1A3A), Color(0xFFFFE6B8)),
  OrbMode.compacting => const _Palette(Color(0xFFB07BFF), Color(0xFF16104A), Color(0xFFE9DCFF)),
};

/// Optional GPU core. Loaded once at startup; the painter falls back to
/// gradients when it is unavailable (tests, unsupported renderers).
abstract final class OrbShader {
  static ui.FragmentProgram? program;

  static Future<void> preload() async {
    if (program != null) return;
    try {
      program = await ui.FragmentProgram.fromAsset('shaders/orb.frag');
    } catch (e) {
      debugPrint('orb shader unavailable, using painter fallback: $e');
    }
  }
}

/// Animated orb reacting to mic input and assistant speech, with distinct
/// looks for every [OrbMode].
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.mode,
    this.micLevel,
    this.outputLevel,
    this.size = 260,
    this.animate = true,
  });

  final OrbMode mode;
  final ValueListenable<double>? micLevel;
  final ValueListenable<double>? outputLevel;
  final double size;

  /// False freezes the animation (tests, reduced motion).
  final bool animate;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _Particle {
  _Particle(Random r)
    : a0 = r.nextDouble() * 2 * pi,
      incline = (r.nextDouble() - 0.5) * 2.2,
      orbit = 1.3 + r.nextDouble() * 0.85,
      speed = 0.35 + r.nextDouble() * 0.9,
      size = 0.6 + r.nextDouble() * 1.5,
      seed = r.nextDouble();
  final double a0, incline, orbit, speed, size, seed;
}

class _Ripple {
  _Ripple(this.born, this.strength);
  final double born;
  final double strength;
}

/// Mutable animation state shared with the painter (repaints via notify).
class _OrbState extends ChangeNotifier {
  double t = 0;
  double spin = 0;
  double mic = 0;
  double out = 0;
  double energy = 0;
  OrbMode mode = OrbMode.offline;
  _Palette palette = _paletteFor(OrbMode.offline);

  // Feature weights eased toward the current mode (0..1).
  double wave = 0, arcs = 0, gears = 0, implode = 0, connect = 0, dim = 0;

  final history = List<double>.filled(48, 0, growable: true);
  double _histAcc = 0;
  final ripples = <_Ripple>[];
  double _lastRipple = -10;
  final particles = List.generate(64, (i) => _Particle(Random(i * 7919 + 13)));
  ui.FragmentShader? shader;

  void tick() => notifyListeners();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _s = _OrbState();
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _s.mode = widget.mode;
    _s.palette = _paletteFor(widget.mode);
    _snapWeights();
    _s.shader = OrbShader.program?.fragmentShader();
    _ticker = createTicker(_onTick);
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ticker.isActive) _ticker.start();
    if (!widget.animate && _ticker.isActive) _ticker.stop();
    if (!widget.animate && old.mode != widget.mode) {
      _s.mode = widget.mode;
      _s.palette = _paletteFor(widget.mode);
      _snapWeights();
      _s.tick();
    }
  }

  ({double wave, double arcs, double gears, double implode, double connect, double dim}) _targets(OrbMode m) => (
    wave: switch (m) {
      OrbMode.listening || OrbMode.hearing || OrbMode.speaking => 1.0,
      OrbMode.idle => 0.25,
      _ => 0.12,
    },
    arcs: m == OrbMode.thinking ? 1.0 : 0.0,
    gears: m == OrbMode.tool ? 1.0 : 0.0,
    implode: m == OrbMode.compacting ? 1.0 : 0.0,
    connect: m == OrbMode.connecting ? 1.0 : 0.0,
    dim: m == OrbMode.offline ? 1.0 : (m == OrbMode.idle ? 0.45 : 0.0),
  );

  void _snapWeights() {
    final g = _targets(_s.mode);
    _s
      ..wave = g.wave
      ..arcs = g.arcs
      ..gears = g.gears
      ..implode = g.implode
      ..connect = g.connect
      ..dim = g.dim;
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    final s = _s;
    final mode = widget.mode;
    s.t += dt;
    s.mode = mode;

    // Meter values sit around 0.4 at room noise; emphasise the top end.
    double shape(double v) => pow(((v - 0.35) / 0.65).clamp(0.0, 1.0), 1.3).toDouble();
    final micOn = mode == OrbMode.listening || mode == OrbMode.hearing;
    final micT = micOn ? shape(widget.micLevel?.value ?? 0) : 0.0;
    final outT = shape(widget.outputLevel?.value ?? 0);
    double ease(double cur, double target, double rate) => cur + (target - cur) * min(1.0, dt * rate);
    s.mic = ease(s.mic, micT, micT > s.mic ? 22 : 9);
    s.out = ease(s.out, outT, outT > s.out ? 22 : 9);
    final synthetic = switch (mode) {
      // Gentle procedural motion when no real level drives the orb.
      OrbMode.speaking => 0.25 + 0.15 * sin(s.t * 7) * sin(s.t * 2.3),
      OrbMode.hearing => 0.2,
      OrbMode.thinking || OrbMode.tool => 0.18,
      _ => 0.0,
    };
    s.energy = ease(s.energy, max(max(s.mic, s.out), synthetic), 10);

    final spinSpeed = switch (mode) {
      OrbMode.thinking => 1.8,
      OrbMode.tool => 2.4,
      OrbMode.compacting => 1.4,
      OrbMode.connecting => 0.9,
      OrbMode.offline => 0.08,
      _ => 0.3 + s.energy * 0.8,
    };
    s.spin += dt * spinSpeed;

    final g = _targets(mode);
    s
      ..wave = ease(s.wave, g.wave, 4)
      ..arcs = ease(s.arcs, g.arcs, 4)
      ..gears = ease(s.gears, g.gears, 4)
      ..implode = ease(s.implode, g.implode, 3)
      ..connect = ease(s.connect, g.connect, 4)
      ..dim = ease(s.dim, g.dim, 3);
    s.palette = _Palette.lerp(s.palette, _paletteFor(mode), min(1, dt * 4));

    // Level history for the waveform ring (~30 samples/s).
    s._histAcc += dt;
    while (s._histAcc > 1 / 30) {
      s._histAcc -= 1 / 30;
      s.history.removeAt(0);
      s.history.add(s.energy);
    }

    // Ripples on voice peaks.
    if (s.energy > 0.32 && s.t - s._lastRipple > 0.55 && (mode == OrbMode.hearing || mode == OrbMode.speaking)) {
      s.ripples.add(_Ripple(s.t, s.energy));
      s._lastRipple = s.t;
    }
    s.ripples.removeWhere((r) => s.t - r.born > 1.6);
    s.tick();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Woi status: ${orbModeLabel(widget.mode)}',
      liveRegion: true,
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _OrbPainter(_s)),
        ),
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
    final unit = size.shortestSide;
    final e = s.energy;
    final p = s.palette;
    final lit = 1 - 0.55 * s.dim;
    final breathe = 0.025 * sin(s.t * 1.4);
    final implodePulse = s.implode * 0.06 * sin(s.t * 5);
    final r = unit * 0.22 * (1 + breathe + 0.16 * e - implodePulse);

    _bloom(canvas, c, r, p, e, lit);
    _particles(canvas, c, r, p, e, lit, front: false);
    _hudRings(canvas, c, r, p, lit);
    _waveRing(canvas, c, r, p, e, lit);
    if (s.arcs > 0.01) _thinkingArcs(canvas, c, r, p);
    if (s.gears > 0.01) _toolSegments(canvas, c, r, p);
    if (s.implode > 0.01) _implosion(canvas, c, r, p);
    if (s.connect > 0.01) _connecting(canvas, c, r, p);
    _core(canvas, c, r, p, e, lit);
    _ripples(canvas, c, r, p);
    _particles(canvas, c, r, p, e, lit, front: true);
  }

  Paint _stroke(double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round;

  void _bloom(Canvas canvas, Offset c, double r, _Palette p, double e, double lit) {
    final haloR = r * (2.6 + 0.5 * e);
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            p.a.withValues(alpha: (0.34 + 0.3 * e) * lit),
            p.b.withValues(alpha: 0.16 * lit),
            p.b.withValues(alpha: 0),
          ],
          stops: const [0.2, 0.5, 1],
        ).createShader(Rect.fromCircle(center: c, radius: haloR)),
    );
    // Tight hot glow hugging the sphere.
    canvas.drawCircle(
      c,
      r * 1.22,
      Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.18)
        ..color = p.a.withValues(alpha: (0.45 + 0.3 * e) * lit),
    );
  }

  void _hudRings(Canvas canvas, Offset c, double r, _Palette p, double lit) {
    final ringR = r * 1.62;
    canvas.drawCircle(c, ringR, _stroke(1)..color = p.a.withValues(alpha: 0.16 * lit));
    // Rotating tick scale.
    final tick = _stroke(1.2);
    const n = 120;
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * pi + s.spin * 0.12;
      final major = i % 10 == 0;
      final len = major ? r * 0.07 : r * 0.03;
      tick.color = p.a.withValues(alpha: (major ? 0.5 : 0.16) * lit);
      final d = Offset(cos(a), sin(a));
      canvas.drawLine(c + d * (ringR + r * 0.05), c + d * (ringR + r * 0.05 + len), tick);
    }
    // Outer dashed segments rotating the other way.
    final outer = Rect.fromCircle(center: c, radius: r * 1.92);
    final seg = _stroke(1.4)..color = p.c.withValues(alpha: 0.22 * lit);
    for (var k = 0; k < 3; k++) {
      canvas.drawArc(outer, -s.spin * 0.2 + k * 2 * pi / 3, pi * 0.32, false, seg);
    }
    // Tiny bracket markers at the cardinal points.
    final br = _stroke(1.6)..color = p.c.withValues(alpha: 0.35 * lit);
    for (var k = 0; k < 4; k++) {
      final a = k * pi / 2 + pi / 4;
      canvas.drawArc(outer.inflate(r * 0.06), a - 0.06, 0.12, false, br);
    }
  }

  void _waveRing(Canvas canvas, Offset c, double r, _Palette p, double e, double lit) {
    final w = s.wave;
    if (w < 0.02) return;
    const bars = 96;
    final base = r * 1.2;
    final paint = _stroke(max(1.4, r * 0.022));
    final hist = s.history;
    for (var i = 0; i < bars; i++) {
      // Mirror around the vertical axis so the ring looks balanced.
      final m = (i <= bars / 2 ? i : bars - i) / (bars / 2);
      final h = hist[(hist.length - 1 - (m * (hist.length - 1))).round()];
      final jitter = 0.5 + 0.5 * sin(i * 1.7 + s.t * 6.0) * sin(i * 0.63 - s.t * 3.1);
      final v = (h * (0.65 + 0.35 * jitter) + 0.04 * (1 + sin(i * 0.4 + s.t * 1.5))) * w;
      final len = r * (0.02 + 0.42 * v);
      final a = i / bars * 2 * pi - pi / 2;
      final d = Offset(cos(a), sin(a));
      paint.color = Color.lerp(p.a, p.c, (v * 1.6).clamp(0, 1))!.withValues(alpha: (0.25 + 0.75 * v.clamp(0, 1)) * lit);
      canvas.drawLine(c + d * base, c + d * (base + len), paint);
    }
  }

  void _thinkingArcs(Canvas canvas, Offset c, double r, _Palette p) {
    for (var k = 0; k < 2; k++) {
      final rr = r * (k == 0 ? 1.42 : 1.62);
      final rect = Rect.fromCircle(center: c, radius: rr);
      final start = (k == 0 ? 1 : -1.3) * s.spin * 1.6 + k * pi;
      canvas.drawArc(
        rect,
        start,
        pi * 0.8,
        false,
        _stroke(k == 0 ? r * 0.045 : r * 0.028)
          ..shader = SweepGradient(
            colors: [p.a.withValues(alpha: 0), p.a.withValues(alpha: 0.9 * s.arcs), p.c.withValues(alpha: s.arcs)],
            stops: const [0, 0.85, 1],
            transform: GradientRotation(start),
          ).createShader(rect),
      );
    }
  }

  void _toolSegments(Canvas canvas, Offset c, double r, _Palette p) {
    final rr = r * 1.48;
    final rect = Rect.fromCircle(center: c, radius: rr);
    // Stepped rotation: snaps forward like a mechanism.
    final step = s.spin * 1.2;
    final stepped = (step.floor() + Curves.easeInOutCubic.transform(step - step.floor())) * pi / 4;
    for (var k = 0; k < 8; k++) {
      final on = (k + step.floor()) % 3 == 0;
      canvas.drawArc(
        rect,
        stepped + k * pi / 4 + 0.08,
        pi / 4 - 0.16,
        false,
        _stroke(r * (on ? 0.06 : 0.035))
          ..strokeCap = StrokeCap.butt
          ..color = (on ? p.c : p.a).withValues(alpha: (on ? 0.95 : 0.4) * s.gears),
      );
    }
  }

  void _implosion(Canvas canvas, Offset c, double r, _Palette p) {
    for (var k = 0; k < 3; k++) {
      final ph = ((s.t * 0.7) + k / 3) % 1.0;
      final rr = r * (2.3 - 1.25 * Curves.easeInCubic.transform(ph));
      final a = sin(ph * pi) * s.implode;
      canvas.drawCircle(c, rr, _stroke(r * 0.03 * (0.5 + ph))..color = p.c.withValues(alpha: 0.6 * a));
    }
  }

  void _connecting(Canvas canvas, Offset c, double r, _Palette p) {
    final rect = Rect.fromCircle(center: c, radius: r * 1.42);
    canvas.drawArc(
      rect,
      s.spin * 2.2,
      pi * (0.25 + 0.2 * sin(s.t * 2)),
      false,
      _stroke(r * 0.035)..color = p.c.withValues(alpha: 0.8 * s.connect),
    );
  }

  void _core(Canvas canvas, Offset c, double r, _Palette p, double e, double lit) {
    final shader = s.shader;
    final rect = Rect.fromCircle(center: c, radius: r);
    if (shader != null) {
      double ch(double v) => v * lit;
      shader
        ..setFloat(0, r * 2)
        ..setFloat(1, r * 2)
        ..setFloat(2, s.t)
        ..setFloat(3, e)
        ..setFloat(4, ch(p.a.r))
        ..setFloat(5, ch(p.a.g))
        ..setFloat(6, ch(p.a.b))
        ..setFloat(7, ch(p.b.r))
        ..setFloat(8, ch(p.b.g))
        ..setFloat(9, ch(p.b.b))
        ..setFloat(10, ch(p.c.r))
        ..setFloat(11, ch(p.c.g))
        ..setFloat(12, ch(p.c.b))
        ..setFloat(13, max(s.arcs, max(s.gears, s.implode)))
        ..setFloat(14, s.spin);
      canvas.save();
      canvas.translate(rect.left, rect.top);
      canvas.drawRect(Offset.zero & rect.size, Paint()..shader = shader);
      canvas.restore();
    } else {
      _fallbackCore(canvas, c, r, p, e, lit);
    }
    // Rim light.
    canvas.drawCircle(
      c,
      r,
      _stroke(max(1.0, r * 0.02))
        ..shader = SweepGradient(
          colors: [
            p.c.withValues(alpha: 0),
            p.c.withValues(alpha: 0.85 * lit),
            p.a.withValues(alpha: 0.2 * lit),
            p.c.withValues(alpha: 0),
          ],
          stops: const [0, 0.3, 0.6, 1],
          transform: GradientRotation(s.t * 0.6),
        ).createShader(rect),
    );
  }

  void _fallbackCore(Canvas canvas, Offset c, double r, _Palette p, double e, double lit) {
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          colors: [
            Color.lerp(p.c, Colors.white, 0.5)!.withValues(alpha: lit),
            p.a.withValues(alpha: lit),
            p.b.withValues(alpha: lit),
            Color.lerp(p.b, p.a, 0.6)!.withValues(alpha: lit),
          ],
          stops: const [0, 0.3, 0.82, 1],
        ).createShader(rect),
    );
    // Liquid filaments.
    for (var layer = 0; layer < 3; layer++) {
      final k = layer * 1.9;
      final amp = (0.04 + 0.16 * e) * (1 - layer * 0.2);
      final lr = r * (0.55 + layer * 0.14);
      final path = Path();
      const n = 90;
      for (var i = 0; i <= n; i++) {
        final th = i / n * 2 * pi;
        final w = sin(3 * th + s.t * 1.3 + k) * 0.6 + sin(5 * th - s.t * 1.9 + 2 * k) * 0.4;
        final pt = c + Offset(cos(th), sin(th)) * lr * (1 + amp * w);
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      canvas.drawPath(path, _stroke(r * 0.02)..color = p.c.withValues(alpha: (0.25 + 0.3 * e) * lit));
    }
    final hl = c + Offset(-r * 0.32, -r * 0.36);
    canvas.drawCircle(
      hl,
      r * 0.38,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.55 * lit), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: hl, radius: r * 0.38)),
    );
  }

  void _ripples(Canvas canvas, Offset c, double r, _Palette p) {
    for (final rp in s.ripples) {
      final k = ((s.t - rp.born) / 1.6).clamp(0.0, 1.0);
      final rr = r * (1.05 + 1.4 * Curves.easeOutCubic.transform(k));
      canvas.drawCircle(c, rr, _stroke(r * 0.025 * (1 - k))..color = p.c.withValues(alpha: 0.55 * (1 - k) * rp.strength));
    }
  }

  void _particles(Canvas canvas, Offset c, double r, _Palette p, double e, double lit, {required bool front}) {
    final dot = Paint();
    final speedK = 1 + e * 2 + s.gears * 1.5;
    for (final q in s.particles) {
      final a = q.a0 + s.spin * q.speed * speedK;
      var orbit = q.orbit;
      var fade = 1.0;
      if (s.implode > 0.01) {
        // Spiral inward and respawn at the edge.
        final ph = (s.t * 0.45 * q.speed + q.seed) % 1.0;
        orbit = orbit * (1 - s.implode) + s.implode * (2.2 - 1.2 * ph);
        fade = 1 - s.implode * ph * ph;
      }
      final x = cos(a);
      final y = sin(a) * cos(q.incline);
      final z = sin(a) * sin(q.incline);
      if ((z >= 0) != front) continue;
      final pos = c + Offset(x, y) * r * orbit;
      if (!front && (pos - c).distance < r) continue; // hidden behind the core
      final depth = 0.55 + 0.45 * z;
      dot.color = Color.lerp(p.a, p.c, q.seed)!.withValues(alpha: (0.25 + 0.55 * depth) * fade * lit * (0.6 + 0.4 * e));
      canvas.drawCircle(pos, q.size * (0.6 + 0.6 * depth) * (r / 60).clamp(0.6, 1.6), dot);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.s != s;
}
