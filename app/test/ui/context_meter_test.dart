import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/context_meter.dart';

class _Gated implements Compressor {
  final gate = Completer<void>();
  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) async {
    await gate.future;
    return CompressionResult(summary: 'summary', tokensAfter: 10);
  }
}

void main() {
  late _Gated compressor;
  late ContextManager cm;
  late Conversation conv;

  setUp(() {
    compressor = _Gated();
    cm = ContextManager(compressor: compressor, threshold: 10000, keepRecentTurns: 2, minInterval: Duration.zero);
    conv = Conversation();
    cm.attach(conv);
    for (var i = 0; i < 6; i++) {
      conv.add(Message(kind: i.isEven ? MessageKind.user : MessageKind.assistant, text: 'x' * 400));
    }
    conv.add(
      Message(
        kind: MessageKind.user,
        image: const ImageAttachment(path: '/nope.png', width: 10, height: 10, originalWidth: 10, originalHeight: 10),
        audio: const AudioClip(path: '/nope.wav', durationMs: 5000),
      ),
    );
    conv.add(
      Message(
        kind: MessageKind.tool,
        tool: ToolCallInfo(callId: 'c', name: 'run_bash', argsJson: '{"command":"ls"}', resultJson: '{"stdout":"a"}'),
      ),
    );
    cm.onConversationChanged();
  });

  tearDown(() {
    if (!compressor.gate.isCompleted) compressor.gate.complete();
    cm.dispose();
  });

  test('formatTokens', () {
    expect(formatTokens(950), '950');
    expect(formatTokens(12400), '12.4k');
    expect(formatTokens(2100), '2.1k');
  });

  test('breakdown splits text, images, audio and tools', () {
    final b = ContextBreakdown.of(cm, conv);
    expect(b.imageCount, 1);
    expect(b.images, cm.imageTokenCost);
    expect(b.audio, 50);
    expect(b.toolCount, 1);
    expect(b.text, greaterThan(600));
    expect(b.threshold, 10000);
    expect(b.total, cm.estimatedTokens);
    expect(b.fill, closeTo(cm.estimatedTokens / 10000, 1e-9));
  });

  Widget host(ContextMeterStyle style, {VoidCallback? onCompact}) => MaterialApp(
    theme: buildWoiTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: ContextMeter(manager: cm, conversation: conv, style: style, onCompact: onCompact),
        ),
      ),
    ),
  );

  for (final style in ContextMeterStyle.values) {
    testWidgets('$style shows usage vs threshold in semantics', (tester) async {
      await tester.pumpWidget(host(style));
      final total = formatTokens(cm.estimatedTokens);
      expect(find.bySemanticsLabel(RegExp('$total.*10.0k')), findsOneWidget);
    });
  }

  testWidgets('shows compacting state while the compressor runs', (tester) async {
    await tester.pumpWidget(host(ContextMeterStyle.bar));
    expect(find.text('compacting…'), findsNothing);
    unawaited(cm.maybeCompress(force: true));
    await tester.pump();
    expect(cm.compressing, isTrue);
    expect(find.text('compacting…'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('compacting')), findsOneWidget);
    await tester.runAsync(() async {
      compressor.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(cm.compressing, isFalse);
    expect(find.text('compacting…'), findsNothing);
  });

  testWidgets('tap opens details with breakdown and Compact now', (tester) async {
    var compacted = 0;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(ContextMeterStyle.panel, onCompact: () => compacted++));
    await tester.tap(find.byType(ContextMeter));
    await tester.pumpAndSettle();
    expect(find.text('Compact now'), findsOneWidget);
    expect(find.textContaining('Screenshots'), findsWidgets);
    await tester.tap(find.text('Compact now'));
    await tester.pumpAndSettle();
    expect(compacted, 1);
  });
}
