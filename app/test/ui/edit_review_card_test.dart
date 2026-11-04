import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/edits/edit_review.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/edit_review_card.dart';

void main() {
  Widget host(EditReview r) => MaterialApp(
    theme: buildWoiTheme(),
    home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: EditReviewCard(review: r))),
  );

  Finder ring(String s) => find.descendant(of: find.byKey(const ValueKey('edit-review-countdown')), matching: find.text(s));

  PendingEdit edit({bool approval = false}) => PendingEdit(
    target: EditTarget.note,
    title: 'Note',
    oldText: '# Todo\n- eggs\n',
    newText: approval ? '' : '# Todo\n- eggs\n- buy milk\n',
    summary: 'Appended 1 line',
    requireApproval: approval,
  );

  testWidgets('shows the diff and a countdown, then applies itself', (t) async {
    final r = EditReview(delaySeconds: () => 5);
    await t.pumpWidget(host(r));
    expect(find.byKey(const ValueKey('edit-review-apply')), findsNothing);
    bool? applied;
    r.review(edit()).then((v) => applied = v);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Note edit', findRichText: true), findsOneWidget);
    expect(find.textContaining('buy milk'), findsWidgets);
    expect(find.byKey(const ValueKey('edit-review-countdown')), findsOneWidget);
    expect(ring('5'), findsOneWidget);
    expect(find.text('Apply now'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 2050));
    expect(ring('3'), findsOneWidget);
    // 2.4 s left reads "2", not "3" (nearest second, not up to +1 s).
    await t.pump(const Duration(milliseconds: 550));
    expect(ring('2'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 2450));
    await t.pump(const Duration(milliseconds: 300));
    expect(applied, isTrue);
    expect(find.byKey(const ValueKey('edit-review-apply')), findsNothing);
    r.dispose();
  });

  testWidgets('Reject and Apply now buttons decide it', (t) async {
    final r = EditReview(delaySeconds: () => 10);
    await t.pumpWidget(host(r));
    bool? a, b;
    r.review(edit()).then((v) => a = v);
    r.review(edit()).then((v) => b = v);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('+1 queued', findRichText: true), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('edit-review-reject')));
    await t.pump(const Duration(milliseconds: 300));
    expect(a, isFalse);
    await t.tap(find.byKey(const ValueKey('edit-review-apply')));
    await t.pump(const Duration(milliseconds: 300));
    expect(b, isTrue);
    r.dispose();
  });

  testWidgets('approval-only edits have no countdown', (t) async {
    final r = EditReview(delaySeconds: () => kRequireApproval);
    await t.pumpWidget(host(r));
    r.review(edit());
    await t.pump();
    expect(find.byKey(const ValueKey('edit-review-countdown')), findsNothing);
    expect(find.text('needs approval'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    await t.pump(const Duration(seconds: 30));
    expect(r.hasPending, isTrue);
    r.rejectAll();
    await t.pump(const Duration(milliseconds: 300));
    r.dispose();
  });
}
