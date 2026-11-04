import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/notes/markdown_syntax.dart';
import 'package:woi/ui/widgets/message_tile.dart';
import 'package:woi/ui/widgets/throttled_builder.dart';

import '../fakes/fakes.dart';

void main() {
  group('Throttle', () {
    test('first call runs at once; a burst runs leading calls in-line and one trailing run', () {
      fakeAsync((async) {
        final t = Throttle(const Duration(milliseconds: 100), now: () => DateTime(2000).add(async.elapsed));
        final runs = <int>[];
        t(() => runs.add(0));
        expect(runs, [0]);
        expect(t.pending, isFalse);
        // Inside the interval: held, the latest action wins.
        async.elapse(const Duration(milliseconds: 30));
        t(() => runs.add(1));
        async.elapse(const Duration(milliseconds: 30));
        t(() => runs.add(2));
        expect(runs, [0]);
        expect(t.pending, isTrue);
        // 100 ms after the last run: the next call runs at once (no timer frame).
        async.elapse(const Duration(milliseconds: 45));
        t(() => runs.add(3));
        expect(runs, [0, 3]);
        expect(t.pending, isFalse);
        // A held call with no follow-up runs once the interval passes.
        async.elapse(const Duration(milliseconds: 10));
        t(() => runs.add(4));
        async.elapse(const Duration(milliseconds: 99));
        expect(runs, [0, 3]);
        async.elapse(const Duration(milliseconds: 2));
        expect(runs, [0, 3, 4]);
        async.elapse(const Duration(seconds: 1));
        expect(runs, [0, 3, 4]);
      });
    });

    test('10 calls/s for 3 s with a 250 ms interval run about 4 times a second', () {
      fakeAsync((async) {
        final t = Throttle(const Duration(milliseconds: 250), now: () => DateTime(2000).add(async.elapsed));
        var runs = 0;
        for (var i = 0; i < 30; i++) {
          t(() => runs++);
          async.elapse(const Duration(milliseconds: 100));
        }
        async.elapse(const Duration(seconds: 1));
        expect(runs, inInclusiveRange(9, 12));
      });
    });

    test('cancel drops the held call', () {
      fakeAsync((async) {
        final t = Throttle(const Duration(milliseconds: 100), now: () => DateTime(2000).add(async.elapsed));
        var runs = 0;
        t(() => runs++);
        t(() => runs++);
        t.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(runs, 1);
      });
    });
  });

  testWidgets('ThrottledBuilder rebuilds at most once per interval and shows the final state', (tester) async {
    final n = ValueNotifier(0);
    var builds = 0;
    var t = DateTime(2000);
    Future<void> pump(int ms) {
      t = t.add(Duration(milliseconds: ms));
      return tester.pump(Duration(milliseconds: ms));
    }

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ThrottledBuilder(
          listenable: n,
          now: () => t,
          interval: const Duration(milliseconds: 200),
          builder: (_) {
            builds++;
            return Text('${n.value}');
          },
        ),
      ),
    );
    expect(builds, 1);
    for (var i = 0; i < 10; i++) {
      n.value++;
      await pump(50);
    }
    // 500 ms of changes every 50 ms: the first build, then a rebuild at 0,
    // 200 and 400 ms, not ten.
    expect(builds, 4);
    await pump(300);
    expect(find.text('10'), findsOneWidget);
  });

  testWidgets('SelectorBuilder rebuilds only when the selected value changes', (tester) async {
    final n = ValueNotifier(0);
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SelectorBuilder<bool>(
          listenable: n,
          selector: () => n.value >= 5,
          builder: (_, big) {
            builds++;
            return Text(big ? 'big' : 'small');
          },
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      n.value++;
      await tester.pump();
    }
    expect(builds, 1);
    n.value = 7;
    await tester.pump();
    expect(builds, 2);
    expect(find.text('big'), findsOneWidget);
  });

  test('SelectedListenable notifies on selected changes only, and only while listened to', () {
    final n = ValueNotifier(0);
    final sel = SelectedListenable<int>(n, () => n.value ~/ 10);
    var hits = 0;
    void l() => hits++;
    sel.addListener(l);
    for (var i = 1; i <= 25; i++) {
      n.value = i;
    }
    expect(hits, 2); // 10 and 20
    sel.removeListener(l);
    n.value = 99;
    expect(hits, 2);
    sel.dispose();
  });

  group('LiveMessageTile', () {
    testWidgets('a streaming delta rebuilds only its own tile', (tester) async {
      final pipeline = ChangeNotifier();
      final a = Message(kind: MessageKind.user, text: 'hello');
      final b = Message(kind: MessageKind.assistant, text: 'Sure', streaming: true);
      final shownA = <Object>[];
      final sigA = messageRenderSignature(a);
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SelectorBuilder<Object>(
                listenable: pipeline,
                selector: () => messageRenderSignature(a),
                builder: (_, s) {
                  shownA.add(s);
                  return const SizedBox();
                },
              ),
              for (final m in [a, b])
                LiveMessageTile(
                  key: ValueKey(m.id),
                  listenable: pipeline,
                  message: m,
                  audio: FakeAudioIO(),
                  viewer: FakeViewer(),
                ),
            ],
          ),
        ),
      );
      b.text += ', here it is';
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      pipeline.notifyListeners();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Sure, here it is'), findsOneWidget);
      expect(shownA, [sigA]); // the other message did not change
      expect(find.byType(RepaintBoundary), findsWidgets);
      await tester.pump(const Duration(seconds: 1));
    });

    test('signature follows the fields a tile shows', () {
      final m = Message(kind: MessageKind.tool, tool: ToolCallInfo(callId: 'c', name: 'n', argsJson: '{}'));
      final s0 = messageRenderSignature(m);
      expect(messageRenderSignature(m), s0);
      m.tool!.status = ToolStatus.running;
      final s1 = messageRenderSignature(m);
      expect(s1, isNot(s0));
      m.meta['imageTier'] = 'reduced';
      expect(messageRenderSignature(m), isNot(s1));
      final s2 = messageRenderSignature(m);
      m.compacted = true;
      expect(messageRenderSignature(m), isNot(s2));
    });
  });

  test('highlightMarkdown merges adjacent runs with the same style', () {
    const src = 'plain line one\nplain line two\nplain line three\n- item\n';
    final runs = highlightMarkdown(src);
    var pos = 0;
    for (var i = 0; i < runs.length; i++) {
      expect(runs[i].start, pos);
      pos = runs[i].end;
      if (i > 0) expect(runs[i].style == runs[i - 1].style, isFalse, reason: 'run $i not merged');
    }
    expect(pos, src.length);
    // Three plain lines and their newlines are one run.
    expect(runs.first.end, greaterThanOrEqualTo(src.indexOf('- item')));
    // The list bullet keeps the body font (no font switch), only its colour.
    final bullet = runs.firstWhere((r) => r.start <= src.indexOf('- item') && r.end > src.indexOf('- item'));
    expect(bullet.style.fontFamily, runs.first.style.fontFamily);
  });
}
