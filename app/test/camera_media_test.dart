import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/media/media_context.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/camera.dart';
import 'package:woi/platform/linux/linux_camera.dart';
import 'package:woi/platform/media_grab.dart';
import 'package:woi/platform/media_viewer.dart';
import 'package:woi/tools/media_tools.dart';
import 'package:woi/tools/tool_registry.dart';
import 'package:woi/ui/widgets/camera_preview.dart';

import 'fakes/fakes.dart';
import 'fakes/live_fakes.dart';

/// 64x36 baseline JPEG (ffmpeg testsrc), decodable by the engine.
final realJpeg = base64Decode('/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMgD/2wBDAAgQEBMQExYWFhYWFhoYGhsbGxoaGhobGxsdHR0iIiIdHR0bGx0dICAiIiUmJSMjIiMmJigoKDAwLi44ODpFRVP/xACkAAACAwEBAQAAAAAAAAAAAAAHAAgFBgQDAgEAAwEBAQEAAAAAAAAAAAAAAAcGCAMFBBAAAQMCBAIHAg8BAAAAAAAAAQIAAxEhEgQFMXFBUUITsoKR0sGz0QahsZJ0FBVSgWE1czQzMhEAAQMCAwQFCgILAQAAAAAAAQIAAxEEIRIFMYEG0iITQVHTMiNCkpFhs7FxFDWyodHB8INyNDN0UoIW/8AAEQgAJABAAwESAAISAAMSAP/aAAwDAQACEQMRAD8Aj+1jGMZ70zK4j2yhYWQCDv8Ai6LbDe/B7CKMRRpQOqANqV6TT9Td8tPt8x61QwGCQR2/7d2HZ7/o6mNAjQlA9EAbKV9+/a/r4v1gxJ+whUQpYCp1JUMEGvmjSqgVYKV5PRoMQotEXt0q9uprhVayyKXQqKikE9FGY0qEiiRgMBsY9a7Bj2sxjNrq2NAMcxWvADHUsYza6tjQDHQabmsCuxUbK/5uKJPR4vn5XeWBIIINCLgjk2dp9xlV1Sjgrye4Hu3/AD+rmwSDUYEdrf3F2jieL76FIEkQ88Ak5pEYAKwqKxjaSPI2qokBuhaEyJUlSQpKgUqSoAhQOBBBwII2hyxdflJ/tWWgnw4e2ijkw1rhxpCqVoK0rvQOrY0IxwQZPyui5aemJcw4FPtQWOSlv5Y9gRvB5mO6n0yGLYqTeU8rMj7kwJTGm6jQUqTUmnM23bYaYTxBdponJCaACpC6n3nzm15FbdvdGtuskkGdGdSlZE5AhNTXKkZMEjYB2Bid6aTJRpNivzHwPSDSUfEl4o4x2/qr8R6NaJn4nvYjhHb70yeKwaysnQssevN9JHoemGqbfXbmalUQ7kr5y/mcEdUnHox+xXMze8HmtUngrhTGeIV7FB5Wb8i4WspNslzuVH4TczXEGsXEu1MW4K53Xsf/AHrPjIwxeSvU1c39/wCVsctesufWj8Jw7vbfS4JdqpNxTyvlfRGgKF2qm05NDtkjBc3rI5Hq1+HBcrlGITur+tyL0n9uyX1WD3SWMx8YMzEkJRFlkpSAlKQhYAAsAAJKAAbBzD7XCRDWn6f3DTjZQ0a3PpS+1PI42NfFjWrGbNNkUnMBI2WCCOAJB42+Uvx0/wDtR+LuF+dp6ymcJGxQIO4V9r5WP9Qj/r8pdfxdbRzaWuVQ6cCkKQcK9NaUKSSQTlIVUgEVKU9z9Din8Guv4Px439tbqY6tjGbXVsaAY5iteAGOpYxm11bGgGOv0mNOBa+sVYfyABtzvW/AP20r/BX8h7qW2tNQMi19pVl3AA/tx3Prpv8AZV/Ofkltvja5kNzb21aRpi62gritSlJqoVocoT0cKjMrHF+fxr+Iw/4qPiys5tfysdAx/wD/2Q==');

class _Viewer extends MediaViewer {
  ViewerState? current;
  @override
  Future<ViewerSurface> show(MediaItem item) async => ViewerSurface.overlay;
  @override
  Future<ViewerState?> state() async => current;
}

class _Grabber implements MediaGrabber {
  final frames = <(String, Duration, int)>[];
  final clips = <(String, Duration, Duration)>[];
  Duration? dur;
  @override
  Future<Uint8List> videoFrame(String path, Duration at, {int maxWidth = 1280}) async {
    frames.add((path, at, maxWidth));
    return fakeJpeg(1280, 720);
  }

  @override
  Future<Uint8List> audioPcm(String path, {Duration start = Duration.zero, required Duration length, int sampleRate = 24000}) async {
    clips.add((path, start, length));
    return Uint8List(length.inMilliseconds * 48);
  }

  @override
  Future<Duration?> duration(String path) async => dur;
}

void main() {
  group('jpeg', () {
    test('jpegSize reads the SOF marker', () {
      expect(jpegSize(fakeJpeg(640, 480)), (640, 480));
      expect(jpegSize(realJpeg), (64, 36));
      expect(jpegSize(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });

    test('splitter: frames across arbitrary chunk boundaries, stuffed bytes, garbage', () {
      final frames = [
        fakeJpeg(1280, 720, payload: [9, 0xFF, 0x00, 7, 0xFF, 0xD3, 5]),
        realJpeg,
        fakeJpeg(320, 240),
      ];
      final stream = <int>[0x00, 0x13, 0xFF, ...frames.expand((f) => f)];
      final rnd = Random(7);
      for (var trial = 0; trial < 20; trial++) {
        final sp = JpegStreamSplitter();
        final out = <Uint8List>[];
        var i = 0;
        while (i < stream.length) {
          final n = min(1 + rnd.nextInt(40), stream.length - i);
          out.addAll(sp.add(stream.sublist(i, i + n)));
          i += n;
        }
        expect(out.length, 3, reason: 'trial $trial');
        for (var k = 0; k < 3; k++) {
          expect(out[k], frames[k]);
        }
      }
    });

    test('splitter resyncs after a corrupt frame header', () {
      final sp = JpegStreamSplitter();
      final out = sp.add([0xFF, 0xD8, 0x12, 0x34, 0x56, ...fakeJpeg(8, 8)]);
      expect(out.map(jpegSize), [(8, 8)]);
    });

    test('linux camera copies MJPEG (no decode) and thins it to <= 8 fps by time', () {
      final c = LinuxCameraService(device: '/dev/videoX');
      final a = c.mjpegArgs();
      expect(a, containsAllInOrder(['-input_format', 'mjpeg', '-c:v', 'copy']));
      // Time-based thinning (8 fps → keep when pts reaches the deadline, next
      // deadline 0.1125 s later), so a camera that slows down in the dark
      // still gives every frame it has instead of every 5th.
      expect(a, contains(r'noise=drop=if(gte(pts*tb\,ld(0))\,st(0\,pts*tb+0.1125)*0\,1),mjpeg2jpeg'));
      expect(a.join(' '), isNot(contains('mod(n')));
      expect(a.join(' '), contains('1280x720'));
      expect(c.yuyvArgs(), contains('fps=8'));
    });

    test('linux camera: open on a missing device fails cleanly and stays off', () async {
      final c = LinuxCameraService(device: '/dev/nonexistent-video');
      await expectLater(c.open(), throwsA(isA<CameraException>()));
      expect(c.active.value, isFalse);
      expect(c.lastError, contains('/dev/nonexistent-video'));
      await c.close();
    });

    test('latest() drops stale frames; nextFrame waits for one', () async {
      final cam = FakeCamera();
      expect(cam.latest(), isNull);
      await cam.open();
      expect(cam.latest(), isNotNull);
      cam.push(at: DateTime.now().subtract(const Duration(seconds: 10)));
      expect(cam.latest(), isNull);
      Timer(const Duration(milliseconds: 60), () => cam.push());
      expect(await cam.nextFrame(timeout: const Duration(seconds: 1)), isNotNull);
      await cam.close();
      expect(cam.latest(), isNull);
    });
  });

  group('intent', () {
    test('cameraCommand', () {
      for (final t in ['open camera', 'Open the camera.', 'turn on the webcam', 'please start camera', 'turn the camera on']) {
        expect(cameraCommand(t), isTrue, reason: t);
      }
      for (final t in ['close camera', 'Turn off the camera!', 'stop the webcam', 'camera off', 'turn camera off']) {
        expect(cameraCommand(t), t == 'camera off' ? isNull : isFalse, reason: t);
      }
      expect(cameraCommand('open the camera app settings and change resolution'), isNull);
      expect(cameraCommand('what do you see'), isNull);
    });

    test('isMediaQuestion', () {
      for (final t in [
        "what's in this image",
        'What is this song?',
        'what are they saying',
        "what's happening now?",
        'describe the video',
        'who is singing',
        'summarize this recording',
      ]) {
        expect(isMediaQuestion(t), isTrue, reason: t);
      }
      for (final t in ['open the image folder', 'play the video', 'click the button', 'what time is it', 'show me cat.png']) {
        expect(isMediaQuestion(t), isFalse, reason: t);
      }
    });
  });

  test('isScreenQuestion', () {
    for (final t in [
      'What is on my screen?',
      "what's on the screen",
      'what do you see',
      'What am I looking at?',
      'describe my screen',
      'what app is this?',
      'what app am I in',
      'what is in the screenshot',
    ]) {
      expect(isScreenQuestion(t), isTrue, reason: t);
    }
    for (final t in ['tell me a joke', 'take a screenshot', 'what time is it', 'turn the screen brightness up', 'tell me more about that']) {
      expect(isScreenQuestion(t), isFalse, reason: t);
    }
  });

  group('media context grab (fake viewer)', () {
    late Directory dir;
    late _Viewer viewer;
    late _Grabber grabber;
    late MediaContextService svc;
    final asked = <(int, String?, String?)>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('woi_media_');
      viewer = _Viewer();
      grabber = _Grabber();
      asked.clear();
      svc = MediaContextService(
        viewer: viewer,
        grabber: grabber,
        describeAudio: (pcm, {title, question}) async {
          asked.add((pcm.length, title, question));
          return 'Transcript: hello world. Audio: a man speaking.';
        },
      );
    });
    tearDown(() => dir.delete(recursive: true));

    test('nothing open -> null', () async {
      expect(await svc.grab(), isNull);
    });

    test('image: small files are attached as they are', () async {
      final f = File('${dir.path}/cat.jpg')..writeAsBytesSync(realJpeg);
      viewer.current = ViewerState(item: MediaItem(kind: MediaKind.image, path: f.path));
      final ctx = (await svc.grab())!;
      expect(ctx.image!.bytes, realJpeg);
      expect((ctx.image!.width, ctx.image!.height), (64, 36));
      expect(ctx.image!.kind, ContextImageKind.media);
      expect(ctx.image!.note, contains('cat.jpg'));
      expect(grabber.frames, isEmpty);
      expect(ctx.toToolResult()['image'], contains('64x36'));
    });

    test('video: the frame at the playing position, with the timestamp', () async {
      viewer.current = const ViewerState(
        item: MediaItem(kind: MediaKind.video, path: '/v/clip.mp4'),
        position: Duration(seconds: 42, milliseconds: 300),
        duration: Duration(minutes: 2),
        playing: true,
      );
      final ctx = (await svc.grab())!;
      expect(grabber.frames.single, ('/v/clip.mp4', const Duration(seconds: 42, milliseconds: 300), 1280));
      expect(ctx.image!.note, contains('at 0:42 of 2:00 (playing)'));
      expect((ctx.image!.width, ctx.image!.height), (1280, 720));
      final r = ctx.toToolResult();
      expect(r['position'], '0:42');
      expect(r['playing'], isTrue);
    });

    test('audio: short clips whole, long ones around the position, described', () async {
      viewer.current = const ViewerState(
        item: MediaItem(kind: MediaKind.audio, path: '/a/hello.wav'),
        position: Duration(seconds: 1),
        duration: Duration(seconds: 3),
      );
      var ctx = (await svc.grab(question: 'what is he saying'))!;
      expect(grabber.clips.single, ('/a/hello.wav', Duration.zero, const Duration(seconds: 3)));
      expect(asked.single, (3000 * 48, 'hello.wav', 'what is he saying'));
      expect(ctx.text, contains('hello world'));
      expect(ctx.image, isNull);

      viewer.current = const ViewerState(
        item: MediaItem(kind: MediaKind.audio, path: '/a/talk.mp3'),
        position: Duration(minutes: 10),
        duration: Duration(hours: 1),
      );
      ctx = (await svc.grab())!;
      expect(grabber.clips.last, ('/a/talk.mp3', const Duration(minutes: 9, seconds: 40), const Duration(seconds: 30)));
      expect(ctx.summary, contains('9:40–10:10 of 1:00:00'));
    });

    test('text: an excerpt', () async {
      viewer.current = const ViewerState(item: MediaItem(kind: MediaKind.text, text: 'hello notes'));
      expect((await svc.grab())!.text, 'hello notes');
    });
  });

  group('delegation', () {
    const tools = [
      ToolSpec(name: 'take_screenshot', description: 'shot', parameters: {'type': 'object'}),
      ToolSpec(name: 'click_screen', description: 'click', parameters: {'type': 'object'}),
      ToolSpec(name: 'camera', description: 'cam', parameters: {'type': 'object'}),
      ToolSpec(name: 'inspect_media', description: 'media', parameters: {'type': 'object'}),
    ];

    test('"open camera" runs the camera tool without a model call', () async {
      final runs = <(String, String)>[];
      final m = FakeDelegationModel([]);
      final rep = await DelegationExecutor(
        model: m,
        tools: tools,
        runTool: (id, name, args) async {
          runs.add((name, args));
          return '{"ok":true,"on":true}';
        },
      ).execute('Open the camera');
      expect(runs.single, ('camera', '{"action":"open"}'));
      expect(m.requests, isEmpty);
      expect(rep.model, 'fast-path');
      expect(rep.ok, isTrue);
    });

    test('a media question inspects the media first and sends its image (JPEG) to the model', () async {
      final images = <DelegationImage>[];
      final runs = <String>[];
      final m = FakeDelegationModel([const DelegationModelTurn(text: 'A cat on a sofa.', calls: [])]);
      final rep = await DelegationExecutor(
        model: m,
        tools: tools,
        latestScreenshot: () => null,
        contextImages: () => images,
        runTool: (id, name, args) async {
          runs.add(name);
          if (name == 'inspect_media') {
            images.add(DelegationImage(png: fakeJpeg(800, 600), capturedAt: DateTime.now(), note: 'Image cat.jpg'));
            return '{"ok":true,"kind":"image","summary":"Image cat.jpg attached."}';
          }
          return '{"ok":true}';
        },
      ).execute("what's in this image?");
      expect(runs.first, 'inspect_media');
      expect(runs, isNot(contains('click_screen')));
      final req = m.requests.single;
      expect(req.tools.map((t) => t['name']), isNot(contains('inspect_media')));
      final content = (req.input.single['content'] as List).cast<Map>();
      final urls = content.where((c) => c['type'] == 'input_image').map((c) => '${c['image_url']}').toList();
      expect(urls, hasLength(1), reason: 'the media image, no screenshot wait for a media question');
      expect(urls.single, startsWith('data:image/jpeg;base64,'));
      expect(content.map((c) => c['text']).join(' '), contains('inspect_media result'));
      expect(rep.resultText, contains('A cat on a sofa.'));
    });

    test('fresh camera frames go with every request; stale ones do not', () async {
      var frames = [DelegationImage(png: fakeJpeg(1280, 720), capturedAt: DateTime.now(), note: 'Live camera frame')];
      final m = FakeDelegationModel([
        const DelegationModelTurn(text: 'You are holding a mug.', calls: []),
        const DelegationModelTurn(text: 'ok', calls: []),
      ]);
      final ex = DelegationExecutor(
        model: m,
        tools: tools,
        contextImages: () => frames,
        runTool: (id, name, args) async => '{"ok":true}',
      );
      await ex.execute('what am I holding?');
      var content = (m.requests.last.input.single['content'] as List).cast<Map>();
      expect(content.where((c) => c['type'] == 'input_image'), hasLength(1));
      expect(content.map((c) => c['text']).join(' '), contains('Live camera frame'));

      frames = [DelegationImage(png: fakeJpeg(1280, 720), capturedAt: DateTime.now().subtract(const Duration(minutes: 2)))];
      await ex.execute('anything else?');
      content = (m.requests.last.input.single['content'] as List).cast<Map>();
      expect(content.where((c) => c['type'] == 'input_image'), isEmpty);
    });
  });

  group('tools', () {
    test('camera and inspect_media call the host', () async {
      var on = false;
      final questions = <String?>[];
      final reg = ToolRegistry()
        ..registerAll(
          mediaTools(
            MediaToolsHost(
              setCamera: (v) async {
                on = v;
                return {'ok': true, 'on': v};
              },
              cameraOn: () => on,
              inspectMedia: (q) async {
                questions.add(q);
                return {'ok': false, 'error': 'nothing is open in the viewer'};
              },
            ),
          ),
        );
      expect(reg.specs.map((s) => s.name), ['camera', 'inspect_media']);
      final t = reg.specs.firstWhere((s) => s.name == 'camera');
      expect(jsonEncode(t.parameters), contains('"open","close","status"'));
      expect(jsonDecode((await reg.dispatch('camera', '{"action":"open"}')).json)['on'], isTrue);
      expect(on, isTrue);
      expect(jsonDecode((await reg.dispatch('camera', '{"action":"status"}')).json)['on'], isTrue);
      await reg.dispatch('inspect_media', '{}');
      await reg.dispatch('inspect_media', '{"question":"who is it"}');
      expect(questions, [null, 'who is it']);
    });
  });

  group('preview tile (perf)', () {
    testWidgets('decodes at 320 px, drops frames while decoding, frees on close', (tester) async {
      final cam = FakeCamera();
      await cam.open();
      await tester.runAsync(() async {
        cam.pushJpeg(realJpeg);
        await tester.pumpWidget(MaterialApp(home: Center(child: CameraPreviewTile(camera: cam, decodeWidth: 32))));
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          if (tester.any(find.byType(RawImage))) break;
        }
      });
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image!.width, 32, reason: 'decoded at the target width, not 64');
      await tester.runAsync(() async {
        await cam.close();
        await tester.pump();
      });
      expect(find.byType(RawImage), findsNothing);
    });
  });
}

