import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/delegate/delegate_backend.dart';
import 'package:woi/core/usage/codex_usage.dart';
import 'package:woi/core/usage/model_guard.dart';
import 'package:woi/ui/widgets/usage_meter.dart';

import 'fakes/fakes.dart';

class _RecordingDelegate implements DelegateBackend {
  final models = <String>[];
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    models.add(model);
    return DelegateResult(output: 'done', model: model);
  }
}

UsageSnapshot _snap(double primaryUsed, double weekUsed, {DateTime? at}) => UsageSnapshot(
  primary: UsageWindow(usedPercent: primaryUsed, windowMinutes: 300, resetsAt: DateTime(2026, 11, 4, 15, 30)),
  secondary: UsageWindow(usedPercent: weekUsed, windowMinutes: 10080, resetsAt: DateTime(2026, 11, 9, 8)),
  plan: 'plus',
  updatedAt: at ?? DateTime.now(),
  source: UsageSource.endpoint,
);

void main() {
  group('guardModel', () {
    test('keeps the selection without data or with enough left', () {
      expect(guardModel('gpt-6.1-sol', null).model, 'gpt-6.1-sol');
      final c = guardModel('gpt-6.1-sol', _snap(50, 79));
      expect(c.model, 'gpt-6.1-sol');
      expect(c.downgraded, isFalse);
      expect(c.reason, isNull);
    });

    test('either window under 20% left: gpt-6-luna, with the reason', () {
      final five = guardModel('gpt-6.1-sol', _snap(85, 10));
      expect(five.model, 'gpt-6-luna');
      expect(five.selected, 'gpt-6.1-sol');
      expect(five.downgraded, isTrue);
      expect(five.reason, '5h usage window has 15% left (< 20%): using gpt-6-luna instead of gpt-6.1-sol');
      final week = guardModel('gpt-6.1-sol', _snap(10, 95));
      expect(week.model, 'gpt-6-luna');
      expect(week.reason, startsWith('week usage window has 5% left'));
    });

    test('configurable threshold; 0 = off; luna is never "downgraded"', () {
      expect(guardModel('gpt-6.1-sol', _snap(85, 10), thresholdPercent: 10).model, 'gpt-6.1-sol');
      expect(guardModel('gpt-6.1-sol', _snap(85, 10), thresholdPercent: 50).model, 'gpt-6-luna');
      expect(guardModel('gpt-6.1-sol', _snap(99, 99), thresholdPercent: 0).model, 'gpt-6.1-sol');
      final luna = guardModel('gpt-6-luna', _snap(99, 99));
      expect(luna.downgraded, isFalse);
      expect(luna.reason, isNull);
    });

    test('a reached limit says so', () {
      final s = UsageSnapshot(
        primary: const UsageWindow(usedPercent: 50),
        limitReached: true,
        updatedAt: DateTime.now(),
        source: UsageSource.endpoint,
      );
      expect(guardModel('gpt-6.1-sol', s).reason, startsWith('ChatGPT usage limit reached'));
    });

    test('GuardedDelegate runs on the effective model and reports why', () async {
      final inner = _RecordingDelegate();
      UsageSnapshot? usage;
      final d = GuardedDelegate(inner, (m) => guardModel(m, usage));
      final ok = await d.runTask('t', model: 'gpt-6.1-sol');
      expect(inner.models.last, 'gpt-6.1-sol');
      expect(ok.toJson().containsKey('model_note'), isFalse);
      usage = _snap(90, 0);
      final low = await d.runTask('t', model: 'gpt-6.1-sol');
      expect(inner.models.last, 'gpt-6-luna');
      expect(low.toJson()['model'], 'gpt-6-luna');
      expect(low.toJson()['model_note'], contains('10% left'));
    });
  });

  group('AppController', () {
    late FakePlatform fp;
    late AppController c;
    late _RecordingDelegate delegate;
    late CodexUsage usage;

    setUp(() async {
      fp = await FakePlatform.create();
      delegate = _RecordingDelegate();
      usage = CodexUsage(credentials: () async => null);
      c = AppController(
        platform: fp.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
        delegate: delegate,
        usage: usage,
      );
      await c.init();
      await c.updateSettings(c.settings.copyWith(compressionModel: 'gpt-6.1-sol', delegateModel: 'gpt-6.1-sol'));
    });
    tearDown(() async {
      await c.shutdown();
      await fp.dispose();
    });

    List<String> notices() => [
      for (final m in c.pipeline.conversation.messages)
        if (m.meta['type'] == 'notice' && m.text.startsWith('ChatGPT usage low')) m.text,
    ];

    test('low usage: compaction and delegate_task use gpt-6-luna; one notice', () async {
      expect(usage.active, isFalse, reason: 'no Codex login: no polling');
      usage.debugSet(_snap(30, 40));
      expect(c.contextManager.compressionModel, 'gpt-6.1-sol');
      expect(c.compactionChoice.downgraded, isFalse);
      expect(notices(), isEmpty);

      usage.debugSet(_snap(85, 40));
      expect(c.contextManager.compressionModel, 'gpt-6-luna');
      expect(c.compactionChoice.reason, contains('5h usage window has 15% left'));
      expect(c.delegationChoice.model, 'gpt-6-luna');
      final r = await c.tools.dispatch('delegate_task', jsonEncode({'task': 'refactor'}));
      expect(delegate.models.last, 'gpt-6-luna');
      expect(jsonDecode(r.json)['model_note'], contains('instead of gpt-6.1-sol'));

      usage.debugSet(_snap(90, 40));
      expect(notices(), hasLength(1), reason: 'one-time');
      expect(notices().single, contains('5h window 15% left'));
      expect(notices().single, contains('Delegation and compaction now use gpt-6-luna'));

      // Back above the threshold (window reset): the selection returns, and a
      // later drop notices again.
      usage.debugSet(_snap(5, 40));
      expect(c.contextManager.compressionModel, 'gpt-6.1-sol');
      usage.debugSet(_snap(5, 95));
      expect(notices(), hasLength(2));
      expect(notices().last, contains('week window 5% left'));
    });

    test('threshold setting and the voice query', () async {
      usage.debugSet(_snap(85, 40));
      await c.actions.setSetting('usage guard', '10');
      expect(c.settings.usageGuardPercent, 10);
      expect(c.compactionChoice.model, 'gpt-6.1-sol');
      expect(c.contextManager.compressionModel, 'gpt-6.1-sol');

      final r = await c.tools.dispatch('app_control', jsonEncode({'action': 'usage'}));
      final j = jsonDecode(r.json) as Map<String, Object?>;
      expect(j['ok'], isTrue);
      expect(j['summary'], contains('5h window: 85% used, 15% left'));
      expect(j['week'], containsPair('used_percent', 40));
      expect(j['delegation_model'], 'gpt-6.1-sol');

      await c.actions.setSetting('usage_guard', '20');
      final low = jsonDecode((await c.tools.dispatch('app_control', jsonEncode({'action': 'usage'}))).json) as Map;
      expect(low['delegation_model'], 'gpt-6-luna');
      expect(low['model_note'], contains('15% left'));
    });

    test('usage query without data fails clearly', () async {
      final r = await c.tools.dispatch('app_control', jsonEncode({'action': 'usage'}));
      expect(r.json, contains('only available with a ChatGPT login'));
    });
  });

  testWidgets('CodexUsageMeter: compact line, resets and the guard reason', (t) async {
    late FakePlatform fp;
    late AppController c;
    final usage = CodexUsage(credentials: () async => null);
    await t.runAsync(() async {
      fp = await FakePlatform.create();
      c = AppController(
        platform: fp.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => ScriptedBackend(),
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
        usage: usage,
      );
      await c.init();
    });
    final now = DateTime(2026, 11, 4, 12);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 340, child: CodexUsageMeter(controller: c, now: () => now)),
        ),
      ),
    );
    expect(find.text('Only with a ChatGPT login'), findsNothing); // backend override: settings say Codex
    expect(find.text('No usage data yet'), findsOneWidget);

    usage.debugSet(_snap(34, 71, at: now));
    await t.pump();
    expect(find.text('5h 34% used · week 71% used'), findsOneWidget);
    expect(find.text('resets 15:30'), findsOneWidget);
    expect(find.text('resets Mon 08:00'), findsOneWidget);
    expect(find.byKey(const Key('usage-guard-delegation')), findsNothing);

    await t.runAsync(() => c.updateSettings(c.settings.copyWith(delegateModel: 'gpt-6.1-sol')));
    usage.debugSet(_snap(34, 85, at: now));
    await t.pump();
    expect(find.textContaining('Delegation: gpt-6-luna (week usage window has 15% left'), findsOneWidget);
    expect(find.byKey(const Key('usage-guard-compaction')), findsNothing);

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await c.shutdown();
      await fp.dispose();
    });
  });
}
