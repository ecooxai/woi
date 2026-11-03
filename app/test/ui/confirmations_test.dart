import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/util/diff.dart';
import 'package:woi/platform/files.dart';
import 'package:woi/ui/confirmations.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/diff_view.dart';

FileWriteRequest _req({String? old = 'a\nb\nc\n', String next = 'a\nB\nc\nd\n'}) =>
    FileWriteRequest(path: '/tmp/demo.dart', oldContent: old, newContent: next, diff: diffLines(old ?? '', next));

void main() {
  serviceTests();

  Future<bool?> open(WidgetTester tester, Widget Function() dialog, {Size size = const Size(1400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(context: context, builder: (_) => dialog());
                  done = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return Future.value(done ? result : null);
  }

  Future<bool?> resultAfterKey(WidgetTester tester, LogicalKeyboardKey key, Widget Function() dialog) async {
    bool? result;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showDialog<bool>(context: context, builder: (_) => dialog()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('edit dialog: Enter approves', (tester) async {
    final r = await resultAfterKey(tester, LogicalKeyboardKey.enter, () => EditConfirmDialog(request: _req()));
    expect(r, isTrue);
  });

  testWidgets('edit dialog: Esc rejects', (tester) async {
    final r = await resultAfterKey(tester, LogicalKeyboardKey.escape, () => EditConfirmDialog(request: _req()));
    expect(r, isFalse);
  });

  testWidgets('command dialog: Enter approves, Esc rejects', (tester) async {
    expect(
      await resultAfterKey(tester, LogicalKeyboardKey.enter, () => const CommandConfirmDialog(command: 'ls')),
      isTrue,
    );
    expect(
      await resultAfterKey(tester, LogicalKeyboardKey.escape, () => const CommandConfirmDialog(command: 'rm -rf x')),
      isFalse,
    );
  });

  testWidgets('edit dialog shows a diff with key hints and toggles split/unified', (tester) async {
    await open(tester, () => EditConfirmDialog(request: _req(), initialLayout: DiffLayout.unified));
    expect(find.byType(DiffView), findsOneWidget);
    expect(find.text('Enter'), findsWidgets);
    expect(find.text('Esc'), findsWidgets);
    expect(tester.widget<DiffView>(find.byType(DiffView)).layout, DiffLayout.unified);
    await tester.tap(find.text('Split'));
    await tester.pumpAndSettle();
    expect(tester.widget<DiffView>(find.byType(DiffView)).layout, DiffLayout.split);
    expect(find.text('BEFORE'), findsOneWidget);
    expect(find.text('AFTER'), findsOneWidget);
  });

  testWidgets('new files show no split toggle', (tester) async {
    await open(tester, () => EditConfirmDialog(request: _req(old: null, next: 'hello\n')));
    expect(find.text('Split'), findsNothing);
    expect(find.byType(DiffView), findsOneWidget);
  });

  testWidgets('buttons work on a phone-sized screen', (tester) async {
    bool? result;
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showDialog<bool>(
                context: context,
                builder: (_) => EditConfirmDialog(request: _req()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Split'), findsNothing, reason: 'split view needs width');
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  test('splitRows pairs deletions with insertions', () {
    final rows = splitRows(diffLines('a\nb\nc\n', 'a\nB\nc\n').withContext(3));
    final changed = rows.where((r) => !r.isGap && r.left?.op != DiffOp.equal).toList();
    expect(changed, hasLength(1), reason: rows.map((r) => '${r.left?.text}|${r.right?.text}').join(', '));
    expect(changed.single.left!.text, 'b');
    expect(changed.single.right!.text, 'B');
  });
}

void serviceTests() {
  testWidgets('service: closes Settings-like routes, cues, then asks', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<NavigatorState>();
    var cues = 0;
    final service = UiConfirmationService(key, onShow: () async => cues++);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: buildWoiTheme(),
        home: const Scaffold(body: Text('home')),
      ),
    );
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('settings'))));
    await tester.pumpAndSettle();
    expect(find.text('settings'), findsOneWidget);

    bool? result;
    service.confirmCommand('rm -rf /tmp/x').then((r) => result = r);
    await tester.pumpAndSettle();
    expect(cues, 1);
    expect(find.text('settings'), findsNothing, reason: 'the dialog must not render over Settings');
    expect(find.byType(CommandConfirmDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.text('home'), findsOneWidget);
  });
}
