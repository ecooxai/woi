import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/ui/notes/note_tabs.dart';
import 'package:woi/ui/theme.dart';

import '../fakes/fakes.dart';

class _ListController extends AppController {
  _ListController(FakePlatform platform)
    : super(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );

  List<ConversationSummary> entries = [];
  Future<List<ConversationSummary>> Function()? load;
  int listReads = 0;

  @override
  Future<List<ConversationSummary>> listConversations() {
    listReads++;
    return load?.call() ?? Future.value(List.of(entries));
  }

  void unrelatedNotification() => notifyListeners();
}

ConversationSummary _summary(String id, String title) =>
    ConversationSummary(id: id, title: title, updatedAt: DateTime.utc(2026, 11, 10), messageCount: 0);

Future<_ListController> _fixture(WidgetTester tester) async {
  late FakePlatform platform;
  late _ListController controller;
  await tester.runAsync(() async {
    platform = await FakePlatform.create();
    controller = _ListController(platform);
    await controller.init();
    expect(controller.initError, isNull);
    controller.notes.setText('# Survivor\n\nExact body.');
    await controller.notes.flush();
    await controller.history.flush(controller.pipeline.conversation);
    for (final id in ['other', 'third', 'fourth']) {
      await controller.history.save(Conversation(id: id, title: 'Original $id'));
    }
  });
  controller.entries = [
    _summary(controller.pipeline.conversation.id, 'Survivor'),
    _summary('other', 'Original other'),
    _summary('third', 'Original third'),
    _summary('fourth', 'Original fourth'),
  ];
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await controller.shutdown();
      await platform.dispose();
    });
    await tester.pump(const Duration(seconds: 2));
    await tester.binding.setSurfaceSize(null);
  });
  return controller;
}

Future<void> _pumpBar(WidgetTester tester, _ListController controller, {double width = 900}) async {
  await tester.binding.setSurfaceSize(Size(width, 300));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildWoiTheme(),
      home: Scaffold(body: NoteTabsBar(controller: controller)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('inactive deletion removes its tab without switching or refreshing More', (tester) async {
    final controller = await _fixture(tester);
    final currentId = controller.pipeline.conversation.id;
    controller.notes.rememberSelection(2, 10);
    await _pumpBar(tester, controller);
    expect(find.byKey(const ValueKey('note-tab-other')), findsOneWidget);

    controller.entries.removeWhere((entry) => entry.id == 'other');
    await tester.runAsync(() => controller.deleteConversation('other'));
    await tester.pump();
    expect(find.byKey(const ValueKey('note-tab-other')), findsNothing);
    expect(controller.pipeline.conversation.id, currentId);
    expect(controller.notes.text, '# Survivor\n\nExact body.');
    expect((controller.notes.selectionStart, controller.notes.selectionEnd), (2, 10));
  });

  testWidgets('inactive and active custom renames update immediately', (tester) async {
    final controller = await _fixture(tester);
    await _pumpBar(tester, controller);
    controller.entries[1] = _summary('other', 'Renamed other');
    await tester.runAsync(() => controller.renameConversation('other', 'Renamed other'));
    await tester.pump();
    expect(find.text('Renamed other'), findsOneWidget);
    expect(find.text('Original other'), findsNothing);

    await tester.runAsync(() => controller.renameConversation(controller.pipeline.conversation.id, 'My note'));
    await tester.pump();
    expect(find.text('My note'), findsOneWidget);
    expect(controller.notes.text, '# Survivor\n\nExact body.');
  });

  testWidgets('ordinary notifications do not scan files or reset intentional tab scrolling', (tester) async {
    final controller = await _fixture(tester);
    await _pumpBar(tester, controller, width: 320);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    final offset = scrollable.position.pixels;
    expect(offset, greaterThan(0));
    final reads = controller.listReads;
    for (var i = 0; i < 100; i++) {
      controller.unrelatedNotification();
    }
    await tester.pump();
    expect(controller.listReads, reads);
    expect(scrollable.position.pixels, offset);

    controller.entries[1] = _summary('other', 'Changed other');
    await tester.runAsync(() => controller.renameConversation('other', 'Changed other'));
    await tester.pump();
    expect(scrollable.position.pixels, offset);
  });

  testWidgets('mutations coalesce behind a pending read and stale results cannot restore old entries', (tester) async {
    final controller = await _fixture(tester);
    final old = Completer<List<ConversationSummary>>();
    final latest = Completer<List<ConversationSummary>>();
    controller.load = () => controller.listReads == 1 ? old.future : latest.future;
    await _pumpBar(tester, controller);
    expect(controller.listReads, 1);

    controller.entries.removeWhere((entry) => entry.id == 'other');
    await tester.runAsync(() => controller.deleteConversation('other'));
    await tester.runAsync(() => controller.renameConversation('third', 'Latest third'));
    controller.entries[1] = _summary('third', 'Latest third');
    await tester.pump();
    expect(controller.listReads, 1, reason: 'one list read may be in flight');
    old.complete([_summary('other', 'Stale deleted note')]);
    await tester.pump();
    await tester.pump();
    expect(controller.listReads, 2, reason: 'one refresh serves the coalesced changes');
    expect(find.text('Stale deleted note'), findsNothing);
    latest.complete(List.of(controller.entries));
    await tester.pump();
    await tester.pump();
    expect(find.text('Latest third'), findsOneWidget);
    expect(find.byKey(const ValueKey('note-tab-other')), findsNothing);
    expect(controller.listReads, 2);
  });

  testWidgets('a pending read cannot restore old tabs after a conversation switch or disposal', (tester) async {
    final controller = await _fixture(tester);
    final old = Completer<List<ConversationSummary>>();
    final fresh = Completer<List<ConversationSummary>>();
    controller.load = () => controller.listReads == 1 ? old.future : fresh.future;
    await _pumpBar(tester, controller);
    final previousId = controller.pipeline.conversation.id;
    await tester.runAsync(controller.newConversation);
    expect(controller.pipeline.conversation.id, isNot(previousId));
    old.complete([_summary('obsolete', 'Obsolete read')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Obsolete read'), findsNothing);
    expect(controller.listReads, 2);
    await tester.pumpWidget(const SizedBox());
    fresh.complete([_summary('late', 'Late result')]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the controller detaches listeners and discards its pending snapshot', (tester) async {
    final previous = await _fixture(tester);
    final old = Completer<List<ConversationSummary>>();
    previous.load = () => old.future;
    await _pumpBar(tester, previous);

    final replacement = await _fixture(tester);
    await tester.runAsync(
      () => replacement.renameConversation(replacement.pipeline.conversation.id, 'Replacement note'),
    );
    replacement.entries = [_summary(replacement.pipeline.conversation.id, 'Replacement note')];
    await _pumpBar(tester, replacement);
    old.complete([_summary('retired', 'Retired controller snapshot')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Replacement note'), findsOneWidget);
    expect(find.text('Retired controller snapshot'), findsNothing);
    expect(replacement.listReads, 1);
    previous.unrelatedNotification();
    await tester.pump();
    expect(previous.listReads, 1);
    expect(replacement.listReads, 1);
  });

  testWidgets('deleting the current note switches safely and drops the deleted tab', (tester) async {
    final controller = await _fixture(tester);
    final deletedId = controller.pipeline.conversation.id;
    await _pumpBar(tester, controller);
    controller.entries.removeWhere((entry) => entry.id == deletedId);
    await tester.runAsync(() => controller.deleteConversation(deletedId));
    await tester.pump();
    expect(controller.pipeline.conversation.id, isNot(deletedId));
    expect(controller.notes.text, isEmpty);
    expect(find.byKey(ValueKey('note-tab-$deletedId')), findsNothing);
    expect(find.byKey(ValueKey('note-tab-${controller.pipeline.conversation.id}')), findsOneWidget);
  });
}
