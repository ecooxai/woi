// Dumps the AT-SPI elements of the frontmost window (WOI_ATSPI_LIVE=1;
// DISPLAY selects the X display, e.g. :11 for the click bench).
@Tags(['live'])
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/atspi_elements.dart';

void main() {
  final on = Platform.environment['WOI_ATSPI_LIVE'] == '1';
  test('lists AT-SPI elements of the front window', () async {
    final pids = await frontWindowPids();
    print('front pids: $pids');
    final src = AtspiElementSource();
    final sw = Stopwatch()..start();
    final els = await src.elements();
    print('${els.length} elements in ${sw.elapsedMilliseconds} ms');
    sw.reset();
    await src.elements();
    print('again in ${sw.elapsedMilliseconds} ms');
    for (final e in els) {
      print('  $e');
    }
    await src.close();
    expect(els, isNotEmpty);
  }, skip: on ? false : 'set WOI_ATSPI_LIVE=1');
}
