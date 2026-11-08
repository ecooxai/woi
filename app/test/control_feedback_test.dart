import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/control_feedback.dart';

class _Native {
  bool cancelled = false;
  bool available = true;
  final events = <String>[];
  final beginnings = <Map<String, Object?>>[];
  final updates = <Map<String, Object?>>[];
  late final feedback = ControlFeedback((method, args) async {
    if (!available) throw StateError('native monitoring unavailable');
    switch (method) {
      case 'begin':
        beginnings.add(Map.of(args!));
        events.add('show:${args['kind']}');
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
        updates.add(Map.of(args!));
        events.add('update');
        return null;
    }
    throw StateError(method);
  });
}

void main() {
  for (final kind in ['pointer', 'keyboard']) {
    test(
      '$kind runs after 120ms and returns with three seconds of visible feedback',
      () {
        fakeAsync((clock) {
          final native = _Native();
          final guard = ControlGuard(native.feedback);
          var finished = false;
          guard
              .run(kind, (_) async {
                native.events.add('input');
              })
              .then((_) => finished = true);
          clock.flushMicrotasks();
          expect(native.events, ['show:$kind']);
          clock.elapse(const Duration(milliseconds: 119));
          expect(native.events, ['show:$kind']);
          clock.elapse(const Duration(milliseconds: 1));
          expect(native.events, ['show:$kind', 'input']);
          expect(finished, isTrue);
          clock.elapse(const Duration(milliseconds: 2999));
          expect(native.events, isNot(contains('hide')));
          clock.elapse(const Duration(milliseconds: 1));
          expect(native.events.last, 'hide');
          expect(clock.periodicTimerCount, 0);
        });
      },
    );
  }

  test('takeover during the short lead-in stops input and latches retries', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      final errors = <Object>[];
      var actions = 0;
      guard
          .run<void>('pointer', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      clock.elapse(const Duration(milliseconds: 50));
      native.cancelled = true;
      clock.elapse(const Duration(milliseconds: 30));
      expect(actions, 0);
      expect(errors.single, isA<ControlInterrupted>());
      expect(native.events, isNot(contains('hide')));
      guard
          .run<void>('keyboard', (_) async {
            actions++;
          })
          .catchError((Object e) {
            errors.add(e);
          });
      clock.flushMicrotasks();
      expect(errors, hasLength(2));
      expect(actions, 0);
      clock.elapse(const Duration(seconds: 3));
      expect(native.events.last, 'hide');
      guard.reset();
      guard.run('keyboard', (_) async {
        actions++;
      });
      clock.elapse(const Duration(milliseconds: 120));
      expect(actions, 1);
      clock.elapse(const Duration(seconds: 3));
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('takeover signals an in-flight action and stops further input', () {
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
      clock.elapse(const Duration(milliseconds: 150));
      native.cancelled = true;
      clock.elapse(const Duration(milliseconds: 25));
      expect(stopped, isTrue);
      expect(failure, isA<ControlInterrupted>());
      expect(native.events, isNot(contains('hide')));
      clock.elapse(const Duration(seconds: 3));
      expect(native.events.last, 'hide');
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('takeover in the third visual second blocks subsequent input', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      var actions = 0;
      var returned = false;
      Object? failure;
      guard
          .run('pointer', (_) async {
            actions++;
          })
          .then((_) => returned = true);
      clock.elapse(const Duration(milliseconds: 2500));
      expect(actions, 1);
      expect(returned, isTrue);
      native.cancelled = true;
      clock.elapse(const Duration(milliseconds: 20));
      guard
          .run<void>('keyboard', (_) async {
            actions++;
          })
          .catchError((Object e) {
            failure = e;
          });
      clock.flushMicrotasks();
      expect(failure, isA<ControlInterrupted>());
      expect(actions, 1);
      expect(native.events, isNot(contains('hide')));
      clock.elapse(const Duration(milliseconds: 600));
      expect(native.events.last, 'hide');
      expect(clock.periodicTimerCount, 0);
    });
  });

  test('sequential actions do not wait for the visual tail or hide a newer indicator', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      guard.run('pointer', (_) async {
        native.events.add('click');
      });
      guard.run('keyboard', (_) async {
        native.events.add('type');
      });
      clock.elapse(const Duration(milliseconds: 120));
      expect(native.events, ['show:pointer', 'click', 'hide', 'show:keyboard']);
      clock.elapse(const Duration(milliseconds: 120));
      expect(native.events.last, 'type');
      clock.elapse(const Duration(milliseconds: 2880));
      expect(
        native.events.where((e) => e == 'hide'),
        hasLength(1),
        reason: 'the older fade deadline cannot hide the new indicator',
      );
      clock.elapse(const Duration(milliseconds: 120));
      expect(native.events.last, 'hide');
      expect(native.events.where((e) => e == 'hide'), hasLength(2));
      expect(clock.periodicTimerCount, 0);
    });
  });

  test(
    'a slow action is not interrupted by the previous indicator deadline',
    () {
      fakeAsync((clock) {
        final native = _Native();
        final guard = ControlGuard(native.feedback);
        guard.run('pointer', (_) async {
          native.events.add('click');
        });
        clock.elapse(const Duration(milliseconds: 3000));
        guard.run('keyboard', (lease) async {
          await lease.pause(const Duration(seconds: 4));
          native.events.add('type');
        });
        clock.elapse(const Duration(seconds: 3));
        expect(native.events.where((e) => e == 'hide'), hasLength(1));
        expect(native.events, isNot(contains('type')));
        clock.elapse(const Duration(milliseconds: 1120));
        expect(native.events.last, 'type');
        clock.elapse(const Duration(seconds: 3));
        expect(native.events.last, 'hide');
        expect(clock.periodicTimerCount, 0);
      });
    },
  );

  test('reset retires a visible tail and does not cancel the new request', () {
    fakeAsync((clock) {
      final native = _Native();
      final guard = ControlGuard(native.feedback);
      guard.run('pointer', (_) async {
        native.events.add('first');
      });
      clock.elapse(const Duration(milliseconds: 120));
      guard.reset();
      guard.run('keyboard', (_) async {
        native.events.add('second');
      });
      clock.elapse(const Duration(milliseconds: 120));
      expect(native.events, [
        'show:pointer',
        'first',
        'hide',
        'reset',
        'show:keyboard',
        'second',
      ]);
      clock.elapse(const Duration(seconds: 3));
      expect(native.events.last, 'hide');
      expect(clock.periodicTimerCount, 0);
    });
  });

  for (final button in ['left', 'right']) {
    test(
      '$button cursor feedback is neutral before the action and colored during its visual tail',
      () {
        fakeAsync((clock) {
          final native = _Native();
          final guard = ControlGuard(native.feedback);
          guard.run(
            'pointer',
            (lease) async {
              await lease.update(button: button);
              native.events.add('click:$button');
            },
            x: 120,
            y: 230,
          );
          clock.elapse(const Duration(milliseconds: 119));
          expect(native.beginnings.single['button'], isNull);
          expect(native.beginnings.single['x'], 120);
          expect(native.beginnings.single['y'], 230);
          expect(native.updates, isEmpty);
          clock.elapse(const Duration(milliseconds: 1));
          expect(native.updates.single['button'], button);
          expect(native.events.last, 'click:$button');
          clock.elapse(const Duration(milliseconds: 2999));
          expect(native.events, isNot(contains('hide')));
          clock.elapse(const Duration(milliseconds: 1));
          expect(native.events.last, 'hide');
          expect(clock.periodicTimerCount, 0);
        });
      },
    );
  }

  test(
    'cancel while a native monitor query is pending cannot return success',
    () {
      fakeAsync((clock) {
        final reply = Completer<Object?>();
        final lease = ControlLease(ControlFeedback((_, _) => reply.future));
        Object? failure;
        lease.check().catchError((Object e) {
          failure = e;
        });
        clock.flushMicrotasks();
        lease.cancel();
        reply.complete(false);
        clock.flushMicrotasks();
        expect(failure, isA<ControlInterrupted>());
      });
    },
  );

  test(
    'reset while retiring a visual tail cancels the stale queued action',
    () {
      fakeAsync((clock) {
        final endGate = Completer<void>();
        final events = <String>[];
        var ends = 0;
        final feedback = ControlFeedback((method, args) async {
          if (method == 'begin') return true;
          if (method == 'interrupted') return false;
          if (method == 'end' && ends++ == 0) await endGate.future;
          return null;
        });
        final guard = ControlGuard(feedback);
        Object? staleFailure;
        guard.run('pointer', (_) async {
          events.add('first');
        });
        clock.elapse(const Duration(milliseconds: 120));
        guard
            .run<void>('keyboard', (_) async {
              events.add('stale');
            })
            .catchError((Object e) {
              staleFailure = e;
            });
        clock.flushMicrotasks();
        expect(ends, 1);
        guard.reset();
        guard.run('keyboard', (_) async {
          events.add('approved');
        });
        endGate.complete();
        clock.elapse(const Duration(milliseconds: 120));
        expect(staleFailure, isA<ControlInterrupted>());
        expect(events, ['first', 'approved']);
        clock.elapse(const Duration(seconds: 3));
        expect(clock.periodicTimerCount, 0);
      });
    },
  );

  test('missing native monitoring fails closed immediately without timers', () {
    fakeAsync((clock) {
      final native = _Native()..available = false;
      final guard = ControlGuard(native.feedback);
      var acted = false;
      Object? failure;
      guard
          .run<void>('pointer', (_) async {
            acted = true;
          })
          .catchError((Object e) {
            failure = e;
          });
      clock.flushMicrotasks();
      expect(acted, isFalse);
      expect(failure, isA<StateError>());
      expect(clock.periodicTimerCount, 0);
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });
}
