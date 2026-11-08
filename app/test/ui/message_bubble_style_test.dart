import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/glass.dart';
import 'package:woi/ui/widgets/message_tile.dart';

import '../fakes/fakes.dart';

final _stamp = DateTime(2020, 1, 1, 12, 34);

Finder _bubble(String id) => find.byKey(ValueKey('message-bubble-$id'));

Color _fill(WidgetTester tester, String id) =>
    (tester.widget<Container>(_bubble(id)).decoration! as BoxDecoration).color!;

Color _textColor(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final color = paragraph.text.style?.color;
  expect(color, isNotNull, reason: 'Rendered message text needs an explicit readable color.');
  return color!;
}

double _contrast(Color foreground, Color background) {
  final painted = Color.alphaBlend(foreground, background);
  final a = painted.computeLuminance(), b = background.computeLuminance();
  return ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
}

void _expectReadableText(WidgetTester tester, Finder within, Color background) {
  for (final element in find.descendant(of: within, matching: find.byType(Text)).evaluate()) {
    final text = element.widget as Text;
    expect(
      _contrast(_textColor(tester, find.byWidget(text)), background),
      greaterThanOrEqualTo(4.5),
      reason: 'Text "${text.data}" must stay readable on the message surface.',
    );
  }
}

void main() {
  tearDown(() => WoiColors.use(WoiPalette.light));

  Future<void> show(WidgetTester tester, List<Message> messages, WoiPalette palette, {double width = 360}) async {
    await tester.binding.setSurfaceSize(Size(width, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    WoiColors.use(palette);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(palette),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final message in messages)
                    MessageTile(message: message, audio: FakeAudioIO(), viewer: FakeViewer()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
  }

  for (final palette in [WoiPalette.light, WoiPalette.dark]) {
    for (final width in [360.0, 900.0]) {
      testWidgets('assistant avatar is above the bubble with readable light surfaces: ${palette.brightness}, $width', (
        tester,
      ) async {
        final user = Message(id: 'user', kind: MessageKind.user, text: 'Please explain this image.', createdAt: _stamp);
        final reply = Message(
          id: 'reply',
          kind: MessageKind.assistant,
          text: 'Here is a clear explanation with enough text to check the compact message layout.',
          createdAt: _stamp,
          meta: {'model': 'gpt-live-1.1'},
        );
        await show(tester, [user, reply], palette, width: width);
        final avatar = tester.getRect(find.byKey(const ValueKey('reply-avatar-reply')));
        final replyBox = tester.getRect(_bubble('reply'));
        expect(avatar.bottom, lessThan(replyBox.top));
        expect(avatar.center.dx, inInclusiveRange(replyBox.left, replyBox.right));
        expect(find.byKey(const ValueKey('reply-avatar-user')), findsNothing);
        for (final id in ['user', 'reply']) {
          final bounds = tester.getRect(_bubble(id));
          final fill = _fill(tester, id);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          expect(fill.computeLuminance(), greaterThan(0.9), reason: 'Both requested message surfaces stay light.');
          _expectReadableText(tester, _bubble(id), fill);
        }
        final userFill = _fill(tester, 'user'), assistantFill = _fill(tester, 'reply');
        expect(userFill, Colors.white, reason: 'User messages have the requested white background.');
        expect(assistantFill.g, greaterThan(assistantFill.r));
        expect(assistantFill.g, greaterThan(assistantFill.b));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('voice, listening and partial user transcripts remain readable in the dark theme', (tester) async {
    final voice = Message(
      id: 'voice',
      kind: MessageKind.user,
      text: '[2.6 s of speech]',
      audio: const AudioClip(path: '/voice-fixture.wav', durationMs: 2600),
      createdAt: _stamp,
    );
    final partial = Message(
      id: 'partial',
      kind: MessageKind.user,
      text: 'Still transcribing the request',
      streaming: true,
      createdAt: _stamp,
    );
    final listening = Message(id: 'listening', kind: MessageKind.user, streaming: true, createdAt: _stamp);
    await show(tester, [voice, partial, listening], WoiPalette.dark);
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('listening'), findsOneWidget);
    expect(tester.widget<Text>(find.text(partial.text)).style?.fontStyle, FontStyle.italic);
    for (final id in ['voice', 'partial', 'listening']) {
      _expectReadableText(tester, _bubble(id), _fill(tester, id));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('generated media, audio, interrupted status and source links remain readable on pale green', (
    tester,
  ) async {
    const image = ImageAttachment(
      path: '/missing-message-style-fixture.jpg',
      width: 1024,
      height: 1024,
      originalWidth: 1254,
      originalHeight: 1254,
      byteSize: 63918,
      generationDurationMs: 15710,
      generationModel: 'gpt-image-2.6-flare',
      generationQuality: 'low',
    );
    final generated = Message(
      id: 'generated',
      kind: MessageKind.assistant,
      text: 'Here is the edited image.',
      image: image,
      audio: const AudioClip(path: '/reply-fixture.wav', durationMs: 2600),
      interrupted: true,
      createdAt: _stamp,
      meta: {'model': 'gpt-image-2.6-flare'},
    );
    final search = Message(
      id: 'search',
      kind: MessageKind.assistant,
      text: 'The documentation explains asynchronous code.',
      createdAt: _stamp,
      meta: {
        'type': 'web_search',
        'model': 'gpt-6.1-sol',
        'sources': [
          {'url': 'https://dart.dev/libraries/async', 'title': 'Dart async'},
        ],
      },
    );
    await show(tester, [generated, search], WoiPalette.dark);
    expect(find.textContaining('Generated in 15.7 s'), findsOneWidget);
    expect(find.textContaining('63.9 KB'), findsOneWidget);
    expect(find.text('Dart async · dart.dev'), findsOneWidget);
    for (final id in ['generated', 'search']) {
      _expectReadableText(tester, _bubble(id), _fill(tester, id));
    }
    final pill = tester.widget<Container>(
      find.descendant(of: find.byType(Pill), matching: find.byType(Container)).first,
    );
    final generatedFill = _fill(tester, 'generated');
    final pillFill = Color.alphaBlend((pill.decoration! as BoxDecoration).color!, generatedFill);
    expect(_contrast(_textColor(tester, find.text('interrupted')), pillFill), greaterThanOrEqualTo(4.5));
    for (var attempt = 0; attempt < 20 && find.byIcon(Icons.broken_image_outlined).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final icon = tester.widget<Icon>(find.byIcon(Icons.broken_image_outlined));
    expect(_contrast(icon.color!, generatedFill), greaterThanOrEqualTo(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending and failed image states keep readable labels and an avatar above the bubble', (tester) async {
    final message = Message(
      id: 'edit',
      kind: MessageKind.assistant,
      text: 'Editing image…',
      createdAt: _stamp,
      meta: {'type': 'image_generation', 'status': 'pending', 'action': 'edit'},
    );
    for (final status in ['pending', 'failed', 'interrupted']) {
      message.meta['status'] = status;
      message.text = status == 'pending' ? 'Editing image…' : 'Please attach the source image again.';
      await show(tester, [message], WoiPalette.dark);
      expect(find.byKey(ValueKey('image-generation-$status')), findsOneWidget);
      _expectReadableText(tester, _bubble('edit'), _fill(tester, 'edit'));
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('reply-avatar-edit'))).dy,
        lessThan(tester.getTopLeft(_bubble('edit')).dy),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('system generated-image metadata retains the app theme outside light bubbles', (tester) async {
    const image = ImageAttachment(
      path: '/missing-system-style-fixture.jpg',
      width: 1024,
      height: 1024,
      originalWidth: 1024,
      originalHeight: 1024,
      generationDurationMs: 1000,
    );
    await show(tester, [
      Message(id: 'system', kind: MessageKind.system, text: 'Saved image', image: image, createdAt: _stamp),
    ], WoiPalette.dark);
    expect(find.byKey(const ValueKey('reply-avatar-system')), findsNothing);
    expect(
      _contrast(_textColor(tester, find.text('Generated in 1.0 s')), WoiPalette.dark.bg0),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.takeException(), isNull);
  });
}
