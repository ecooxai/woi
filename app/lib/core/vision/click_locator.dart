import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../platform/screen_capture.dart';
import '../responses/responses_client.dart';
import 'ui_elements.dart';

/// Where a click target was found.
enum LocateMethod {
  /// Matched by name in the accessibility tree (exact bounds, no model call).
  element,

  /// Found by a vision model in a full-resolution screenshot.
  vision,
}

/// A located click target in real screen pixels.
class LocatedTarget {
  const LocatedTarget(this.point, {required this.method, required this.elapsed, this.label, this.bounds});

  final Point<int> point;
  final LocateMethod method;
  final Duration elapsed;

  /// Element role and name ([LocateMethod.element]).
  final String? label;
  final Rectangle<int>? bounds;

  Map<String, Object?> toJson() => {
    'located_by': method.name,
    'locate_ms': elapsed.inMilliseconds,
    'label': ?label,
  };
}

/// Not found (or the locator failed); [reason] goes back to the model.
class LocateFailure implements Exception {
  LocateFailure(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// Finds the screen position of a described UI element ("the blue Save
/// button under the Email field"). [hint] is the voice model's own guess in
/// screen pixels: it only breaks ties (the realtime models see screenshots at
/// a fixed ~512 px short side and miss targets by ~60 px, see
/// research/REALTIME_API.md "Click accuracy").
abstract class ClickLocator {
  Future<LocatedTarget> locate(String target, {Point<int>? hint});
}

/// Tries [locators] in order; the first success wins. Failures are collected.
class ChainLocator implements ClickLocator {
  ChainLocator(this.locators);
  final List<ClickLocator> locators;

  @override
  Future<LocatedTarget> locate(String target, {Point<int>? hint}) async {
    final reasons = <String>[];
    for (final l in locators) {
      try {
        return await l.locate(target, hint: hint);
      } on LocateFailure catch (e) {
        reasons.add(e.reason);
      } catch (e) {
        reasons.add('$e');
      }
    }
    throw LocateFailure(reasons.isEmpty ? 'no locator' : reasons.join('; '));
  }
}

/// Matches the target description against the accessibility tree
/// ([ElementSource]); only a confident, unambiguous match counts (else the
/// next locator, usually [VisionLocator], decides).
class ElementLocator implements ClickLocator {
  ElementLocator(this.source, {this.timeout = const Duration(milliseconds: 1500)});
  final ElementSource source;
  final Duration timeout;

  @override
  Future<LocatedTarget> locate(String target, {Point<int>? hint}) async {
    final sw = Stopwatch()..start();
    final List<UiElement> els;
    try {
      els = await source.elements().timeout(timeout);
    } on TimeoutException {
      throw LocateFailure('accessibility tree timed out');
    }
    final m = matchElement(target, els, hint: hint);
    if (m == null) throw LocateFailure('no unique accessibility match for "$target" among ${els.length} elements');
    return LocatedTarget(
      m.center,
      method: LocateMethod.element,
      elapsed: sw.elapsed,
      label: m.describe(),
      bounds: m.bounds,
    );
  }
}

/// System prompt of the vision locator.
const kLocateInstructions = '''
You locate UI elements in a screenshot for a click tool. The user gives the image size and describes the element to
click. Reply with JSON only, no prose: {"x": <int>, "y": <int>} = the pixel at the centre of that element (a text
field: its input box; a checkbox or radio: the box itself), in this image's pixel coordinates (origin top-left);
or {"error": "<short reason>"} if no such element is visible. If several elements match, take the one nearest the
hint point when one is given.''';

/// Parses the locator reply: `{"x":..,"y":..}` (possibly inside prose or a
/// code fence) or `{"error":..}`.
({int x, int y})? parseLocateReply(String text, {void Function(String error)? onError}) {
  final m = RegExp(r'\{[^{}]*\}').firstMatch(text);
  if (m == null) return null;
  try {
    final j = jsonDecode(m[0]!);
    if (j is! Map) return null;
    final x = j['x'], y = j['y'];
    if (x is num && y is num) return (x: x.round(), y: y.round());
    final err = j['error'];
    if (err != null) onError?.call('$err');
  } catch (_) {}
  return null;
}

/// Asks a Responses vision model (gpt-6-luna) where the element is, in a
/// fresh screenshot at up to [maxWidth] px (sent as is: the model then sees
/// small targets that the realtime model's downscaled view loses).
class VisionLocator implements ClickLocator {
  VisionLocator({
    required this.client,
    required this.screen,
    required this.model,
    this.maxWidth = 1920,
    this.timeout = const Duration(seconds: 10),
    this.reasoning = 'low',
  });

  final ResponsesClient client;
  final ScreenCapture screen;
  final String Function() model;
  final int maxWidth;
  final Duration timeout;

  /// Reasoning effort ('low' measured best: same accuracy, fewer stalls).
  final String? reasoning;

  /// Last request (diagnostics).
  Duration? lastCapture, lastModel;

  @override
  Future<LocatedTarget> locate(String target, {Point<int>? hint}) async {
    final sw = Stopwatch()..start();
    // Full resolution, lossless: small targets survive (not the chat setting).
    final shot = await screen.capture(scale: 1, jpegQuality: null, maxWidth: maxWidth);
    lastCapture = sw.elapsed;
    final h = hint == null ? null : shot.fromScreen(hint.x, hint.y);
    final prompt = StringBuffer('Image size: ${shot.width}x${shot.height} pixels. Target: $target');
    if (h != null) prompt.write('\nHint: the requester guessed about (${h.x}, ${h.y}); it may be off by 100 px or more.');
    final ResponsesResult r;
    try {
      r = await client
          .create(
            model: model(),
            instructions: kLocateInstructions,
            input: [
              userMessage([inputImage(shot.png), inputText(prompt.toString())]),
            ],
            reasoning: reasoning == null ? null : {'effort': reasoning},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw LocateFailure('vision locator timed out after ${timeout.inSeconds}s');
    } on ResponsesException catch (e) {
      throw LocateFailure('vision locator failed: ${e.message}');
    }
    lastModel = sw.elapsed - lastCapture!;
    String? why;
    final p = parseLocateReply(r.text, onError: (e) => why = e);
    if (p == null) throw LocateFailure(why == null ? 'vision locator gave no position' : 'not found: $why');
    if (p.x < 0 || p.y < 0 || p.x >= shot.width || p.y >= shot.height) {
      throw LocateFailure('vision locator answered outside the image (${p.x}, ${p.y})');
    }
    debugPrint('locate "$target": (${p.x},${p.y}) in ${shot.width}x${shot.height}, ${sw.elapsedMilliseconds} ms');
    return LocatedTarget(shot.toScreen(p.x, p.y), method: LocateMethod.vision, elapsed: sw.elapsed);
  }
}
