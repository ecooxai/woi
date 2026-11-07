import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/message_tile.dart';

import '../fakes/fakes.dart';

void main() {
  const attachment = ImageAttachment(
    path: '/missing-layout-fixture.jpg',
    width: 1024,
    height: 1024,
    originalWidth: 1024,
    originalHeight: 1024,
  );

  Future<void> show(WidgetTester tester, Message message, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(
          body: Center(
            child: MessageTile(message: message, audio: FakeAudioIO(), viewer: FakeViewer()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final width in [360.0, 900.0]) {
    testWidgets('user text stays above its image at $width px, including streaming text', (tester) async {
      for (final streaming in [false, true]) {
        final message = Message(
          kind: MessageKind.user,
          text: 'Please edit this image to add a blue sky.',
          image: attachment,
          streaming: streaming,
          createdAt: DateTime(2020),
        );
        await show(tester, message, width);
        final text = find.text(message.text);
        final image = find.byType(ScreenshotThumb);
        expect(text, findsOneWidget);
        expect(image, findsOneWidget);
        expect(tester.getBottomLeft(text).dy, lessThan(tester.getTopLeft(image).dy));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('spoken user label stays above its attached image', (tester) async {
    await show(
      tester,
      Message(kind: MessageKind.user, text: '[2.6 s of speech]', image: attachment, createdAt: DateTime(2020)),
      360,
    );
    expect(
      tester.getBottomLeft(find.text('Voice message')).dy,
      lessThan(tester.getTopLeft(find.byType(ScreenshotThumb)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant image remains above its explanatory text', (tester) async {
    final message = Message(
      kind: MessageKind.assistant,
      text: 'Here is the image with a blue sky.',
      image: attachment,
      createdAt: DateTime(2020),
    );
    await show(tester, message, 360);
    expect(
      tester.getBottomLeft(find.byType(ScreenshotThumb)).dy,
      lessThan(tester.getTopLeft(find.text(message.text)).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
