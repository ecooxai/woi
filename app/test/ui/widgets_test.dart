import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/viewer/viewer_app.dart' show wavPeaks;
import 'package:woi/ui/widgets/controls.dart';
import 'package:woi/ui/widgets/empty_state.dart';
import 'package:woi/ui/widgets/input_bar.dart' show composerDisabledHint;
import 'package:woi/ui/widgets/message_tile.dart';
import 'package:woi/ui/widgets/status_chip.dart';

import '../fakes/fakes.dart';

Widget _app(Widget child, {double width = 900}) => MaterialApp(
  theme: buildWoiTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: width, child: child)),
  ),
);

void main() {
  group('connection status', () {
    test('reconnecting only after a successful connection', () {
      expect(linkStateFor(SessionStatus.connecting, wasConnected: false), LinkState.connecting);
      expect(linkStateFor(SessionStatus.connecting, wasConnected: true), LinkState.reconnecting);
      expect(linkStateFor(SessionStatus.connected, wasConnected: false), LinkState.connected);
      expect(linkStateFor(SessionStatus.error, wasConnected: true), LinkState.error);
      expect(linkStateFor(SessionStatus.disconnected, wasConnected: false), LinkState.offline);
    });

    // iter6 QA: after a failed voice session (HTTP 429) the composer still
    // said "Connecting…" under the "Voice session failed" banner.
    test('composer placeholder says offline after a failure, not connecting', () {
      expect(composerDisabledHint(SessionStatus.connecting), 'Connecting…');
      expect(composerDisabledHint(SessionStatus.error), startsWith('Offline'));
    });

    testWidgets('disabled composer shows its disabled hint', (tester) async {
      await tester.pumpWidget(_app(Composer(onSend: (_) {}, enabled: false, disabledHint: 'Offline — x')));
      expect(find.text('Offline — x'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('chip shows "model · state" and a retry when down', (tester) async {
      var retries = 0;
      Widget chip(LinkState s) => _app(
        ConnectionStatusChip(
          state: s,
          model: 'gpt-live-1.1',
          backend: BackendMode.gptLive,
          onRetry: () => retries++,
        ),
      );
      await tester.pumpWidget(chip(LinkState.connected));
      expect(find.textContaining('gpt-live-1.1'), findsOneWidget);
      expect(find.textContaining('connected'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);

      await tester.pumpWidget(chip(LinkState.error));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
      expect(find.bySemanticsLabel(RegExp('Connection: gpt-live-1.1')), findsOneWidget);
    });
  });

  testWidgets('empty state chips send their prompt and meet touch size', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_app(EmptyState(subtitle: 'Just talk', onHint: sent.add)));
    await tester.pumpAndSettle();
    expect(find.text('How can I help?'), findsOneWidget);
    for (final label in ['Click the browser', 'Run ls', 'Show me a file']) {
      expect(find.text('"$label"'), findsOneWidget);
    }
    final chip = find.bySemanticsLabel('Suggestion: Run ls');
    expect(chip, findsOneWidget);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(kTouchTarget));
    await tester.tap(find.text('"Run ls"'));
    expect(sent, ['Run ls in my home folder']);
  });

  testWidgets('empty state chips are inert while disconnected', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(_app(EmptyState(subtitle: 'x', onHint: sent.add, enabled: false)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('"Run ls"'));
    expect(sent, isEmpty);
  });

  group('tool cards', () {
    Message tool(String name, Map<String, Object?> args, Map<String, Object?>? result, {ToolStatus? status}) => Message(
      kind: MessageKind.tool,
      tool: ToolCallInfo(
        callId: 'c1',
        name: name,
        argsJson: jsonEncode(args),
        resultJson: result == null ? null : jsonEncode(result),
        status: status ?? (result == null ? ToolStatus.running : ToolStatus.success),
      ),
      createdAt: DateTime(2020),
    );

    testWidgets('bash card expands to terminal output with exit code', (tester) async {
      final m = tool('run_bash', {'command': 'ls -la'}, {
        'ok': true,
        'exit_code': 0,
        'stdout': 'file_a\nfile_b\n',
        'stderr': '',
        'ms': 12,
      });
      await tester.pumpWidget(_app(ToolCallCard(message: m)));
      expect(find.text('Shell command'), findsOneWidget);
      expect(find.text('ls -la'), findsOneWidget);
      expect(find.text('done'), findsOneWidget);
      expect(find.textContaining('file_a'), findsNothing);
      await tester.tap(find.text('Shell command'));
      await tester.pumpAndSettle();
      expect(find.textContaining('file_a'), findsOneWidget);
      expect(find.text('exit 0'), findsOneWidget);
    });

    testWidgets('status change animates from running to failed', (tester) async {
      final m = tool('read_file', {'path': '/etc/x'}, null);
      await tester.pumpWidget(_app(ToolCallCard(key: const ValueKey('t'), message: m)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      m.tool!
        ..status = ToolStatus.error
        ..resultJson = jsonEncode({'error': 'no such file'});
      await tester.pumpWidget(_app(ToolCallCard(key: const ValueKey('t'), message: m)));
      await tester.pumpAndSettle();
      expect(find.text('failed'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('click card marks the click on the prior screenshot', (tester) async {
      final viewer = FakeViewer();
      final m = tool('click_screen', {'x': 120, 'y': 80, 'button': 'left'}, {'ok': true, 'screen_xy': '240,160'});
      const shot = ImageAttachment(path: '/nope.png', width: 640, height: 360, originalWidth: 1280, originalHeight: 720);
      await tester.pumpWidget(_app(ToolCallCard(message: m, screenshot: shot, viewer: viewer, initiallyExpanded: true)));
      await tester.pump();
      expect(find.text('(120, 80)'), findsOneWidget);
      expect(find.byType(ClickMarker), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Screenshot with click at 120, 80')), findsOneWidget);
    });
  });

  testWidgets('voice placeholders render as a voice message', (tester) async {
    final fake = FakeAudioIO();
    final m = Message(
      kind: MessageKind.user,
      text: '[2.6 s of speech]',
      audio: const AudioClip(path: '/x.wav', durationMs: 2600),
      createdAt: DateTime(2020),
    );
    await tester.pumpWidget(_app(MessageTile(message: m, audio: fake, viewer: FakeViewer())));
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('[2.6 s of speech]'), findsNothing);
    expect(isSpeechPlaceholder('[12 s of speech]'), isTrue);
    expect(isSpeechPlaceholder('hello [2 s of speech]'), isFalse);
  });

  test('compact labels', () {
    expect(shortModelName('gpt-live-1.1'), 'live-1.1');
    expect(shortModelName('gpt-realtime'), 'realtime');
    expect(
      humanizeTokenCounts('Context compacted: 46212 → 2100 tokens (3 messages summarised)'),
      'Context compacted: 46.2k → 2.1k tokens (3 messages summarised)',
    );
  });

  test('wavPeaks reads 16-bit PCM', () {
    const rate = 8000;
    final samples = List<int>.generate(rate, (i) => i < rate ~/ 2 ? 0 : (i.isEven ? 16000 : -16000));
    final data = BytesBuilder();
    void u32(int v) => data.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
    void u16(int v) => data.add([v & 255, (v >> 8) & 255]);
    data.add(ascii.encode('RIFF'));
    u32(36 + samples.length * 2);
    data.add(ascii.encode('WAVEfmt '));
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    data.add(ascii.encode('data'));
    u32(samples.length * 2);
    for (final s in samples) {
      u16(s & 0xFFFF);
    }
    final r = wavPeaks(data.toBytes(), buckets: 10)!;
    expect(r.duration, const Duration(seconds: 1));
    expect(r.peaks.take(5).every((p) => p == 0), isTrue);
    expect(r.peaks.skip(5).every((p) => p > 0.9), isTrue);
    expect(wavPeaks(Uint8List.fromList(List.filled(100, 1))), isNull);
  });
}
