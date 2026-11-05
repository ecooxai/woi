import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/chat_transcript.dart';

/// A fixed "now": Thursday 2026-03-12, 15:00 local.
final _now = DateTime(2026, 3, 12, 15);

List<Message> _messages(int n, {DateTime? last, Duration step = const Duration(minutes: 1)}) {
  final end = last ?? _now;
  return [
    for (var i = 0; i < n; i++)
      Message(id: 'm$i', kind: i.isEven ? MessageKind.user : MessageKind.assistant, text: 'msg $i', createdAt: end.subtract(step * (n - 1 - i))),
  ];
}

class _Host extends StatefulWidget {
  const _Host({required this.messages, this.conversationId = 'c1'});
  final List<Message> messages;
  final String conversationId;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<Message> messages = widget.messages;
  late String conv = widget.conversationId;

  void add(Message m) => setState(() => messages.add(m));
  void switchTo(String id, List<Message> msgs) => setState(() {
    conv = id;
    messages = msgs;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    endDrawer: const Drawer(child: Text('history-drawer', key: ValueKey('history-drawer'))),
    body: Builder(
      builder: (context) => ChatTranscript(
        conversationId: conv,
        // A new widget each rebuild, like the pipeline-driven owner.
        messages: messages,
        clock: () => _now,
        onOpenHistory: () => Scaffold.of(context).openEndDrawer(),
        tileBuilder: (context, m, i) => SizedBox(height: 60, child: Text(m.text)),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester t, Widget host) async {
  await t.binding.setSurfaceSize(const Size(500, 700));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(theme: buildWoiTheme(), home: host));
}

ChatTranscriptState _state(WidgetTester t) => t.state<ChatTranscriptState>(find.byType(ChatTranscript));

Future<void> _scrollToTop(WidgetTester t) async {
  final sc = _state(t).scrollController;
  sc.jumpTo(sc.position.maxScrollExtent);
  await t.pump();
}

void main() {
  test('day labels', () {
    expect(dayLabel(DateTime(2026, 3, 12, 0, 1), _now), 'Today');
    expect(dayLabel(DateTime(2026, 3, 11, 23, 59), _now), 'Yesterday');
    expect(dayLabel(DateTime(2026, 3, 10), _now), 'Tuesday');
    expect(dayLabel(DateTime(2026, 3, 6), _now), 'Friday');
    expect(dayLabel(DateTime(2026, 3, 5), _now), 'Mar 5');
    expect(dayLabel(DateTime(2025, 12, 31), _now), 'Dec 31, 2025');
    expect(dayLabel(DateTime(2026, 1, 1), DateTime(2026, 1, 1, 0, 0, 1)), 'Today');
    expect(dayLabel(DateTime(2025, 12, 31, 23), DateTime(2026, 1, 1, 0, 0, 1)), 'Yesterday');
  });

  testWidgets('300 messages render only the newest 50', (t) async {
    await _pump(t, _Host(messages: _messages(300)));
    expect(_state(t).renderedCount, 50);
    expect(find.text('msg 299'), findsOneWidget, reason: 'opens at the newest message');
    await _scrollToTop(t);
    // The scroll reached the top: one step loads 20 more.
    expect(_state(t).renderedCount, 70);
  });

  testWidgets('scrolling to the top loads 20 more up to 200, then the History footer opens the drawer', (t) async {
    await _pump(t, _Host(messages: _messages(300)));
    expect(_state(t).renderedCount, 50);
    final seen = <int>[];
    for (var i = 0; i < 10; i++) {
      await _scrollToTop(t);
      seen.add(_state(t).renderedCount);
    }
    expect(seen, [70, 90, 110, 130, 150, 170, 190, 200, 200, 200]);
    await _scrollToTop(t);
    // The oldest rendered message is #100 (300 - 200), nothing older.
    expect(find.text('msg 100'), findsOneWidget);
    expect(find.text('msg 99'), findsNothing);
    expect(find.text('Older messages are in History'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('transcript-open-history')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-drawer')), findsOneWidget);
  });

  testWidgets('loading more keeps the message on screen in place', (t) async {
    await _pump(t, _Host(messages: _messages(300)));
    final sc = _state(t).scrollController;
    // Just below the load threshold: the oldest rendered messages are visible.
    sc.jumpTo(sc.position.maxScrollExtent - 200);
    await t.pump();
    expect(_state(t).renderedCount, 50);
    final anchor = find.text('msg 252');
    final before = t.getTopLeft(anchor);
    final pixels = sc.position.pixels;
    expect(_state(t).loadMore(), isTrue);
    await t.pump();
    expect(_state(t).renderedCount, 70);
    expect(sc.position.pixels, pixels);
    expect(t.getTopLeft(anchor), before);
    expect(sc.position.maxScrollExtent - sc.position.pixels, greaterThan(1000), reason: 'room to scroll up again');
  });

  testWidgets('no History footer when everything fits in the window', (t) async {
    await _pump(t, _Host(messages: _messages(120)));
    for (var i = 0; i < 6; i++) {
      await _scrollToTop(t);
    }
    expect(_state(t).renderedCount, 120);
    expect(find.text('msg 0'), findsOneWidget);
    expect(find.text('Older messages are in History'), findsNothing);
  });

  testWidgets('day separators: one before the first message and between days', (t) async {
    final msgs = [
      Message(id: 'a', kind: MessageKind.user, text: 'old', createdAt: DateTime(2025, 11, 20, 9)),
      Message(id: 'b', kind: MessageKind.user, text: 'last week', createdAt: DateTime(2026, 3, 4, 9)),
      Message(id: 'c', kind: MessageKind.user, text: 'monday', createdAt: DateTime(2026, 3, 9, 9)),
      Message(id: 'd', kind: MessageKind.assistant, text: 'monday 2', createdAt: DateTime(2026, 3, 9, 23, 59)),
      Message(id: 'e', kind: MessageKind.user, text: 'yesterday', createdAt: DateTime(2026, 3, 11, 8)),
      Message(id: 'f', kind: MessageKind.user, text: 'today', createdAt: DateTime(2026, 3, 12, 0, 1)),
      Message(id: 'g', kind: MessageKind.assistant, text: 'today 2', createdAt: DateTime(2026, 3, 12, 14)),
    ];
    await _pump(t, _Host(messages: msgs));
    final chips = t.widgetList<DayChip>(find.byType(DayChip)).map((c) => c.label).toList();
    // Newest first (the list is bottom-anchored).
    expect(chips, ['Today', 'Yesterday', 'Monday', 'Mar 4', 'Nov 20, 2025']);
    // The chip sits above its day's first message.
    expect(t.getTopLeft(find.text('Today')).dy, lessThan(t.getTopLeft(find.text('today')).dy));
    expect(t.getTopLeft(find.text('today')).dy, lessThan(t.getTopLeft(find.text('today 2')).dy));
    expect(t.getTopLeft(find.text('Yesterday')).dy, lessThan(t.getTopLeft(find.text('yesterday')).dy));
    expect(t.getTopLeft(find.text('Yesterday')).dy, greaterThan(t.getTopLeft(find.text('monday 2')).dy));
  });

  testWidgets('a separator also precedes the first rendered message of a window', (t) async {
    // 300 messages over one day: the window starts mid-day, still with a chip.
    await _pump(t, _Host(messages: _messages(300, step: const Duration(seconds: 10))));
    for (var i = 0; i < 10; i++) {
      await _scrollToTop(t);
    }
    expect(_state(t).renderedCount, 200);
    expect(find.text('Today'), findsOneWidget);
    expect(t.getTopLeft(find.text('Older messages are in History')).dy, lessThan(t.getTopLeft(find.text('Today')).dy));
    expect(t.getTopLeft(find.text('Today')).dy, lessThan(t.getTopLeft(find.text('msg 100')).dy));
  });

  testWidgets('a new message at the bottom stays visible and the window keeps its size', (t) async {
    await _pump(t, _Host(messages: _messages(60)));
    final host = t.state<_HostState>(find.byType(_Host));
    expect(_state(t).renderedCount, 50);
    host.add(Message(id: 'new', kind: MessageKind.assistant, text: 'fresh reply', createdAt: _now));
    await t.pump();
    expect(find.text('fresh reply'), findsOneWidget);
    expect(t.getBottomLeft(find.text('fresh reply')).dy, lessThanOrEqualTo(700));
    expect(_state(t).scrollController.position.pixels, 0);
    expect(_state(t).renderedCount, 50, reason: 'the oldest dropped out of the rendered window');
  });

  testWidgets('a new message while reading older ones extends the window', (t) async {
    await _pump(t, _Host(messages: _messages(300)));
    final host = t.state<_HostState>(find.byType(_Host));
    final sc = _state(t).scrollController;
    sc.jumpTo(1000);
    await t.pump();
    expect(_state(t).renderedCount, 50);
    host.add(Message(id: 'new', kind: MessageKind.assistant, text: 'fresh reply', createdAt: _now));
    await t.pump();
    expect(_state(t).renderedCount, 51);
  });

  testWidgets('switching conversations resets to the newest 50', (t) async {
    await _pump(t, _Host(messages: _messages(300)));
    await _scrollToTop(t);
    await _scrollToTop(t);
    expect(_state(t).renderedCount, 90);
    t.state<_HostState>(find.byType(_Host)).switchTo('c2', _messages(250));
    await t.pump();
    expect(_state(t).renderedCount, 50);
    expect(_state(t).scrollController.position.pixels, 0);
    expect(find.text('msg 249'), findsOneWidget);
  });
}
