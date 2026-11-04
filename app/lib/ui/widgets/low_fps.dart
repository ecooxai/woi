import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A 0..1 phase that repeats every [period], stepped [fps] times a second by
/// a timer instead of a vsync ticker. Continuous "busy" indicators (sweeps,
/// spinners) then cost [fps] frames a second instead of 60: on software GL
/// each frame is a full raster. The timer runs only while someone listens.
class LowFpsLoop extends ChangeNotifier implements ValueListenable<double> {
  LowFpsLoop({required this.period, this.fps = 12});

  final Duration period;
  final int fps;
  Timer? _timer;
  double _value = 0;

  @override
  double get value => _value;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(Duration(microseconds: 1000000 ~/ fps), (_) {
      _value = (_value + 1e6 / fps / period.inMicroseconds) % 1.0;
      notifyListeners();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Builds [builder] with a [LowFpsLoop] phase, in its own repaint boundary.
class LowFpsBuilder extends StatefulWidget {
  const LowFpsBuilder({super.key, required this.period, required this.builder, this.fps = 12});

  final Duration period;
  final int fps;
  final Widget Function(BuildContext context, double phase) builder;

  @override
  State<LowFpsBuilder> createState() => _LowFpsBuilderState();
}

class _LowFpsBuilderState extends State<LowFpsBuilder> {
  late final _loop = LowFpsLoop(period: widget.period, fps: widget.fps);

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ValueListenableBuilder<double>(
      valueListenable: _loop,
      builder: (context, v, _) => widget.builder(context, v),
    ),
  );
}

/// An indeterminate spinner at 12 fps (a rotating arc), for small "running"
/// badges; CircularProgressIndicator animates at the display rate.
class LowFpsSpinner extends StatelessWidget {
  const LowFpsSpinner({super.key, this.size = 14, this.strokeWidth = 1.8, this.color});

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'In progress',
    child: SizedBox.square(
      dimension: size,
      child: LowFpsBuilder(
        period: const Duration(milliseconds: 1000),
        builder: (context, v) => Transform.rotate(
          angle: v * 2 * math.pi,
          child: CircularProgressIndicator(value: 0.28, strokeWidth: strokeWidth, color: color),
        ),
      ),
    ),
  );
}
