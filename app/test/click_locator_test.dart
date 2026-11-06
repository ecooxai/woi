import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/vision/click_locator.dart';
import 'package:woi/core/vision/ui_elements.dart';
import 'package:woi/platform/linux/atspi_elements.dart';
import 'package:woi/platform/screen_capture.dart';
import 'package:woi/tools/builtin_tools.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

UiElement el(String role, String name, int x, int y, int w, int h) =>
    UiElement(role: role, name: name, bounds: Rectangle(x, y, w, h));

/// The AT-SPI tree Chromium reported for the click-bench page on :11
/// (qa/click_bench/web/page.html), trimmed.
final page = [
  el('entry', 'Address and search bar', 122, 11, 98, 24),
  el('button', 'Main menu', 10, 9, 26, 26),
  el('button', 'Back', 42, 9, 26, 26),
  el('entry', 'Search mail', 156, 9, 380, 26),
  el('button', 'Settings', 1502, 9, 26, 26),
  el('button', 'Close window', 1574, 14, 16, 16),
  el('list item', '', 8, 58, 194, 27),
  el('link', 'Inbox', 8, 58, 194, 27),
  el('list item', '', 8, 116, 194, 27),
  el('link', 'Sent', 8, 116, 194, 27),
  el('button', 'General', 230, 64, 86, 29),
  el('button', 'Privacy', 317, 64, 82, 29),
  el('table cell', 'Alice Martin', 230, 107, 174, 33),
  el('table cell', 'Edit', 845, 107, 108, 33),
  el('button', 'Edit', 853, 113, 42, 20),
  el('table cell', 'Delete', 952, 107, 138, 33),
  el('button', 'Delete', 960, 113, 58, 20),
  el('table cell', 'Bob Chen', 230, 139, 174, 34),
  el('table cell', 'Edit', 845, 139, 108, 34),
  el('button', 'Edit', 853, 146, 42, 20),
  el('button', 'Delete', 960, 146, 58, 20),
  el('link', '3', 308, 286, 22, 20),
  el('entry', 'Full name', 1147, 123, 396, 28),
  el('combo box', 'Language', 1147, 233, 396, 28),
  el('check box', 'Remember me', 1151, 272, 13, 13),
  el('button', 'Save', 1147, 353, 62, 29),
  el('button', 'Delete account', 1298, 353, 130, 29),
  el('link', 'Privacy', 230, 840, 40, 13),
  el('button', 'Open', 600, 600, 60, 20),
];

String? match(String target, {Point<int>? hint}) => matchElement(target, page, hint: hint)?.toString();

class FakeLocator implements ClickLocator {
  FakeLocator(this.answer, {this.name = 'fake'});
  final Point<int>? answer;
  final String name;
  final calls = <(String, Point<int>?)>[];

  @override
  Future<LocatedTarget> locate(String target, {Point<int>? hint}) async {
    calls.add((target, hint));
    final a = answer;
    if (a == null) throw LocateFailure('$name: not found');
    return LocatedTarget(a, method: LocateMethod.vision, elapsed: const Duration(milliseconds: 5));
  }
}

class FakeElements implements ElementSource {
  FakeElements(this.els);
  final List<UiElement> els;
  @override
  Future<List<UiElement>> elements() async => els;
}

class FakeResponses extends ResponsesClient {
  FakeResponses(this.reply, {this.error}) : super(credentials: () async => null);
  final String reply;
  final Object? error;
  final requests = <(String, List<Map<String, Object?>>, String?)>[];

  @override
  Future<ResponsesResult> create({
    required String model,
    required List<Map<String, Object?>> input,
    String? instructions,
    List<Map<String, Object?>>? tools,
    Map<String, Object?>? reasoning,
    void Function(String delta)? onTextDelta,
    void Function(FunctionCallItem call)? onFunctionCall,
    bool parallelToolCalls = false,
  }) async {
    requests.add((model, input, instructions));
    if (error != null) throw error!;
    return ResponsesResult(text: reply, functionCalls: const [], status: 'completed');
  }
}

void main() {
  group('Screenshot coordinate mapping', () {
    test('scales image pixels to the screen and back', () {
      final s = Screenshot(png: tinyPng(1280, 720), width: 1280, height: 720, originalWidth: 1600, originalHeight: 900);
      expect(s.scaleX, 1.25);
      expect(s.toScreen(0, 0), const Point(0, 0));
      expect(s.toScreen(640, 360), const Point(800, 450));
      expect(s.toScreen(1279, 719), const Point(1599, 899));
      expect(s.toScreen(5000, -3), const Point(1599, 0), reason: 'clamped to the captured area');
      expect(s.fromScreen(800, 450), const Point(640, 360));
      expect(s.fromScreen(1600, 10), isNull);
    });

    test('adds the capture origin (second monitor, offset region)', () {
      final s = Screenshot(
        png: tinyPng(960, 540),
        width: 960,
        height: 540,
        originalWidth: 1920,
        originalHeight: 1080,
        originX: 2560,
        originY: 360,
      );
      expect(s.toScreen(480, 270), const Point(2560 + 960, 360 + 540));
      expect(s.toScreen(-1, 9999), const Point(2560, 360 + 1079));
      expect(s.fromScreen(2560 + 960, 360 + 540), const Point(480, 270));
      expect(s.fromScreen(100, 100), isNull, reason: 'left of the captured monitor');
    });

    test('round trip stays within one screen pixel per image pixel', () {
      final s = Screenshot(png: tinyPng(1280, 720), width: 1280, height: 720, originalWidth: 2560, originalHeight: 1440);
      for (final (x, y) in [(0, 0), (1, 1), (333, 77), (1279, 719)]) {
        final p = s.toScreen(x, y);
        expect(s.fromScreen(p.x, p.y), Point(x, y));
      }
    });
  });

  group('parseLocateReply', () {
    test('reads x/y from bare JSON, prose and code fences', () {
      expect(parseLocateReply('{"x": 12, "y": 34}'), (x: 12, y: 34));
      expect(parseLocateReply('Here: ```json\n{"x":12.6,"y":3.2}\n```'), (x: 13, y: 3));
      expect(parseLocateReply('nothing'), isNull);
      expect(parseLocateReply('{"x": "a"}'), isNull);
    });

    test('reports {"error"} replies', () {
      String? err;
      expect(parseLocateReply('{"error": "no such button"}', onError: (e) => err = e), isNull);
      expect(err, 'no such button');
    });
  });

  group('matchElement', () {
    test('finds unique labels, by role and longest name', () {
      expect(match("the 'Save' button in the Profile form"), startsWith("button 'Save'"));
      expect(match('the Save button in the profile form'), startsWith("button 'Save'"));
      expect(match('Search mail field in the top bar'), startsWith("entry 'Search mail'"));
      expect(match('the Remember me checkbox'), startsWith("check box 'Remember me'"));
      expect(match('the Language dropdown'), startsWith("combo box 'Language'"));
      expect(match('the red Delete account button'), startsWith("button 'Delete account'"));
      expect(match('Inbox in the left sidebar'), startsWith("link 'Inbox'"), reason: 'not the unnamed list item');
      expect(match('the Privacy link in the footer'), startsWith("link 'Privacy'"), reason: 'role picks the link');
      expect(match('page 3 in the pager'), startsWith("link '3'"));
    });

    test('a quoted label must equal the name', () {
      expect(match('"Delete" button'), isNull, reason: 'two Delete buttons, no hint');
      expect(match('"Delete account"'), startsWith("button 'Delete account'"));
      expect(match('"Sav" button'), isNull);
    });

    test('leaves ambiguous or unnamed targets to vision', () {
      expect(match('the Edit button'), isNull, reason: 'two Edit buttons');
      expect(match("the Edit button in Carla Diaz's row"), isNull, reason: 'no such row in the tree');
      expect(match('the Privacy tab'), isNull, reason: 'Privacy button and link');
      expect(match('the gear icon at the top right'), isNull);
      expect(match('the search bar'), isNull, reason: '"Address and search bar" is not in the description');
      expect(match('click open the Settings'), startsWith("button 'Settings'"), reason: 'filler "open" never matches');
    });

    test('the row of a named cell picks among duplicates', () {
      expect(match('"Edit" button in Alice Martin\'s row of the mail list'), startsWith("button 'Edit' @853,113"));
      expect(match('"Delete" button in Bob Chen\'s row'), startsWith("button 'Delete' @960,146"));
      expect(match('"Edit" button in the Bob Chen row', hint: const Point(870, 120)), startsWith("button 'Edit' @853,146"));
    });

    test('a quoted label may be part of the name of the named role', () {
      expect(match('"Close" button (X) in the top-right corner'), startsWith("button 'Close window'"));
      expect(match('"Menu" button with three lines at the far left'), startsWith("button 'Main menu'"));
      expect(match('"Close" link in the footer'), isNull, reason: 'role must fit');
      expect(match('"Open" item'), isNull, reason: 'filler-only quote');
    });

    test('a hint picks among duplicates only when clearly nearer', () {
      // The table cell around each Edit button counts as the same control.
      expect(match('the Edit button', hint: const Point(870, 120)), startsWith("button 'Edit' @853,113"));
      expect(match('the Edit button', hint: const Point(870, 155)), startsWith("button 'Edit' @853,146"));
      expect(match('the Edit button', hint: const Point(870, 140)), isNull, reason: 'between the two rows');
    });
  });

  group('locators', () {
    test('ElementLocator clicks the element centre', () async {
      final l = ElementLocator(FakeElements(page));
      final r = await l.locate('the Save button');
      expect(r.point, const Point(1147 + 31, 353 + 14));
      expect(r.method, LocateMethod.element);
      expect(r.toJson(), containsPair('label', "button 'Save'"));
      await expectLater(l.locate('the gear icon'), throwsA(isA<LocateFailure>()));
    });

    test('ChainLocator falls through failures and reports them all', () async {
      final a = FakeLocator(null, name: 'a'), b = FakeLocator(const Point(5, 6), name: 'b');
      final r = await ChainLocator([a, b]).locate('x', hint: const Point(1, 2));
      expect(r.point, const Point(5, 6));
      expect(a.calls.single, ('x', const Point(1, 2)));
      expect(
        () => ChainLocator([a, FakeLocator(null, name: 'c')]).locate('x'),
        throwsA(isA<LocateFailure>().having((e) => e.reason, 'reason', 'a: not found; c: not found')),
      );
    });

    test('VisionLocator sends a fresh capture and maps the answer to the screen', () async {
      final screen = FakeScreen(width: 1600, height: 900, originalWidth: 3200, originalHeight: 1800);
      final client = FakeResponses('{"x": 800, "y": 100}');
      final l = VisionLocator(client: client, screen: screen, model: () => 'gpt-6-luna');
      final r = await l.locate("'Save' button", hint: const Point(1700, 260));
      expect(r.point, const Point(1600, 200));
      expect(r.method, LocateMethod.vision);
      final (model, input, instructions) = client.requests.single;
      expect(model, 'gpt-6-luna');
      expect(instructions, kLocateInstructions);
      final text = jsonEncode(input);
      expect(text, contains('Image size: 1600x900 pixels. Target:'));
      expect(text, contains('guessed about (850, 130)'), reason: 'hint in image pixels');
      expect(text, contains('data:image/png;base64,'));
    });

    test('VisionLocator failures become LocateFailure', () async {
      final screen = FakeScreen();
      Future<void> fails(FakeResponses c, Matcher reason) => expectLater(
        VisionLocator(client: c, screen: screen, model: () => 'm').locate('t'),
        throwsA(isA<LocateFailure>().having((e) => e.reason, 'reason', reason)),
      );
      await fails(FakeResponses('{"error": "not visible"}'), contains('not visible'));
      await fails(FakeResponses('{"x": 5000, "y": 1}'), contains('outside the image'));
      await fails(FakeResponses('', error: ResponsesException('HTTP 500')), contains('HTTP 500'));
    });
  });

  group('planClick', () {
    final shot = Screenshot(png: tinyPng(1280, 720), width: 1280, height: 720, originalWidth: 2560, originalHeight: 1440);

    test('x/y only map through the screenshot', () async {
      final p = await planClick(x: 100, y: 50, shot: shot, locator: FakeLocator(const Point(1, 1)));
      expect(p.point, const Point(200, 100));
      expect(p.info, isEmpty);
    });

    test('a target goes to the locator with the mapped hint', () async {
      final l = FakeLocator(const Point(7, 8));
      final p = await planClick(target: 'Save', x: 100, y: 50, shot: shot, locator: l);
      expect(p.point, const Point(7, 8));
      expect(l.calls.single, ('Save', const Point(200, 100)));
      expect(p.info['located_by'], 'vision');
    });

    test('falls back to the model estimate, or fails without one', () async {
      final p = await planClick(target: 'Save', x: 100, y: 50, shot: shot, locator: FakeLocator(null));
      expect(p.point, const Point(200, 100));
      expect(p.info, {'located_by': 'model_xy', 'locate_error': 'fake: not found'});
      await expectLater(planClick(target: 'Save', locator: FakeLocator(null)), throwsA(isA<ToolFailure>()));
      await expectLater(planClick(), throwsA(isA<ToolFailure>()));
      expect((await planClick(target: 'Save', x: 3, y: 4)).point, const Point(3, 4), reason: 'no locator, no shot');
    });

    test('a screen position ("center of the screen") skips the locator', () async {
      final l = FakeLocator(const Point(7, 8));
      for (final t in ['center of the screen area', 'the centre of the screen', 'Middle of my screen.', 'center', 'center of the screen (empty background area in the main workspace)', 'center of the screen, empty background area', 'the middle of the screen on the desktop background']) {
        final p = await planClick(target: t, x: 640, y: 360, shot: shot, locator: l);
        expect(p.point, const Point(1280, 720), reason: t);
        expect(p.info['located_by'], 'absolute');
      }
      expect((await planClick(target: 'top left corner of the screen', shot: shot, locator: l)).point, const Point(5, 5));
      expect((await planClick(target: 'bottom-right corner', shot: shot, locator: l)).point, const Point(2554, 1434));
      expect(l.calls, isEmpty);
      // Elements are still grounded, and an offset capture keeps its origin.
      for (final t in ['center of the dialog', "'Center' button", 'the middle tab', 'center of the screen (the OK button)', 'center of the screen, the Save button']) {
        expect(absoluteScreenPoint(t, shot), isNull, reason: t);
      }
      final right = Screenshot(png: shot.png, width: 640, height: 360, originalWidth: 1920, originalHeight: 1080, originX: 2560);
      expect(absoluteScreenPoint('center of the screen', right), const Point(2560 + 960, 540));
    });
  });

  test('click_screen resolves target through the environment locator', () async {
    final fp = await FakePlatform.create();
    addTearDown(fp.dispose);
    final env = ToolEnvironment(
      platform: fp.services,
      confirmations: FakeConfirmations(),
      delegate: _NoDelegate(),
      settings: () => const AppSettings(),
      onScreenshot: (s, note) async {},
      locator: ElementLocator(FakeElements(page)),
    );
    final registry = ToolRegistry()..registerAll(builtinTools(env));
    await registry.dispatch('take_screenshot', '{}');
    final o = await registry.dispatch('click_screen', jsonEncode({'target': "'Save' button", 'x': 10, 'y': 10}));
    final j = jsonDecode(o.json) as Map;
    expect(j['ok'], isTrue);
    expect(j['screen_xy'], [1178, 367]);
    expect(j['located_by'], 'element');
    expect(fp.input.log.last, 'click 1178 367 left');
    final miss = await registry.dispatch('click_screen', jsonEncode({'target': 'gear icon', 'x': 10, 'y': 10}));
    expect((jsonDecode(miss.json) as Map)['located_by'], 'model_xy');
    expect(fp.input.log.last, 'click 20 20 left', reason: 'FakeScreen is 1280x720 of 2560x1440');
    final none = await registry.dispatch('click_screen', '{}');
    expect(none.ok, isFalse);
  });

  test('atspiBitSet packs AT-SPI states/roles into signed int32 words', () {
    expect(atspiBitSet([25, 30]), [(1 << 25) | (1 << 30), 0]);
    expect(atspiBitSet([31]), [-2147483648, 0]);
    expect(atspiBitSet([43, 130], words: 5), [0, 1 << 11, 0, 0, 1 << 2]);
    expect(atspiRole('push button'), 'button');
    expect(atspiRole('password text'), 'entry');
  });
}

class _NoDelegate implements DelegateBackend {
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async =>
      DelegateResult(output: '', success: false);
}
