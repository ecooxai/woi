import 'dart:async';

import 'package:flutter/services.dart';

/// The user took over. Kept latched until the next user turn so a model cannot
/// immediately retry an interrupted input tool.
class ControlInterrupted implements Exception {
  const ControlInterrupted();
  @override
  String toString() =>
      'User took control. Stop mouse and keyboard tools until a new user request. '
      'Earlier input may already have completed.';
}

typedef ControlNativeCall = Future<Object?> Function(String method, Map<String, Object?>? arguments);

/// Native overlays are deliberately outside Flutter: they remain visible over
/// the app being controlled, without stealing its keyboard focus.
class ControlFeedback {
  ControlFeedback(this.call);
  ControlFeedback.linux()
    : call = ((method, arguments) => const MethodChannel('woi/control').invokeMethod<Object?>(method, arguments));

  final ControlNativeCall call;
  Future<void> begin(String kind, {String keys = '', int? x, int? y}) async {
    final ok = await call('begin', {'kind': kind, 'keys': keys, 'x': x, 'y': y});
    if (ok != true) throw const ControlInterrupted();
  }

  Future<bool> interrupted() async => await call('interrupted', null) != false;
  Future<void> update({String? keys, int? x, int? y, String? button}) async {
    await call('update', {'keys': keys, 'x': x, 'y': y, 'button': button});
  }

  Future<void> end() async {
    await call('end', null);
  }

  Future<void> reset() async {
    await call('reset', null);
  }
}

/// One active operation. Native physical-input detection runs continuously;
/// this poll also terminates a running xdotool process on takeover.
class ControlLease {
  ControlLease(this.feedback);
  final ControlFeedback feedback;
  final _cancelled = Completer<void>();
  Timer? _timer;
  bool _checking = false;
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  void start() {
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) async {
      if (_checking || cancelled) return;
      _checking = true;
      try {
        if (await feedback.interrupted()) cancel();
      } catch (_) {
        cancel();
      } finally {
        _checking = false;
      }
    });
  }

  Future<void> check() async {
    if (cancelled || await feedback.interrupted()) {
      cancel();
      throw const ControlInterrupted();
    }
  }

  Future<void> pause(Duration duration) async {
    await Future.any<void>([Future<void>.delayed(duration), whenCancelled]);
    await check();
  }

  Future<void> update({String? keys, int? x, int? y, String? button}) async {
    await check();
    await feedback.update(keys: keys, x: x, y: y, button: button);
  }

  void dispose() {
    _timer?.cancel();
  }
}

/// Serializes visible control: one second of warning, then input, then three
/// seconds of feedback. Failed/missing native feedback never permits input.
class ControlGuard {
  ControlGuard(this.feedback, {this.warning = const Duration(seconds: 1), this.cooldown = const Duration(seconds: 3)});
  final ControlFeedback feedback;
  final Duration warning;
  final Duration cooldown;
  Future<void> _tail = Future<void>.value();
  ControlLease? _active;
  bool _interrupted = false;
  int _generation = 0;

  Future<void> reset() {
    _generation++;
    _active?.cancel();
    _tail = _tail.then((_) async {
      try {
        await feedback.reset();
        _interrupted = false;
      } catch (_) {
        _interrupted = true;
      }
    });
    return _tail;
  }

  Future<T> run<T>(String kind, Future<T> Function(ControlLease lease) action, {String keys = '', int? x, int? y}) {
    final generation = _generation;
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      if (_interrupted || generation != _generation) {
        done.completeError(const ControlInterrupted());
        return;
      }
      final lease = ControlLease(feedback);
      _active = lease;
      Future<void>? trailing;
      try {
        await feedback.begin(kind, keys: keys, x: x, y: y);
        lease.start();
        await lease.pause(warning);
        final result = await action(lease);
        trailing = Future<void>.delayed(cooldown);
        await Future.any<void>([trailing, lease.whenCancelled]);
        await lease.check();
        done.complete(result);
      } catch (error, stack) {
        if (error is ControlInterrupted || lease.cancelled) _interrupted = true;
        // A takeover during the trailing period keeps its original deadline.
        // Warning/action interruption starts the same three-second stopped tail.
        await (trailing ?? Future<void>.delayed(cooldown));
        done.completeError(error, stack);
      } finally {
        lease.dispose();
        try {
          await feedback.end();
        } catch (_) {
          _interrupted = true;
        }
        _active = null;
      }
    });
    return done.future;
  }
}
