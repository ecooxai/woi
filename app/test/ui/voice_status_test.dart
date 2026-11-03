import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/voice_status.dart';

void main() {
  test('voiceModeFor maps connection, phase and compaction', () {
    expect(voiceModeFor(AssistantPhase.idle, status: SessionStatus.connecting), VoiceMode.connecting);
    expect(voiceModeFor(AssistantPhase.listening, status: SessionStatus.error), VoiceMode.offline);
    expect(voiceModeFor(AssistantPhase.listening), VoiceMode.listening);
    expect(voiceModeFor(AssistantPhase.userSpeaking), VoiceMode.hearing);
    expect(voiceModeFor(AssistantPhase.toolRunning), VoiceMode.tool);
    expect(voiceModeFor(AssistantPhase.idle, compacting: true), VoiceMode.compacting);
    // Compaction never hides speech.
    expect(voiceModeFor(AssistantPhase.speaking, compacting: true), VoiceMode.speaking);
    expect(voiceModeLabel(VoiceMode.tool), 'Running tool…');
    expect(voiceModeLabel(VoiceMode.thinking), 'Thinking…');
  });

  test('only busy modes animate; idle and offline are still', () {
    for (final m in VoiceMode.values) {
      final busy = {VoiceMode.connecting, VoiceMode.thinking, VoiceMode.tool, VoiceMode.compacting}.contains(m);
      expect(voiceModeAnimates(m), busy, reason: '$m');
    }
    expect(voiceModeShowsLevel(VoiceMode.hearing), isTrue);
    expect(voiceModeShowsLevel(VoiceMode.listening), isFalse);
    expect(voiceModeShowsLevel(VoiceMode.idle), isFalse);
  });

  testWidgets('ThrottledLevel quantizes and coalesces to ~15 Hz', (t) async {
    final src = ValueNotifier<double>(0);
    final level = ThrottledLevel(hz: 15, steps: 10);
    var notes = 0;
    level.addListener(() => notes++);
    level.source = src;

    // Noise under the floor and sub-step jitter are dropped.
    src.value = 0.02;
    src.value = 0.05;
    expect(notes, 0);

    // A burst of changes within one period: at most one now, one later.
    for (var i = 1; i <= 20; i++) {
      src.value = i / 20;
    }
    expect(notes, lessThanOrEqualTo(1));
    await t.pump(const Duration(milliseconds: 100));
    expect(notes, lessThanOrEqualTo(2));
    expect(level.value, 1.0);

    level.dispose();
    src.dispose();
  });

  final theme = buildWoiTheme();
  Future<void> pump(WidgetTester t, VoiceMode mode, {ValueListenable<double>? mic}) => t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: VoiceStatusIndicator(mode: mode, micLevel: mic)),
    ),
  );

  testWidgets('idle indicator schedules no frames; thinking pulses', (t) async {
    await pump(t, VoiceMode.idle);
    await t.pump();
    await t.binding.delayed(const Duration(seconds: 1));
    expect(find.text('Mic muted'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-indicator')), findsOneWidget);
    expect(t.binding.hasScheduledFrame, isFalse);

    await pump(t, VoiceMode.thinking);
    expect(find.text('Thinking…'), findsOneWidget);
    await t.pump();
    await t.binding.delayed(const Duration(milliseconds: 100));
    expect(t.binding.hasScheduledFrame, isTrue, reason: 'the pulse repaints');
    final sem = t.ensureSemantics();
    await t.pump();
    expect(find.bySemanticsLabel(RegExp('^Voice: Thinking')), findsOneWidget);
    sem.dispose();

    // Back to idle: the pulse stops.
    await pump(t, VoiceMode.idle);
    await t.pump();
    await t.binding.delayed(const Duration(milliseconds: 300));
    expect(t.binding.hasScheduledFrame, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('hearing shows a level waveform that follows the mic', (t) async {
    final mic = ValueNotifier<double>(0);
    await pump(t, VoiceMode.hearing, mic: mic);
    expect(find.text('Hearing you…'), findsOneWidget);
    mic.value = 0.8;
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    mic.dispose();
  });
}
