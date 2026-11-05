// Stage B of the click benchmark (qa/click_bench/README.md): replays the
// click_screen calls gpt-realtime-2.1 made in stage A through the app's own
// planClick + ClickLocator + LinuxScreenCapture + xdotool on a nested X
// display, and reads where the click really landed from the page's log.
//
//   DISPLAY=:11 WOI_CLICK_BENCH=1 WOI_CLICK_DIR=<results/web> WOI_CLICK_ROWS=<stage A rows.json> \
//     WOI_CLICK_MODE=chain|element|vision|xy|oracle flutter test --tags live test/live/click_bench_live_test.dart
//
// oracle: x/y = the exact target centre in image pixels (checks the app's
// coordinate mapping end to end, no model involved).
@Tags(['live'])
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/usage/model_guard.dart';
import 'package:woi/core/vision/click_locator.dart';
import 'package:woi/platform/linux/atspi_elements.dart';
import 'package:woi/platform/linux/linux_input_control.dart';
import 'package:woi/platform/linux/linux_screen_capture.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/tools/builtin_tools.dart';

void main() {
  final env = Platform.environment;
  final on = env['WOI_CLICK_BENCH'] == '1';
  test('replays click_screen calls on the bench display', () async {
    final dir = env['WOI_CLICK_DIR']!;
    final mode = env['WOI_CLICK_MODE'] ?? 'chain';
    final layout = jsonDecode(File('$dir/web_layout.json').readAsStringSync()) as Map;
    final targets = {for (final t in layout['targets'] as List) (t as Map)['id']: t};
    final rows = mode == 'oracle'
        ? [for (final t in targets.values) {'id': t['id'], 'args': <String, Object?>{}}]
        : (jsonDecode(File(env['WOI_CLICK_ROWS']!).readAsStringSync()) as List).cast<Map>();
    final screen = LinuxScreenCapture();
    final input = LinuxInputControl();
    // Read-only: a refresh would fail here instead of rewriting auth.json.
    final auth = CodexAuthManager(refreshUrl: Uri.parse('http://127.0.0.1:9/no-refresh'));
    final client = ResponsesClient(credentials: auth.credentials, reuseConnections: true);
    final vision = VisionLocator(client: client, screen: screen, model: () => kCheapModel);
    final elements = ElementLocator(AtspiElementSource());
    final ClickLocator? locator = switch (mode) {
      'chain' => ChainLocator([elements, vision]),
      'element' => elements,
      'vision' => vision,
      _ => null,
    };
    // The geometry stage A's model saw (the app's 1280-wide capture).
    final probe = await screen.capture(scale: 1, jpegQuality: null, maxWidth: 1280);
    final shot = Screenshot(
      png: probe.png,
      width: probe.width,
      height: probe.height,
      originalWidth: probe.originalWidth,
      originalHeight: probe.originalHeight,
    );
    print('screen ${shot.originalWidth}x${shot.originalHeight}, image ${shot.width}x${shot.height}');
    final log = File('$dir/web_clicks.log');
    final out = <Map<String, Object?>>[];
    for (final r in rows) {
      final t = targets[r['id']] as Map;
      final args = ((r['args'] as Map?) ?? const {}).cast<String, Object?>();
      int? x = (args['x'] as num?)?.round(), y = (args['y'] as num?)?.round();
      var target = '${args['target'] ?? ''}';
      if (mode == 'oracle') {
        final c = shot.fromScreen((t['x'] as int) + (t['w'] as int) / 2, (t['y'] as int) + (t['h'] as int) / 2)!;
        (x, y, target) = (c.x, c.y, '');
      }
      final before = log.existsSync() ? log.readAsLinesSync().length : 0;
      final sw = Stopwatch()..start();
      Map<String, Object?> row;
      try {
        final plan = await planClick(target: target, x: x, y: y, shot: shot, locator: locator);
        final planMs = sw.elapsedMilliseconds;
        await input.click(plan.point.x, plan.point.y);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final lines = log.readAsLinesSync();
        final got = lines.length > before ? jsonDecode(lines.last) as Map : null;
        final ax = got?['sx'] as num?, ay = got?['sy'] as num?;
        final tx = t['x'] as int, ty = t['y'] as int, tw = t['w'] as int, th = t['h'] as int;
        final hit = ax != null && ax >= tx && ax <= tx + tw && ay! >= ty && ay <= ty + th;
        final err = ax == null ? null : sqrt(pow(ax - (tx + tw / 2), 2) + pow(ay! - (ty + th / 2), 2));
        row = {
          'id': t['id'],
          'target': target,
          'args': args,
          'planned': [plan.point.x, plan.point.y],
          'sx': ax,
          'sy': ay,
          'page_hit': got?['hit'],
          'hit': hit,
          'err': err,
          'small': min(tw, th) <= 24,
          'locate_ms': planMs,
          'lat_stage_a': r['lat'],
          ...plan.info,
        };
      } catch (e) {
        row = {'id': t['id'], 'target': target, 'args': args, 'hit': false, 'err': null, 'error': '$e', 'locate_ms': sw.elapsedMilliseconds};
      }
      out.add(row);
      print(
        '${'${row['id']}'.padRight(14)} ${row['hit'] == true ? 'HIT ' : 'miss'} '
        'by=${row['located_by'] ?? (row['error'] != null ? 'ERR' : 'xy')} ms=${row['locate_ms']} '
        'planned=${row['planned']} got=${row['sx']},${row['sy']} "$target" ${row['locate_error'] ?? row['error'] ?? ''}',
      );
      // Close whatever the click opened (dropdowns) before the next one.
      await Process.run('xdotool', ['key', 'Escape']);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    client.close();
    final tag = mode == 'oracle' ? 'oracle' : '${env['WOI_CLICK_TAG'] ?? 'run'}_$mode';
    File('$dir/stageb_$tag.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    final hits = out.where((r) => r['hit'] == true).length;
    print('$tag: $hits/${out.length} hits');
  }, skip: on ? false : 'set WOI_CLICK_BENCH=1', timeout: const Timeout(Duration(minutes: 30)));
}
