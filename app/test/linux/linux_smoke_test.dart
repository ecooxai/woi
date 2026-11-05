import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/exec_util.dart';
import 'package:woi/platform/linux/linux_input_control.dart';
import 'package:woi/platform/linux/linux_screen_capture.dart';
import 'package:woi/platform/linux/linux_shell.dart';
import 'package:woi/platform/screen_capture.dart';

/// Talks to the real X server / tools. Skipped off Linux or without a display.
void main() {
  final display = x11Display();
  final socket = '/tmp/.X11-unix/X${display.replaceAll(RegExp(r'^.*:'), '').split('.').first}';
  final String? skip = !Platform.isLinux
      ? 'not Linux'
      : FileSystemEntity.typeSync(socket) == FileSystemEntityType.notFound
      ? 'no X display at $display'
      : null;

  test('screenshot via ffmpeg x11grab: JPEG at the dp width by default, PNG when lossless', () async {
    final sw = Stopwatch()..start();
    final shot = await LinuxScreenCapture().capture();
    sw.stop();
    expect(shot.isJpeg, isTrue);
    expect((shot.width, shot.height), screenshotSize(shot.originalWidth, shot.originalHeight, kScreenshotScaleDp));
    expect(imageSize(shot.png), (shot.width, shot.height));
    final full = await LinuxScreenCapture().capture(scale: 1, jpegQuality: null, maxWidth: 1280);
    expect(full.isJpeg, isFalse);
    expect(full.width, lessThanOrEqualTo(1280));
    expect(pngSize(full.png), (full.width, full.height));
    // ignore: avoid_print
    print(
      'screenshot ${shot.width}x${shot.height} of ${shot.originalWidth}x${shot.originalHeight} '
      '(${shot.png.length ~/ 1024} KiB JPEG) in ${sw.elapsedMilliseconds} ms; '
      'lossless ${full.width}x${full.height} ${full.png.length ~/ 1024} KiB PNG',
    );
  }, skip: skip ?? (which('ffmpeg') == null && which('import') == null ? 'ffmpeg missing' : null));

  test('run_bash: echo hi', () async {
    final r = await LinuxShell().run('echo hi');
    expect(r.exitCode, 0);
    expect(r.stdout, 'hi\n');
    final t = await LinuxShell().run('sleep 5', timeout: const Duration(milliseconds: 300));
    expect(t.timedOut, isTrue);
    expect(t.elapsed.inSeconds, lessThan(3));
  }, skip: Platform.isLinux ? null : 'not Linux');

  test('xdotool mouse location', () async {
    final p = await LinuxInputControl().mouseLocation();
    expect(p.x, greaterThanOrEqualTo(0));
    expect(p.y, greaterThanOrEqualTo(0));
    // ignore: avoid_print
    print('mouse at ${p.x},${p.y}');
  }, skip: skip ?? (which('xdotool') == null ? 'xdotool missing' : null));
}
