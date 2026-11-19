import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/audio/wav.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/context/image_tiers.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/audio_io.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/audio_button.dart';
import 'package:woi/ui/widgets/context_document.dart';
import 'package:woi/ui/widgets/context_meter.dart';

class _Compressor implements Compressor {
  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async =>
      CompressionResult(summary: 'Summary', tokensAfter: 1);
}

class _Playback implements ClipPlayback {
  final completed = Completer<void>();
  bool stopped = false;
  @override
  Future<void> get done => completed.future;
  @override
  Future<void> stop() async {
    stopped = true;
    if (!completed.isCompleted) completed.complete();
  }
}

class _Audio implements AudioIO {
  final playback = _Playback();
  String? played;
  bool fail = false;
  @override
  Future<ClipPlayback> playFile(String path) async {
    if (fail) throw StateError('Recording unavailable');
    played = path;
    return playback;
  }

  @override
  String get description => 'Synthetic test audio';
  @override
  Future<MicStream> openMic() => throw UnimplementedError();
  @override
  Future<PcmPlayer> openPlayer() => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!const bool.fromEnvironment('WOI_CONTEXT_SCREENSHOTS')) return;
    for (final font in const {
      'Inter': 'assets/fonts/Inter-Variable.ttf',
      'JetBrainsMono': 'assets/fonts/JetBrainsMono-Regular.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(font.key)..addFont(rootBundle.load(font.value));
      await loader.load();
    }
  });
  late ContextManager manager;
  late Conversation conversation;
  late _Audio audio;
  late Directory temporary;
  late String imagePath;
  late String audioPath;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('woi-context-document-');
    imagePath = '${temporary.path}/context.png';
    audioPath = '${temporary.path}/context.wav';
    // A visible synthetic checkerboard proves the image rendered; no private
    // conversation media or external asset is used for tests or screenshots.
    final fixture = img.Image(width: 240, height: 140);
    for (var y = 0; y < fixture.height; y++) {
      for (var x = 0; x < fixture.width; x++) {
        final colors = ((x ~/ 40) + (y ~/ 35)).isEven ? const [38, 130, 150] : const [245, 191, 105];
        fixture.setPixelRgb(x, y, colors[0], colors[1], colors[2]);
      }
    }
    await File(imagePath).writeAsBytes(img.encodePng(fixture));
    await writeWav(audioPath, Uint8List(4800));
    manager = ContextManager(compressor: _Compressor(), threshold: 100000);
    audio = _Audio();
    conversation = Conversation(title: 'A conversation with media', summary: 'Earlier context is retained here.');
    conversation.add(Message(id: 'old', kind: MessageKind.user, text: 'Compacted raw text', compacted: true));
    conversation.add(
      Message(
        id: 'media',
        kind: MessageKind.user,
        text: 'Complete message text\nSecond paragraph stays available.',
        image: ImageAttachment(path: imagePath, width: 240, height: 140, originalWidth: 240, originalHeight: 140),
        audio: AudioClip(path: audioPath, durationMs: 100),
      ),
    );
    conversation.add(
      Message(
        id: 'tool',
        kind: MessageKind.tool,
        tool: ToolCallInfo(
          callId: 'call',
          name: 'example_tool',
          argsJson: '{"query":"entire argument"}',
          resultJson: '{"result":"entire result"}',
          status: ToolStatus.success,
        ),
      ),
    );
    conversation.add(Message(id: 'notice', kind: MessageKind.system, text: 'UI-only notice'));
    manager.attach(conversation);
  });

  tearDown(() async {
    await audio.playback.stop();
    manager.dispose();
    await temporary.delete(recursive: true);
  });

  Widget host({VoidCallback? onCompact}) => RepaintBoundary(
    key: const ValueKey('context-document-capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildWoiTheme(),
      home: Scaffold(
        body: Center(
          child: ContextMeter(
            manager: manager,
            conversation: conversation,
            style: ContextMeterStyle.indicator,
            audio: audio,
            onCompact: onCompact,
            documentData: () => const ContextDocumentData(
              instructions: 'Full session instructions.',
              pinnedNote: 'Keep this pinned note.',
              tools: [
                ToolSpec(
                  name: 'example_tool',
                  description: 'Complete tool definition.',
                  parameters: {'type': 'object'},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Finder text(String value) => find.byWidgetPredicate((widget) => widget is SelectableText && widget.data == value);
  Finder section(String key) => find.byKey(ValueKey('context-section-$key'));
  Finder documentScrollable() => find
      .descendant(of: find.byKey(const ValueKey('context-document-scroll')), matching: find.byType(Scrollable))
      .first;

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(ContextMeter));
    await tester.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester tester, String key) async {
    final heading = find.descendant(of: section(key), matching: find.byKey(const ValueKey('context-section-heading')));
    await tester.scrollUntilVisible(heading, 180, scrollable: documentScrollable());
    await tester.ensureVisible(heading);
    await tester.pumpAndSettle();
    expect(heading.hitTestable(), findsOneWidget);
    await tester.tap(heading);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('WOI_CONTEXT_SCREENSHOTS')) return;
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('context-document-capture')));
    await tester.runAsync(() async {
      final raster = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/qa/context-document');
        await dir.create(recursive: true);
        await File('${dir.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        raster.dispose();
      }
    });
  }

  Future<void> readyImage(WidgetTester tester) async {
    // File-image I/O and codec completion need real async turns in a widget
    // test. Pumping fake time alone can leave a perfectly sized, blank RawImage.
    expect(await tester.runAsync(() => File(imagePath).exists()), isTrue);
    final image = find.byKey(ValueKey('context-image-$imagePath'));
    final raw = find.descendant(of: image, matching: find.byType(RawImage));
    ui.Image? decoded;
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
      if (raw.evaluate().isNotEmpty) decoded = tester.widget<RawImage>(raw).image;
      if (decoded != null) break;
    }
    expect(
      decoded,
      isNotNull,
      reason: 'The visible context image must finish decoding, not just create an Image widget.',
    );
    final decodedImage = decoded!;
    expect(decodedImage.width, 240);
    expect(decodedImage.height, 140);
    final bytes = await tester.runAsync(() => decodedImage.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(bytes, isNotNull);
    // The fixture's two opaque colors prove actual file pixels were decoded.
    expect(bytes!.buffer.asUint8List(0, 4), orderedEquals(const [38, 130, 150, 255]));
    expect(bytes.buffer.asUint8List(50 * 4, 4), orderedEquals(const [245, 191, 105, 255]));
    final bounds = tester.getSize(raw);
    expect(bounds.width, greaterThan(0));
    expect(bounds.height, greaterThan(0));
  }

  testWidgets('document has a title and starts folded again on every opening', (tester) async {
    await tester.pumpWidget(host());
    await open(tester);
    expect(find.text('CONTEXT DOCUMENT'), findsOneWidget);
    expect(find.text(conversation.title), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(AudioClipButton), findsNothing);
    await toggle(tester, 'instructions');
    expect(text('Full session instructions.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close context'));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('summary note and tool results expose complete selectable content', (tester) async {
    await tester.pumpWidget(host());
    await open(tester);
    await toggle(tester, 'note');
    expect(text('Keep this pinned note.'), findsOneWidget);
    await toggle(tester, 'summary');
    expect(text(conversation.summary!), findsOneWidget);
    expect(text('Compacted raw text'), findsNothing);
    expect(find.textContaining('UI-only notice'), findsNothing);
    await toggle(tester, 'message-tool');
    expect(text('{"query":"entire argument"}'), findsOneWidget);
    expect(text('{"result":"entire result"}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanding a message reveals image and audio and collapsing stops playback', (tester) async {
    await tester.pumpWidget(host());
    await open(tester);
    expect(find.byType(Image), findsNothing);
    await toggle(tester, 'message-media');
    expect(text(conversation.messages[1].text), findsOneWidget);
    expect(find.byKey(ValueKey('context-image-$imagePath')), findsOneWidget);
    await readyImage(tester);
    expect(find.byType(AudioClipButton), findsOneWidget);
    await tester.ensureVisible(find.byType(AudioClipButton));
    await tester.pumpAndSettle();
    expect(find.byType(AudioClipButton).hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byType(AudioClipButton));
      for (var attempt = 0; attempt < 20 && audio.played == null; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(audio.played, audioPath);
    await toggle(tester, 'message-media');
    expect(find.byType(AudioClipButton), findsNothing);
    expect(audio.playback.stopped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing image and failed audio show recoverable feedback', (tester) async {
    await tester.runAsync(() => File(imagePath).delete());
    audio.fail = true;
    await tester.pumpWidget(host());
    await open(tester);
    await toggle(tester, 'message-media');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Image unavailable on this device.'), findsOneWidget);
    await tester.ensureVisible(find.byType(AudioClipButton));
    await tester.pumpAndSettle();
    expect(find.byType(AudioClipButton).hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byType(AudioClipButton));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Cannot play audio:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('described images clearly distinguish local originals from model context', (tester) async {
    manager.configure(accounting: ContextAccounting.textEstimate);
    conversation.messages[1].meta[ImageMeta.tier] = 'described';
    conversation.messages[1].meta[ImageMeta.description] = 'An exact recorded image description.';
    await tester.pumpWidget(host());
    await open(tester);
    await toggle(tester, 'message-media');
    await readyImage(tester);
    expect(find.text('Image retained locally · model context uses the description below'), findsOneWidget);
    expect(text('An exact recorded image description.'), findsOneWidget);
    expect(find.text('Recording · transcript is used in live voice context'), findsOneWidget);
  });

  for (final size in const [Size(320, 640), Size(400, 860), Size(1280, 720)]) {
    testWidgets('context document at $size keeps compact and close usable', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var compacted = 0;
      await tester.pumpWidget(host(onCompact: () => compacted++));
      await open(tester);
      await capture(tester, '${size.width.toInt()}-collapsed');
      expect(find.text('Compact now').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Compact now'));
      expect(compacted, 1);
      await toggle(tester, 'message-media');
      await readyImage(tester);
      await capture(tester, '${size.width.toInt()}-expanded-text-image');
      await tester.ensureVisible(find.byType(AudioClipButton));
      await tester.pumpAndSettle();
      await capture(tester, '${size.width.toInt()}-expanded-audio');
      await toggle(tester, 'message-media');
      await toggle(tester, 'usage');
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Close context').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Close context'));
      await tester.pumpAndSettle();
      expect(find.byType(ContextDocument), findsNothing);
    });
  }
}
