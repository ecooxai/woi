import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_input_control.dart';
import 'package:woi/platform/control_feedback.dart';
import 'package:woi/platform/input_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(AndroidBridge.method, null));

  test('left tap and right long press retain their actual native button', () async {
    final input = AndroidInputControl();
    await input.click(120, 230);
    await input.click(450, 670, button: MouseButton.right);
    expect(calls.map((c) => c.method), ['click', 'click']);
    expect(calls[0].arguments, {'x': 120, 'y': 230, 'button': 'left'});
    expect(calls[1].arguments, {'x': 450, 'y': 670, 'button': 'right'});
  });

  test('double tap is explicitly left and unsupported buttons emit no input', () async {
    final input = AndroidInputControl();
    await input.doubleClick(140, 250);
    expect(calls.single.method, 'doubleClick');
    expect(calls.single.arguments, {'x': 140, 'y': 250, 'button': 'left'});
    calls.clear();
    await expectLater(input.click(1, 2, button: MouseButton.middle), throwsUnsupportedError);
    await expectLater(input.doubleClick(1, 2, button: MouseButton.middle), throwsUnsupportedError);
    await expectLater(input.doubleClick(1, 2, button: MouseButton.right), throwsUnsupportedError);
    expect(calls, isEmpty);
    expect(await input.mouseLocation(), const Point(140, 250));
  });

  test('move-only pointer updates stay neutral and never emit a native tap', () async {
    final feedbackCalls = <(String, Map<String, Object?>?)>[];
    final feedback = ControlFeedback((method, args) async {
      feedbackCalls.add((method, args));
      return method == 'begin'
          ? true
          : method == 'interrupted'
          ? false
          : null;
    });
    final input = AndroidInputControl(
      control: ControlGuard(feedback, warning: Duration.zero, cooldown: Duration.zero),
    );
    await input.moveMouse(190, 280);
    expect(calls, isEmpty);
    final begin = feedbackCalls.singleWhere((c) => c.$1 == 'begin').$2!;
    final update = feedbackCalls.singleWhere((c) => c.$1 == 'update').$2!;
    expect(begin, {'kind': 'pointer', 'keys': '', 'x': 190, 'y': 280});
    expect(update, {'keys': null, 'x': 190, 'y': 280, 'button': null});
    expect(await input.mouseLocation(), const Point(190, 280));
  });
  void keyboardReplies({String delivery = 'dispatched', String backend = 'android_accessibility_input_connection'}) {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      if (call.method == 'typeText') return 'ime_dispatched';
      final args = call.arguments as Map<Object?, Object?>;
      return {
        'completed': (args['operations'] as List).length,
        'package': 'com.example.editor',
        'delivery': delivery,
        'backend': backend,
      };
    });
  }

  test('exact copy shortcuts and combined modifiers use one ordered native batch', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    final result = await input.sendKeys(keys: 'ctrl+a ctrl+c ctrl+shift+c ctrl+alt+shift+k meta+v');
    expect(calls.map((c) => c.method), ['sendKeys']);
    expect(calls.single.arguments, {
      'operations': [
        {
          'type': 'key',
          'key': 'a',
          'modifiers': ['ctrl'],
        },
        {
          'type': 'key',
          'key': 'c',
          'modifiers': ['ctrl'],
        },
        {
          'type': 'key',
          'key': 'c',
          'modifiers': ['ctrl', 'shift'],
        },
        {
          'type': 'key',
          'key': 'k',
          'modifiers': ['ctrl', 'shift', 'alt'],
        },
        {
          'type': 'key',
          'key': 'v',
          'modifiers': ['super'],
        },
      ],
    });
    expect(result.toJson(), {
      'keys': 'ctrl+a ctrl+c ctrl+shift+c ctrl+shift+alt+k super+v',
      'window': 'com.example.editor',
      'class': 'com.example.editor',
      'delivery': 'dispatched',
      'backend': 'android_accessibility_input_connection',
    });
  });

  test('semantic edits stay separate from physical shortcut intent', () async {
    keyboardReplies(delivery: 'applied', backend: 'android_accessibility_action');
    final input = AndroidInputControl();
    for (final action in [KeyAction.copy, KeyAction.paste, KeyAction.cut, KeyAction.selectAll]) {
      final result = await input.sendKeys(action: action);
      expect(result.delivery, 'applied');
      expect((calls.last.arguments as Map)['operations'], [
        {'type': 'edit', 'name': action.wire},
      ]);
    }
    calls.clear();
    await input.sendKeys(keys: 'ctrl+c ctrl+v ctrl+x ctrl+a');
    expect(
      ((calls.single.arguments as Map)['operations'] as List).map((op) => (op as Map)['type']),
      everyElement('key'),
    );
  });

  test('undo and redo use real input connection chords', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    await input.sendKeys(action: KeyAction.undo);
    await input.sendKeys(action: KeyAction.redo);
    expect((calls[0].arguments as Map)['operations'], [
      {
        'type': 'key',
        'key': 'z',
        'modifiers': ['ctrl'],
      },
    ]);
    expect((calls[1].arguments as Map)['operations'], [
      {
        'type': 'key',
        'key': 'z',
        'modifiers': ['ctrl', 'shift'],
      },
    ]);
  });

  test('bare modifiers tap their actual keys without becoming phone Home', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    for (final modifier in ['ctrl', 'shift', 'alt', 'super']) {
      await input.sendKeys(keys: modifier);
      expect((calls.last.arguments as Map)['operations'], [
        {'type': 'key', 'key': modifier, 'modifiers': <String>[]},
      ]);
    }
  });

  test('phone navigation mappings require their exact modifier combination', () async {
    keyboardReplies(delivery: 'applied', backend: 'android_accessibility_global');
    final input = AndroidInputControl();
    for (final pair in [('home', 'home'), ('escape', 'back'), ('alt+tab', 'recents'), ('alt+left', 'back')]) {
      await input.sendKeys(keys: pair.$1);
      expect((calls.last.arguments as Map)['operations'], [
        {'type': 'global', 'name': pair.$2},
      ]);
    }
    calls.clear();
    await input.sendKeys(keys: 'ctrl+alt+tab alt+shift+left ctrl+home');
    expect(
      ((calls.single.arguments as Map)['operations'] as List).map((op) => (op as Map)['type']),
      everyElement('key'),
    );
  });

  test('literal text remains exact including newlines and Unicode', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    const text = 'A + B; "quoted"\n雪🙂';
    await input.typeText(text);
    expect(calls.single.method, 'typeText');
    expect(calls.single.arguments, {'text': text});
    await input.typeText('');
    expect(calls.length, 1);
  });

  test('explicit Android target is checked natively and is never silently dropped', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    await input.sendKeys(
      keys: 'ctrl+v',
      target: const KeyTarget(window: '  com.example.editor  '),
    );
    expect((calls.single.arguments as Map)['target'], 'com.example.editor');
    calls.clear();
    await expectLater(
      input.sendKeys(
        keys: 'home',
        target: const KeyTarget(window: 'editor'),
      ),
      throwsUnsupportedError,
    );
    expect(calls, isEmpty);
  });

  test('unsupported later keys and mixed navigation fail before any native input', () async {
    keyboardReplies();
    final input = AndroidInputControl();
    await expectLater(input.sendKeys(keys: 'ctrl+a f24'), throwsUnsupportedError);
    await expectLater(input.sendKeys(keys: 'home ctrl+a'), throwsUnsupportedError);
    await expectLater(input.sendKeys(keys: 'ctrl+é'), throwsUnsupportedError);
    expect(calls, isEmpty);
  });

  test('partial native failure is reported once without replay or semantic fallback', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      throw PlatformException(
        code: 'input_stopped',
        message: 'Keyboard request stopped after 1/2 operations; input may already have been sent',
        details: {'completed': 1, 'retry_safe': false},
      );
    });
    final input = AndroidInputControl();
    await expectLater(
      input.sendKeys(keys: 'ctrl+a ctrl+c'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('1/2'))),
    );
    expect(calls.map((c) => c.method), ['sendKeys']);
  });

  test('missing input connection stays an error rather than pretending shortcut success', () async {
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      throw PlatformException(code: 'no_input_target', message: 'No active input connection in the focused app');
    });
    final input = AndroidInputControl();
    await expectLater(input.sendKeys(keys: 'ctrl+alt+shift+k'), throwsStateError);
    await expectLater(input.typeText('literal'), throwsStateError);
    expect(calls.map((c) => c.method), ['sendKeys', 'typeText']);
  });

  test('incomplete or absent native receipts cannot report success', () async {
    for (final reply in [
      null,
      false,
      {'completed': 0, 'delivery': 'dispatched', 'backend': 'android_accessibility_input_connection'},
    ]) {
      messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
        calls.add(call);
        return reply;
      });
      await expectLater(AndroidInputControl().sendKeys(keys: 'ctrl+a'), throwsStateError);
    }
    expect(calls.length, 3);
  });

  test('keys and semantic action are mutually exclusive before dispatch', () async {
    final input = AndroidInputControl();
    await expectLater(input.sendKeys(), throwsArgumentError);
    await expectLater(input.sendKeys(keys: 'ctrl+c', action: KeyAction.copy), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('keyCombo uses the same complete batch and native receipt as sendKeys', () async {
    keyboardReplies();
    await AndroidInputControl().keyCombo('ctrl+a ctrl+v');
    expect(calls.map((call) => call.method), ['sendKeys']);
    expect((calls.single.arguments as Map)['operations'], [
      {
        'type': 'key',
        'key': 'a',
        'modifiers': ['ctrl'],
      },
      {
        'type': 'key',
        'key': 'v',
        'modifiers': ['ctrl'],
      },
    ]);
  });
  test('Stop reaches a blocked native batch before queued reset and preserves the approved next turn', () async {
    final nativeStarted = Completer<void>();
    final nativeCancelled = Completer<void>();
    final heldReply = Completer<Map<String, Object?>>();
    final journal = <String>[];
    var requests = 0;
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      if (call.method == 'cancelKeyboard') {
        journal.add('native cancel');
        nativeCancelled.complete();
        return true;
      }
      requests++;
      journal.add('native batch $requests');
      if (requests == 1) {
        nativeStarted.complete();
        return heldReply.future;
      }
      return {
        'completed': ((call.arguments as Map)['operations'] as List).length,
        'package': 'com.example.editor',
        'delivery': 'dispatched',
        'backend': 'android_accessibility_input_connection',
      };
    });
    final feedback = ControlFeedback((method, args) async {
      if (method == 'reset') journal.add('queued reset');
      return method == 'begin'
          ? true
          : method == 'interrupted'
          ? false
          : null;
    });
    final input = AndroidInputControl(
      control: ControlGuard(feedback, warning: Duration.zero, cooldown: Duration.zero),
    );
    final first = input.sendKeys(keys: 'ctrl+a ctrl+c');
    final firstCancelled = expectLater(first, throwsA(isA<ControlInterrupted>()));
    await nativeStarted.future;
    final stopped = input.rememberTargetWindow();
    // Apply/new-turn code may queue its continuation immediately after this
    // call yields. It must capture the already-invalidated Dart generation.
    final approved = input.sendKeys(keys: 'ctrl+v');
    await nativeCancelled.future;
    expect(journal, ['native batch 1', 'native cancel']);
    expect(journal, isNot(contains('queued reset')));
    // Even an in-flight success reply is discarded after Stop. The real native
    // epoch tests separately prove later callbacks do not dispatch more keys.
    heldReply.complete({
      'completed': 2,
      'package': 'com.example.editor',
      'delivery': 'dispatched',
      'backend': 'android_accessibility_input_connection',
    });
    await firstCancelled;
    await stopped;
    expect((await approved).delivery, 'dispatched');
    expect(journal, ['native batch 1', 'native cancel', 'queued reset', 'native batch 2']);
    expect(calls.map((call) => call.method), ['sendKeys', 'cancelKeyboard', 'sendKeys']);
  });

  test('unavailable native Stop is best effort while queued guard reset still completes', () async {
    var resets = 0;
    messenger.setMockMethodCallHandler(AndroidBridge.method, (call) async {
      calls.add(call);
      throw PlatformException(code: 'no_accessibility', message: 'Service is detached');
    });
    final input = AndroidInputControl(
      control: ControlGuard(
        ControlFeedback((method, args) async {
          if (method == 'reset') resets++;
          return null;
        }),
        warning: Duration.zero,
        cooldown: Duration.zero,
      ),
    );
    await input.rememberTargetWindow();
    expect(resets, 1);
    expect(calls.map((call) => call.method), ['cancelKeyboard']);
  });
}
