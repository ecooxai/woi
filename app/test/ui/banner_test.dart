import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/banner.dart';
import 'package:woi/ui/widgets/context_meter.dart';

BannerData _b(String id, {Duration? auto = const Duration(seconds: 8), VoidCallback? onAction}) => BannerData(
  id: id,
  icon: Icons.info_outline,
  color: WoiColors.violet,
  title: 'Banner $id',
  actionLabel: onAction == null ? null : 'Retry',
  onAction: onAction,
  autoDismiss: auto,
);

void main() {
  test('compaction banner text', () {
    expect(
      compactionBannerText(formatTokens(12400), formatTokens(2100)),
      'Context compacted 12.4k → 2.1k — now using new context',
    );
  });

  test('controller: newest first, same id replaces, max three, auto-dismiss', () {
    fakeAsync((fa) {
      final c = BannerController();
      c.show(_b('a'));
      c.show(_b('b', auto: null));
      c.show(_b('a'));
      expect(c.items.map((b) => b.id), ['a', 'b']);
      c.show(_b('c'));
      c.show(_b('d'));
      expect(c.items.map((b) => b.id), ['d', 'c', 'a']);
      fa.elapse(const Duration(seconds: 9));
      expect(c.items, isEmpty, reason: 'b was evicted, the rest auto-dismissed');
      c.show(_b('sticky', auto: null));
      fa.elapse(const Duration(minutes: 5));
      expect(c.items.single.id, 'sticky');
      c.dismiss('sticky');
      expect(c.items, isEmpty);
      c.dispose();
    });
  });

  testWidgets('bounded banners leave short content interactive and scroll longer stacks to their actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = BannerController();
    final transcript = ScrollController();
    addTearDown(transcript.dispose);
    var taps = 0;
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerDown: (_) => taps++,
                  child: SingleChildScrollView(
                    controller: transcript,
                    child: const SizedBox(height: 1000, width: double.infinity),
                  ),
                ),
              ),
              Positioned(top: 10, bottom: 10, left: 10, right: 10, child: BannerStack(controller: c)),
            ],
          ),
        ),
      ),
    );
    c.show(_b('first', auto: null, onAction: () => retried++));
    await tester.pumpAndSettle();
    final shortBottom = tester.getRect(find.byType(WoiBanner)).bottom;
    expect(shortBottom, lessThan(250));
    await tester.tapAt(const Offset(150, 275));
    expect(taps, 1, reason: 'A short banner must not intercept the transcript below it.');
    await tester.dragFrom(const Offset(150, 275), const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(transcript.offset, greaterThan(0));
    c.show(_b('second', auto: null));
    c.show(_b('third', auto: null));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(of: find.byType(BannerStack), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('Retry'), 80, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(find.text('Retry').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.text('Retry')).bottom, lessThanOrEqualTo(290));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, 1);
    expect(c.items.map((b) => b.id), isNot(contains('first')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('stack shows banners; dismiss button and action work', (tester) async {
    final c = BannerController();
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Scaffold(body: BannerStack(controller: c)),
      ),
    );
    c.show(_b('x', auto: null, onAction: () => retried++));
    await tester.pumpAndSettle();
    expect(find.text('Banner x'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Banner x')), findsWidgets);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retried, 1);

    c.show(_b('y', auto: null));
    await tester.pumpAndSettle();
    expect(find.text('Banner y'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss').first);
    await tester.pumpAndSettle();
    expect(c.items.map((b) => b.id), isNot(contains('y')));
    expect(find.text('Banner y'), findsNothing);
    c.dispose();
  });
}
