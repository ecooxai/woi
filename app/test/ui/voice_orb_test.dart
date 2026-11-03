import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/voice_orb.dart';

void main() {
  group('orbModeFor', () {
    test('session status wins over phase', () {
      expect(orbModeFor(AssistantPhase.listening, status: SessionStatus.connecting), OrbMode.connecting);
      expect(orbModeFor(AssistantPhase.listening, status: SessionStatus.error), OrbMode.offline);
      expect(orbModeFor(AssistantPhase.speaking, status: SessionStatus.disconnected), OrbMode.offline);
    });

    test('maps every phase to a distinct visual state', () {
      expect(orbModeFor(AssistantPhase.idle), OrbMode.idle);
      expect(orbModeFor(AssistantPhase.listening), OrbMode.listening);
      expect(orbModeFor(AssistantPhase.userSpeaking), OrbMode.hearing);
      expect(orbModeFor(AssistantPhase.thinking), OrbMode.thinking);
      expect(orbModeFor(AssistantPhase.toolRunning), OrbMode.tool);
      expect(orbModeFor(AssistantPhase.speaking), OrbMode.speaking);
      expect(orbModeFor(AssistantPhase.offline), OrbMode.offline);
    });

    test('compacting shows unless someone is talking', () {
      expect(orbModeFor(AssistantPhase.listening, compacting: true), OrbMode.compacting);
      expect(orbModeFor(AssistantPhase.thinking, compacting: true), OrbMode.thinking);
      expect(orbModeFor(AssistantPhase.toolRunning, compacting: true), OrbMode.tool);
      expect(orbModeFor(AssistantPhase.speaking, compacting: true), OrbMode.speaking);
      expect(orbModeFor(AssistantPhase.userSpeaking, compacting: true), OrbMode.hearing);
    });

    test('labels and colours differ per state', () {
      final labels = OrbMode.values.map(orbModeLabel).toSet();
      expect(labels.length, OrbMode.values.length);
      expect(orbModeColor(OrbMode.speaking), isNot(orbModeColor(OrbMode.listening)));
      expect(orbModeColor(OrbMode.tool), isNot(orbModeColor(OrbMode.thinking)));
    });
  });

  testWidgets('animates through every mode without errors and with a live label', (tester) async {
    final mic = ValueNotifier(0.0);
    final out = ValueNotifier(0.0);
    Widget host(OrbMode m) => MaterialApp(
      theme: buildWoiTheme(),
      home: Center(child: VoiceOrb(mode: m, micLevel: mic, outputLevel: out, size: 220)),
    );
    for (final m in OrbMode.values) {
      await tester.pumpWidget(host(m));
      for (var i = 0; i < 40; i++) {
        mic.value = (i % 10) / 10;
        out.value = ((i + 5) % 10) / 10;
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(tester.takeException(), isNull, reason: 'mode $m');
      expect(find.bySemanticsLabel('Woi status: ${orbModeLabel(m)}'), findsOneWidget);
    }
    // Let ripples and history wrap around for a while.
    await tester.pumpWidget(host(OrbMode.speaking));
    for (var i = 0; i < 120; i++) {
      out.value = i.isEven ? 1 : 0.2;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('static (animate: false) orb still switches mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: VoiceOrb(mode: OrbMode.idle, animate: false)));
    await tester.pumpWidget(const MaterialApp(home: VoiceOrb(mode: OrbMode.tool, animate: false)));
    await tester.pump();
    expect(find.bySemanticsLabel('Woi status: Working…'), findsOneWidget);
  });
}
