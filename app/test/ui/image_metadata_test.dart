import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/auth/pkce_login.dart';
import 'package:woi/core/images/media_metadata.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/platform/media_viewer.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/viewer/viewer_app.dart';
import 'package:woi/ui/widgets/image_viewer.dart';
import 'package:woi/ui/widgets/media_metadata_label.dart';
import 'package:woi/ui/widgets/message_tile.dart';

import '../fakes/fakes.dart';

Widget app(Widget child) => MaterialApp(
  theme: buildWoiTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 600, child: child)),
  ),
);

// File.stat and native encoded-image header IO complete outside Flutter's
// fake clock. Alternate a bounded real-IO yield with a frame until this widget's
// own FutureBuilder has painted its facts; a separate file read is not a signal
// that all of the widget's staged async continuations have completed.
Future<void> waitForFileMetadata(WidgetTester tester, Finder expected) async {
  for (
    var attempt = 0;
    attempt < 200 && expected.evaluate().isEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> imageFile() async {
    final dir = await Directory.systemTemp.createTemp('woi-image-ui-');
    addTearDown(() => dir.delete(recursive: true));
    return File('${dir.path}/picture.png')
        .writeAsBytes(img.encodePng(img.Image(width: 7, height: 5)));
  }

  test(
    'large-view facts use encoded file bytes and native image dimensions',
    () async {
      final file = await imageFile();
      final metadata = await MediaMetadata.read(file, image: true);
      expect(metadata!.width, 7);
      expect(metadata.height, 5);
      expect(metadata.byteSize, await file.length());
      expect(metadata.label, '7 × 5 px · ${await file.length()} B');
      final plain = File('${file.parent.path}/notes.txt');
      await plain.writeAsBytes(List.filled(1536, 65));
      expect((await MediaMetadata.read(plain))!.label, '1.5 KB');
      expect(
        await MediaMetadata.read(File('${file.parent.path}/missing.png')),
        isNull,
      );
      expect(formatGenerationDuration(13694), '13.7 s');
      expect(formatGenerationDuration(75100), '1 min 15.1 s');
    },
  );

  testWidgets(
    'actual controller pending and failure metadata show clear states',
    (tester) async {
      final message = Message(
        kind: MessageKind.assistant,
        createdAt: DateTime(2020),
        text: 'Generating image…',
        meta: {
          'type': 'image_generation',
          'status': 'pending',
          'prompt': 'A green circle',
          'model': 'gpt-image-flare-2.1',
          'quality': 'low',
        },
      );
      Widget tile() => app(
        MessageTile(
          message: message,
          audio: FakeAudioIO(),
          viewer: FakeViewer(),
        ),
      );
      await tester.pumpWidget(tile());
      expect(find.text('Generating image…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(messageDisplayText(message), isEmpty);
      message.text = '  Generating image...  ';
      await tester.pumpWidget(tile());
      expect(find.text('Generating image…'), findsOneWidget);
      expect(find.text('  Generating image...  '), findsNothing);
      message.text = 'A green circle';
      await tester.pumpWidget(tile());
      expect(find.text('Generating image…'), findsOneWidget);
      expect(find.text('A green circle'), findsOneWidget);
      message.meta['status'] = 'failed';
      message.text = 'The provider rejected the selected image model.';
      await tester.pumpWidget(tile());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Generating image…'), findsNothing);
      expect(find.text('Image generation failed'), findsOneWidget);
      expect(
        find.text('The provider rejected the selected image model.'),
        findsOneWidget,
      );
      message.meta['status'] = 'interrupted';
      await tester.pumpWidget(tile());
      expect(find.text('Image generation interrupted'), findsOneWidget);
    },
  );

  testWidgets('actual pending edit metadata shows one editing status', (
    tester,
  ) async {
    final message = Message(
      kind: MessageKind.assistant,
      createdAt: DateTime(2020),
      text: 'Editing image…',
      meta: {
        'type': 'image_generation',
        'status': 'pending',
        'action': 'edit',
        'prompt': 'Make the sky blue',
        'source_message_id': 'previous-generated-image',
      },
    );
    Widget tile() => app(
      MessageTile(message: message, audio: FakeAudioIO(), viewer: FakeViewer()),
    );
    await tester.pumpWidget(tile());
    expect(find.text('Editing image…'), findsOneWidget);
    expect(find.text('Generating image…'), findsNothing);
    expect(messageDisplayText(message), isEmpty);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    message.text = 'Make the sky blue';
    await tester.pumpWidget(tile());
    expect(find.text('Editing image…'), findsOneWidget);
    expect(find.text('Make the sky blue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search sources use platform browser and hide opaque citation handles',
    (tester) async {
      final opener = _Opener();
      final message = Message(
        kind: MessageKind.assistant,
        createdAt: DateTime(2020),
        text: 'Futures represent eventual results. citeturn0search0',
        meta: {
          'type': 'web_search',
          'sources': [
            {'url': 'https://dart.dev/libraries/async', 'title': 'Dart async'},
            {'url': 'javascript:alert(1)', 'title': 'Invalid'},
          ],
        },
      );
      await tester.pumpWidget(
        app(
          MessageTile(
            message: message,
            audio: FakeAudioIO(),
            viewer: FakeViewer(),
            urlOpener: opener,
          ),
        ),
      );
      expect(find.textContaining('turn0search0'), findsNothing);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Invalid'), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey('search-source-https://dart.dev/libraries/async'),
        ),
      );
      await tester.pump();
      expect(opener.opened, [Uri.parse('https://dart.dev/libraries/async')]);
      expect(opener.keepAliveRequests, [false]);
    },
  );

  testWidgets(
    'real lightbox route shows media facts without fallback text decorations',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final file = await tester.runAsync(imageFile);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showImageLightbox(
                  context,
                  file!.path,
                  caption: 'Generated image',
                  generationDurationMs: 13694,
                  generationModel: 'gpt-image-flare-2.1',
                  generationQuality: 'low',
                ),
              ),
              child: const Text('Open image'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open image'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await waitForFileMetadata(tester, find.textContaining('7 × 5 px'));
      expect(find.byType(MediaMetadataLabel), findsOneWidget);
      expect(
        find.textContaining('7 × 5 px'),
        findsOneWidget,
        reason: tester
            .widget<Text>(find.byKey(const ValueKey('media-file-metadata')))
            .data,
      );
      final byteSize = await tester.runAsync(file!.length);
      expect(find.textContaining('$byteSize B'), findsOneWidget);
      expect(find.textContaining('Generated in 13.7 s'), findsOneWidget);
      expect(find.textContaining('low quality'), findsOneWidget);
      for (final text in [
        find.text('Generated image'),
        find.byKey(const ValueKey('media-file-metadata')),
        find.text('100%'),
      ]) {
        expect(text, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(
          paragraph.text.style?.decoration ?? TextDecoration.none,
          TextDecoration.none,
          reason: 'Rendered lightbox text must not inherit the double-underline warning style.',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close (Esc)'));
      await tester.pumpAndSettle();
      expect(find.byType(ZoomableImage), findsNothing);
    },
  );

  testWidgets('shared viewer title reports generic file size', (tester) async {
    final file = await tester.runAsync(() async {
      final image = await imageFile();
      return File('${image.parent.path}/notes.txt')
          .writeAsBytes(List.filled(1536, 65));
    });
    await tester.pumpWidget(
      app(
        ViewerTitle(
          item: MediaItem(kind: MediaKind.text, path: file!.path),
        ),
      ),
    );
    await waitForFileMetadata(tester, find.text('1.5 KB'));
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Opener implements PlatformUrlOpener {
  final opened = <Uri>[];
  final keepAliveRequests = <bool>[];
  @override
  Future<bool> open(Uri url, {bool keepAlive = false}) async {
    opened.add(url);
    keepAliveRequests.add(keepAlive);
    return true;
  }
}
