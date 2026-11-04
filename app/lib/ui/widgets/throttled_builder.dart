import 'dart:async';

import 'package:flutter/widgets.dart';

/// Calls [action] at most once per [interval]. A call at least [interval]
/// after the last run runs at once (inside the caller's frame, so a readout
/// that follows keystrokes or transcript deltas costs no extra frame); calls
/// inside the interval are held, and when they stop, one trailing run at
/// [interval] after the last of them shows the final state.
class Throttle {
  Throttle(this.interval, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration interval;
  final DateTime Function() _now;
  DateTime? _last;
  Timer? _timer;
  VoidCallback? _action;

  /// True while a trailing run is scheduled.
  bool get pending => _timer != null;

  void call(VoidCallback action) {
    final last = _last;
    if (last == null || _now().difference(last) >= interval) {
      _run(action);
      return;
    }
    // Held: re-armed on every call, so during a burst the leading runs
    // (above) do the work and the timer only fires once the burst ends.
    _action = action;
    _timer?.cancel();
    _timer = Timer(interval, () => _run(_action!));
  }

  void _run(VoidCallback action) {
    _timer?.cancel();
    _timer = null;
    _action = null;
    _last = _now();
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _action = null;
  }
}

/// Like [ListenableBuilder], but rebuilds at most once per [interval]
/// (leading + trailing edge), in its own repaint boundary. For readouts that
/// follow a fast-changing model (word counts while typing, a streaming
/// transcript): every change still shows, a few times a second instead of on
/// every notification.
class ThrottledBuilder extends StatefulWidget {
  const ThrottledBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.interval = const Duration(milliseconds: 250),
    this.repaintBoundary = true,
    this.now,
  });

  final Listenable listenable;
  final Duration interval;

  /// Clock for the throttle (tests); defaults to [DateTime.now].
  final DateTime Function()? now;
  final WidgetBuilder builder;
  final bool repaintBoundary;

  @override
  State<ThrottledBuilder> createState() => _ThrottledBuilderState();
}

class _ThrottledBuilderState extends State<ThrottledBuilder> {
  late Throttle _throttle = Throttle(widget.interval, now: widget.now);

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(ThrottledBuilder old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    if (old.interval != widget.interval) {
      _throttle.cancel();
      _throttle = Throttle(widget.interval, now: widget.now);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    _throttle.cancel();
    super.dispose();
  }

  void _changed() => _throttle(() {
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context);
    return widget.repaintBoundary ? RepaintBoundary(child: child) : child;
  }
}

/// Rebuilds only when [selector] returns a different value (==) after a
/// notification of [listenable]. A whole-controller [ListenableBuilder]
/// rebuilds its subtree on every change; this one only when what it shows
/// changed.
class SelectorBuilder<T> extends StatefulWidget {
  const SelectorBuilder({super.key, required this.listenable, required this.selector, required this.builder});

  final Listenable listenable;
  final T Function() selector;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<SelectorBuilder<T>> createState() => _SelectorBuilderState<T>();
}

class _SelectorBuilderState<T> extends State<SelectorBuilder<T>> {
  late T _value = widget.selector();

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(SelectorBuilder<T> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.selector();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final v = widget.selector();
    if (v != _value && mounted) setState(() => _value = v);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// A [Listenable] that notifies only when [selector] (over [source]) returns
/// a different value (==). For merging into a [ListenableBuilder] that
/// shows a few fields of a busy model: it then rebuilds when those change,
/// not on every notification of [source]. Subscribes to [source] only while
/// it has listeners.
class SelectedListenable<T> extends ChangeNotifier {
  SelectedListenable(this.source, this.selector);

  final Listenable source;
  final T Function() selector;
  late T _value;

  @override
  void addListener(VoidCallback listener) {
    if (!hasListeners) {
      _value = selector();
      source.addListener(_check);
    }
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) source.removeListener(_check);
  }

  void _check() {
    final v = selector();
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }

  @override
  void dispose() {
    if (hasListeners) source.removeListener(_check);
    super.dispose();
  }
}
