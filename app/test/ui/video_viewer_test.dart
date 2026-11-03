import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:woi/ui/viewer/video_viewer.dart';

/// In-memory controller: no platform player, just the value transitions.
class _FakeController extends VideoPlayerController {
  _FakeController({this.fail = false}) : super.file(File('/tmp/x.mp4'));
  final bool fail;
  final seeks = <Duration>[];

  @override
  Future<void> initialize() async {
    if (fail) throw Exception('unsupported codec');
    value = value.copyWith(
      isInitialized: true,
      duration: const Duration(seconds: 80),
      size: const Size(1280, 720),
      volume: 1,
    );
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);
  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);
  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    value = value.copyWith(position: position);
  }

  @override
  Future<void> setVolume(double volume) async => value = value.copyWith(volume: volume);
}

Future<(VideoViewerBodyState, _FakeController)> _pumpViewer(WidgetTester t, {bool autoplay = true}) async {
  late _FakeController c;
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 600,
          child: VideoViewerBody(
            path: '/tmp/demo.mp4',
            autoplay: autoplay,
            controllerFactory: (_) => c = _FakeController(),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return (t.state<VideoViewerBodyState>(find.byType(VideoViewerBody)), c);
}

Future<void> _teardown(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 3));
  viewerFullscreen.value = false;
}

void main() {
  testWidgets('autoplays with controls, time label and a full-width seek bar', (t) async {
    final (s, c) = await _pumpViewer(t);
    expect(c.value.isPlaying, isTrue);
    expect(find.byKey(const ValueKey('video-play')), findsOneWidget);
    expect(find.text('0:00 / 1:20'), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('video-seek'))).width, greaterThan(700), reason: 'was 0 before the fix');
    expect(VideoViewerBodyState.fmt(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    await _teardown(t);
  });

  testWidgets('keys: space, arrows, m, f / esc', (t) async {
    final (s, c) = await _pumpViewer(t);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    expect(c.value.isPlaying, isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    expect(c.value.isPlaying, isTrue);

    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(c.value.position, const Duration(seconds: 5));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(c.value.position, Duration.zero, reason: 'clamped at the start');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(c.value.volume, closeTo(0.9, 1e-9));
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(c.value.volume, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(c.value.volume, closeTo(0.9, 1e-9));

    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(viewerFullscreen.value, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(viewerFullscreen.value, isFalse);
    await _teardown(t);
  });

  testWidgets('tapping the seek bar seeks; controls auto-hide while playing', (t) async {
    final (s, c) = await _pumpViewer(t);
    final bar = find.byKey(const ValueKey('video-seek'));
    final r = t.getRect(bar);
    await t.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
    await t.pump();
    expect(c.seeks.last.inSeconds, inInclusiveRange(39, 41));

    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(milliseconds: 500));
    final op = t.widget<AnimatedOpacity>(
      find.ancestor(of: find.byKey(const ValueKey('video-play')), matching: find.byType(AnimatedOpacity)).first,
    );
    expect(op.opacity, 0);
    await _teardown(t);
  });

  testWidgets('initialize failure shows the error view', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: VideoViewerBody(path: '/tmp/bad.mkv', controllerFactory: (_) => _FakeController(fail: true)),
      ),
    );
    await t.pump();
    expect(find.text('Cannot play this video'), findsOneWidget);
    expect(find.textContaining('unsupported codec'), findsOneWidget);
    await _teardown(t);
  });
}
