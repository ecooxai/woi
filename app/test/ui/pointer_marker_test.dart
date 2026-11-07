import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/screens/home_screen.dart' show toolScreenshotsForMessages;
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/message_tile.dart';

import '../fakes/fakes.dart';

ImageAttachment shot(String name, {bool generated = false}) => ImageAttachment(
  path: '/$name.jpg',
  width: 640,
  height: 360,
  originalWidth: 1280,
  originalHeight: 720,
  generationDurationMs: generated ? 1000 : null,
);

Message capture(String id, ImageAttachment? image, {String? callId, String type = 'screenshot', String? kind}) =>
    Message(
      id: id,
      kind: MessageKind.system,
      createdAt: DateTime(2020),
      image: image,
      meta: {'type': type, 'pointerCallId': ?callId, 'imageKind': ?kind},
    );

Message tool(
  String callId, {
  String name = 'click_screen',
  ToolStatus status = ToolStatus.success,
  Map<String, Object?>? args,
  Map<String, Object?>? result,
}) => Message(
  id: 'tool-$callId',
  kind: MessageKind.tool,
  createdAt: DateTime(2020),
  tool: ToolCallInfo(
    callId: callId,
    name: name,
    status: status,
    argsJson: jsonEncode(args ?? {'x': 10, 'y': 20}),
    resultJson: jsonEncode(result ?? {'ok': true}),
  ),
);

void main() {
  test('generated artwork and camera/media context never replace a screen capture', () {
    final screen = shot('screen');
    final messages = [
      capture('screen', screen),
      capture('generated', shot('artwork', generated: true)),
      capture('generated-meta', shot('artwork-meta'), type: 'image_generation'),
      capture('camera', shot('camera'), type: 'camera'),
      capture('camera-kind', shot('camera-kind'), kind: 'camera'),
      capture('media', shot('media'), type: 'media'),
      capture('media-kind', shot('media-kind'), kind: 'media'),
      tool('click'),
    ];
    expect(toolScreenshotsForMessages(messages).last, same(screen));
    expect(toolScreenshotsForMessages(messages.sublist(1)).last, isNull);
  });

  test('exact pointer call IDs select captures even when appended later and out of order', () {
    final first = shot('fresh-first'), second = shot('fresh-second');
    final messages = [
      capture('old', shot('old-screen')),
      tool('first', name: 'control_pointer'),
      tool('second'),
      capture('second-shot', second, callId: 'second'),
      capture('first-shot', first, callId: 'first'),
      tool('not-captured', name: 'control_pointer'),
    ];
    final chosen = toolScreenshotsForMessages(messages);
    expect(chosen[1], same(first));
    expect(chosen[2], same(second));
    expect(chosen.last, isNull, reason: "A fresh pointer call cannot borrow another action's screenshot");
  });

  test('a linked capture still saving suppresses unrelated chronological fallback', () {
    final messages = [capture('old', shot('old-screen')), tool('pending'), capture('saving', null, callId: 'pending')];
    expect(toolScreenshotsForMessages(messages)[1], isNull);
    messages[2] = capture('invalid-context', shot('camera'), callId: 'pending', type: 'camera');
    expect(toolScreenshotsForMessages(messages)[1], isNull);
  });

  test('legacy user screenshots still support direct click markers', () {
    final screen = shot('legacy-screen');
    final messages = [Message(kind: MessageKind.user, image: screen), tool('legacy')];
    expect(toolScreenshotsForMessages(messages).last, same(screen));
  });

  Future<void> show(WidgetTester tester, Message message, ImageAttachment screenshot) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolCallCard(
              message: message,
              screenshot: screenshot,
              viewer: FakeViewer(),
              initiallyExpanded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final name in ['click_screen', 'control_pointer']) {
    testWidgets('$name marks the executed Luna coordinate on its captured screen at360px', (tester) async {
      final screen = shot('fresh-screen');
      await show(
        tester,
        tool(
          'click',
          name: name,
          args: name == 'click_screen' ? {'x': 10, 'y': 20} : {'action': 'click', 'request': 'Click Save'},
          result: {
            'ok': true,
            'model': 'gpt-6-luna',
            'action': 'click',
            'image_xy': [80, 45],
            'screen_xy': [160, 90],
          },
        ),
        screen,
      );
      final thumb = tester.widget<ScreenshotThumb>(find.byType(ScreenshotThumb));
      expect(thumb.image, same(screen));
      expect(thumb.marker, const Offset(80, 45));
      expect(tester.getSize(find.byType(ScreenshotThumb)).width, lessThanOrEqualTo(280));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pointer moves and failed clicks do not show a completed click marker', (tester) async {
    final screen = shot('fresh-screen');
    await show(
      tester,
      tool(
        'move',
        name: 'control_pointer',
        result: {
          'ok': true,
          'action': 'move',
          'clicked': false,
          'image_xy': [80, 45],
        },
      ),
      screen,
    );
    expect(find.byType(ScreenshotThumb), findsNothing);
    await show(tester, tool('failed', status: ToolStatus.error, result: {'error': 'Target not found'}), screen);
    expect(find.byType(ScreenshotThumb), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
