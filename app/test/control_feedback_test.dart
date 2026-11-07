import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/control_feedback.dart';

class _Native {
  bool cancelled = false;
  bool available = true;
  final events = <String>[];
  late final feedback = ControlFeedback((method, args) async {
    if (!available) throw StateError('native monitoring unavailable');
    switch (method) {
      case 'begin':
        events.add('show:${args!['kind']}');
        return !cancelled;
      case 'interrupted':
        return cancelled;
      case 'end':
        events.add('hide');
        return null;
      case 'reset':
        cancelled = false;
        events.add('reset');
        return null;
      case 'update':
        events.add('update');
        return null;
    }
    throw StateError(method);
  });
}

void main() {
  test('input waits one second; overlay stays one second after it', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      var finished = false;
      guard
          .run('keyboard', (_) async {
            native.events.add('type');
          })
          .then((_) => finished = true);
      clock.flushMicrotasks();
      expect(native.events, ['show:keyboard']);
      clock.elapse(const Duration(milliseconds: 999));
      expect(native.events, ['show:keyboard']);
      clock.elapse(const Duration(milliseconds: 1));
      expect(native.events, ['show:keyboard', 'type']);
      expect(finished, isFalse);
      clock.elapse(const Duration(milliseconds: 999));
      expect(native.events, isNot(contains('hide')));
      clock.elapse(const Duration(milliseconds: 1));
      expect(native.events.last, 'hide');
      expect(finished, isTrue);
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('user movement during warning cancels input and latches retries', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      final errors = <Object>[];
      var actions = 0;
      guard
          .run('pointer', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      clock.elapse(const Duration(milliseconds: 250));
      native.cancelled = true;
      clock.elapse(const Duration(milliseconds: 30));
      expect(actions, 0);
      expect(native.events, isNot(contains('hide')));
      clock.elapse(const Duration(seconds: 1));
      expect(errors.single, isA<ControlInterrupted>());
      guard
          .run('keyboard', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      clock.flushMicrotasks();
      expect(errors, hasLength(2));
      expect(actions, 0);
      guard.reset();
      guard.run('keyboard', (_) async {
        actions++;
      });
      clock.elapse(const Duration(seconds: 3));
      expect(actions, 1);
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('takeover signals a running operation and stops further input', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      var stopped = false;
      Object? failure;
      guard
          .run<void>('keyboard', (lease) async {
            await lease.whenCancelled;
            stopped = true;
            await lease.check();
            fail('No input may continue after takeover');
          })
          .catchError((Object e) {
            failure = e;
          });
      clock.elapse(const Duration(milliseconds: 1100));
      native.cancelled = true;
      clock.elapse(const Duration(milliseconds: 25));
      expect(stopped, isTrue);
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isA<ControlInterrupted>());
      expect(native.events.last, 'hide');
    });
  });

  test('takeover during cooldown prevents the next queued operation', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      var actions = 0;
      final errors = <Object>[];
      guard
          .run('pointer', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      guard
          .run('keyboard', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      clock.elapse(const Duration(milliseconds: 1200));
      expect(actions, 1);
      native.cancelled = true;
      clock.elapse(const Duration(seconds: 2));
      expect(actions, 1);
      expect(errors, hasLength(2));
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('operations are serialized including warning and cooldown', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      guard.run('pointer', (_) async {
        native.events.add('click');
      });
      guard.run('keyboard', (_) async {
        native.events.add('type');
      });
      clock.elapse(const Duration(seconds: 2));
      expect(native.events, ['show:pointer', 'click', 'hide', 'show:keyboard']);
      clock.elapse(const Duration(seconds: 2));
      expect(native.events, [
        'show:pointer',
        'click',
        'hide',
        'show:keyboard',
        'type',
        'hide',
      ]);
    });
  });

  test('missing native monitoring fails closed and does not leave timers', () {
    fakeAsync((clock) {
      final native = _Native()..available = false;
      final guard = ControlGuard(native.feedback);
      var acted = false;
      Object? failure;
      guard
          .run('pointer', (_) async {
            acted = true;
          })
          .catchError((Object e) {
            failure = e;
          });
      clock.elapse(const Duration(seconds: 2));
      expect(acted, isFalse);
      expect(failure, isA<StateError>());
      expect(clock.periodicTimerCount, 0);
    });
  });
}
