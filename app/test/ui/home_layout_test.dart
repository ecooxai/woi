import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/ui/notes/note_editor.dart';
import 'package:woi/ui/notes/note_tabs.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/screens/settings_screen.dart';
import 'package:woi/ui/widgets/glass.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/tab_strip.dart';
import 'package:woi/ui/widgets/voice_status.dart';

import '../fakes/fakes.dart';

class _GateCompressor implements Compressor {
  final gate = Completer<CompressionResult>();
  @override
  Future<CompressionResult> compress(List<Message> messages, {required String model, String? previousSummary}) =>
      gate.future;
}

class _Env {
  late FakePlatform fp;
  late AppController c;
  ScriptedBackend? backend;
  Compressor? compressor;

  Future<void> start(WidgetTester t) async {
    await t.runAsync(() async {
      fp = await FakePlatform.create();
      c = AppController(
        platform: fp.services,
        confirmations: FakeConfirmations(),
        backendFactory: () => backend = ScriptedBackend(),
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
        compressor: compressor,
      );
      await c.init();
    });
    expect(c.initError, isNull);
  }

  /// Saves [n] note-only conversations ("Note 1".."Note n", oldest first)
  /// and ends on a fresh, empty one.
  Future<void> seedNotes(WidgetTester t, int n) async {
    await t.runAsync(() async {
      for (var i = 1; i <= n; i++) {
        c.notes.setText('# Note $i\n\nbody $i\n');
        await c.notes.flush();
        await c.history.flush(c.pipeline.conversation);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await c.newConversation();
      }
    });
  }

  Future<void> stop(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await c.shutdown();
      await fp.dispose();
    });
    await t.pump(const Duration(seconds: 5));
  }
}

/// Lets real file IO (history, notes, settings) progress: each IO hop
/// completes in real time and continues on the next fake-time pump.
Future<void> _settle(WidgetTester t, [int ms = 300]) async {
  for (var i = 0; i < ms ~/ 15; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpHome(WidgetTester t, AppController c, Size size) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  // Pumped in the real zone so the note tabs' history read (file IO)
  // completes.
  await t.runAsync(() async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildWoiTheme(),
        home: HomeScreen(controller: c),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await _settle(t);
}

/// Taps in the real zone so file IO started by the tap completes.
Future<void> _tapIo(WidgetTester t, Finder f) async {
  await t.runAsync(() async {
    await t.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await _settle(t);
}

Finder _tabs() => find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('note-tab-') && k.value != 'note-tab-more';
});

ConversationSummary _sum(String id, int minutesAgo) => ConversationSummary(
  id: id,
  title: 'T $id',
  updatedAt: DateTime(2026, 11, 3, 12).subtract(Duration(minutes: minutesAgo)),
  messageCount: 0,
);

/// Full diagnostics of a caught layout error (null when there was none).
String? _err(Object? e) => e == null ? null : (e is FlutterError ? e.toStringDeep() : '$e');

void main() {
  group('note tabs model', () {
    test('four most recent; the rest go to More', () {
      final all = [for (var i = 0; i < 7; i++) _sum('n$i', i)];
      final (tabs, rest) = splitNoteTabs(all, currentId: 'n0', currentTitle: 'Current');
      expect(tabs.map((t) => t.id), ['n0', 'n1', 'n2', 'n3']);
      expect(tabs.first.title, 'Current');
      expect(tabs.first.current, isTrue);
      expect(rest.map((t) => t.id), ['n4', 'n5', 'n6']);
    });

    test('an older current note replaces the last tab; an unsaved one comes first', () {
      final all = [for (var i = 0; i < 6; i++) _sum('n$i', i)];
      var (tabs, rest) = splitNoteTabs(all, currentId: 'n5', currentTitle: 'Old');
      expect(tabs.map((t) => t.id), ['n0', 'n1', 'n2', 'n5']);
      expect(rest.map((t) => t.id), ['n3', 'n4']);

      (tabs, rest) = splitNoteTabs(all, currentId: 'new', currentTitle: 'New note');
      expect(tabs.map((t) => t.id), ['new', 'n0', 'n1', 'n2']);
      expect(rest, hasLength(3));
    });
  });

  group('Run text', () {
    test('selection wins, else the cursor line, trimmed', () {
      const text = '# Plan\n  ls -la  \n\nlast';
      expect(runTextFor(const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: 10))), 'ls -la');
      expect(
        runTextFor(const TextEditingValue(text: text, selection: TextSelection(baseOffset: 2, extentOffset: 6))),
        'Plan',
      );
      expect(
        runTextFor(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        ),
        'last',
      );
      expect(runTextFor(const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: 18))), '');
    });
  });

  group('HomeScreen layout', () {
    testWidgets('minimal header and an input bar with the status row', (t) async {
      final env = _Env();
      await env.start(t);
      await _pumpHome(t, env.c, const Size(1400, 900));

      for (final k in [
        'view-note',
        'view-terminal',
        'view-settings',
        'pane-divider',
        'chat-pane',
        'open-history',
        'input-bar',
        'composer-field',
        'mic-button',
        'voice-indicator',
        'voice-label',
        'connection-status',
        'context-compact',
        'mic-mode-handsFree',
        'mic-mode-pushToTalk',
        'mic-mode-muted',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      // The status lives inside the input bar.
      final bar = find.byKey(const ValueKey('input-bar'));
      for (final k in ['voice-indicator', 'connection-status', 'context-compact', 'mic-mode-muted']) {
        expect(
          find.descendant(of: bar, matching: find.byKey(ValueKey(k))),
          findsOneWidget,
          reason: k,
        );
      }
      expect(find.textContaining('gpt-live-1.1'), findsOneWidget);
      // No "Woi" title: the tabs start at the left edge, in order.
      expect(find.text('Woi'), findsNothing);
      // Wide: no Chat tab (the chat is docked on the right).
      final xs = [
        for (final v in HomeView.values)
          if (v != HomeView.chat) t.getTopLeft(find.byKey(ValueKey('view-${v.name}'))).dx,
      ];
      expect(xs.first, lessThan(24));
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      for (final l in ['Note', 'Terminal', 'Settings']) {
        expect(
          find.descendant(of: find.byType(HomeTabs), matching: find.text(l)),
          findsOneWidget,
          reason: l,
        );
      }

      // Mic mode toggle changes the setting.
      await t.tap(find.byKey(const ValueKey('mic-mode-muted')));
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.muted);

      // Tapping the meter shows the breakdown.
      await t.tap(find.byKey(const ValueKey('context-compact')));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Compact now'), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump(const Duration(milliseconds: 500));

      await env.stop(t);
    });

    testWidgets('"Compacting memory…" ends with the compaction (no endless animation)', (t) async {
      final gated = _GateCompressor();
      final env = _Env()..compressor = gated;
      await env.start(t);
      await _pumpHome(t, env.c, const Size(1400, 900));
      final conv = env.c.pipeline.conversation;
      for (var i = 0; i < 6; i++) {
        conv.add(Message(kind: MessageKind.user, text: 'q' * 800));
        conv.add(Message(kind: MessageKind.assistant, text: 'a' * 800));
      }
      env.c.compactNow();
      await t.pump(const Duration(milliseconds: 100));
      expect(env.c.contextManager.compressing, isTrue);
      expect(find.text('Compacting memory…'), findsOneWidget);
      gated.gate.completeError(Exception('Responses API error 429: The usage limit has been reached'));
      await _settle(t);
      expect(env.c.contextManager.compressing, isFalse);
      expect(find.text('Compacting memory…'), findsNothing);
      await env.stop(t);
    });

    testWidgets('phone: 48dp targets and a mic-mode menu', (t) async {
      final env = _Env();
      await env.start(t);
      await _pumpHome(t, env.c, const Size(400, 860));

      expect(find.byKey(const ValueKey('mic-mode-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('split-toggle')), findsNothing);
      for (final k in ['mic-mode-menu', 'mic-button', 'note-new', 'note-tab-more', 'context-compact']) {
        final f = find.byKey(ValueKey(k));
        final tappable = find.ancestor(of: f, matching: find.byType(GestureDetector));
        final s = t.getSize(k == 'context-compact' ? tappable.first : f);
        expect(s.height, greaterThanOrEqualTo(kTouchTarget), reason: k);
        expect(s.width, greaterThanOrEqualTo(kTouchTarget), reason: k);
      }
      await t.tap(find.byKey(const ValueKey('mic-mode-menu')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Push-to-talk').last);
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.pushToTalk);
      expect(t.takeException(), isNull);

      await env.stop(t);
    });

    for (final size in const [Size(360, 740), Size(400, 860)]) {
      testWidgets('phone ${size.width.toInt()}x${size.height.toInt()}: tab strip fits, every tab opens', (t) async {
        final env = _Env();
        await env.start(t);
        await _pumpHome(t, env.c, size);
        expect(_err(t.takeException()), isNull);
        final strip = find.byType(HomeTabs);
        expect(t.getTopLeft(strip).dx, lessThan(8));
        expect(t.getTopRight(strip).dx, lessThanOrEqualTo(size.width - kTouchTarget));
        // The status row is readable: the voice state is not ellipsized
        // (it was "Mi…"), and the longest phone label fits too; the
        // connection is a dot with the model in its tooltip.
        final label = find.byKey(const ValueKey('voice-label'));
        expect(t.renderObject<RenderParagraph>(label).didExceedMaxLines, isFalse);
        // Room for the indicator and an 11-character label in the 12 px
        // body font (~100 px; the test font's square glyphs are wider).
        final left = find.ancestor(of: label, matching: find.byType(Expanded)).first;
        final chip = find.byKey(const ValueKey('connection-status'));
        expect(t.getSize(left).width - t.getSize(chip).width, greaterThanOrEqualTo(120), reason: '${size.width} px');
        for (final m in VoiceMode.values) {
          expect(voiceModeShortLabel(m).length, lessThanOrEqualTo(11), reason: m.name);
        }
        expect(find.textContaining('realtime'), findsNothing);
        expect(find.textContaining('gpt-live'), findsNothing);
        final tip = find.ancestor(of: find.byKey(const ValueKey('connection-status')), matching: find.byType(Tooltip));
        expect(t.widget<Tooltip>(tip.first).message, contains('Model: '));
        // Only the selected tab shows its label.
        expect(find.descendant(of: strip, matching: find.text('Note')), findsOneWidget);
        expect(find.descendant(of: strip, matching: find.text('Chat')), findsNothing);
        for (final v in HomeView.values) {
          final f = find.byKey(ValueKey('view-${v.name}'));
          expect(t.getSize(f).height, greaterThanOrEqualTo(kTouchTarget), reason: v.name);
          expect(t.getSize(f).width, greaterThanOrEqualTo(kTouchTarget), reason: v.name);
        }
        for (final (v, panel) in [
          (HomeView.chat, 'chat-panel'),
          (HomeView.settings, 'settings-view'),
          (HomeView.terminal, 'terminal-view'),
          (HomeView.note, 'note-panel'),
        ]) {
          await _tapIo(t, find.byKey(ValueKey('view-${v.name}')));
          expect(env.c.actions.view.value, v);
          expect(find.byKey(ValueKey(panel)), findsOneWidget, reason: panel);
          expect(find.descendant(of: strip, matching: find.text(kHomeTabs[v]!.$2)), findsOneWidget);
          expect(_err(t.takeException()), isNull, reason: v.name);
        }
        await env.stop(t);
      });
    }

    testWidgets('Settings is a tab: Ctrl+4, Ctrl+, and voice select it, Esc goes back', (t) async {
      final env = _Env();
      await env.start(t);
      await _pumpHome(t, env.c, const Size(900, 900));
      final a = env.c.actions;
      Future<void> ctrl(LogicalKeyboardKey k) async {
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(k);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _settle(t, 150);
      }

      await ctrl(LogicalKeyboardKey.digit2);
      expect(a.view.value, HomeView.chat);
      await ctrl(LogicalKeyboardKey.digit4);
      expect(a.view.value, HomeView.settings);
      expect(find.byKey(const ValueKey('settings-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('choices-backend')), findsOneWidget);
      // Inline: no route was pushed and the input bar stays.
      expect(find.byKey(const ValueKey('input-bar')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t, 150);
      expect(a.view.value, HomeView.chat);
      await ctrl(LogicalKeyboardKey.digit3);
      expect(a.view.value, HomeView.terminal);
      await ctrl(LogicalKeyboardKey.digit1);
      expect(a.view.value, HomeView.note);
      await ctrl(LogicalKeyboardKey.comma);
      expect(a.view.value, HomeView.settings);
      // Ctrl+N from Settings starts a note and shows it (QA P3).
      await ctrl(LogicalKeyboardKey.keyN);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await _settle(t, 150);
      expect(a.view.value, HomeView.note);
      expect(find.byKey(const ValueKey('settings-view')), findsNothing);
      await ctrl(LogicalKeyboardKey.comma);
      expect(a.view.value, HomeView.settings);

      // Voice: "show chat" / "open settings" select the tabs.
      final r1 = await t.runAsync(() => env.c.tools.dispatch('app_control', '{"action":"show_view","view":"chat"}'));
      await _settle(t, 150);
      expect(r1!.json, contains('"ok":true'));
      expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
      await t.runAsync(() => env.c.tools.dispatch('app_control', '{"action":"show_view","view":"settings"}'));
      await _settle(t, 150);
      expect(find.byKey(const ValueKey('settings-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-panel')), findsNothing);
      await env.stop(t);
    });

    // Android starts the app in a bottom freeform window (100% x 70%): on a
    // MI 8 (393x817 dp) that is 393x572 dp with only the nav bar inset, and
    // the keyboard takes about half of it.
    testWidgets('phone: freeform window at 70% height, with and without the keyboard', (t) async {
      final env = _Env();
      await env.start(t);
      const dpr = 2.75;
      t.view.devicePixelRatio = dpr;
      t.view.physicalSize = const Size(393 * dpr, 572 * dpr);
      t.view.padding = const FakeViewPadding(bottom: 48 * dpr);
      t.view.viewPadding = const FakeViewPadding(bottom: 48 * dpr);
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        await t.pumpWidget(
          MaterialApp(
            theme: buildWoiTheme(),
            home: HomeScreen(controller: env.c),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await _settle(t);
      expect(t.takeException(), isNull);
      final mic = t.getRect(find.byKey(const ValueKey('mic-button')));
      expect(mic.bottom, lessThanOrEqualTo(572 - 48 + 0.5), reason: 'input bar above the nav bar');
      expect(mic.top, greaterThanOrEqualTo(0));

      // Keyboard up: ~260 dp of the 572.
      t.view.viewInsets = const FakeViewPadding(bottom: 260 * dpr);
      t.view.padding = FakeViewPadding.zero;
      await t.pump();
      await _settle(t);
      expect(t.takeException(), isNull);
      expect(t.getRect(find.byKey(const ValueKey('mic-button'))).bottom, lessThanOrEqualTo(572 - 260 + 0.5));
      // The note text keeps the room (tabs, toolbar and footer step aside).
      expect(t.getSize(find.byKey(const ValueKey('note-editor-field'))).height, greaterThan(60));

      // Maximized again (full screen with the status bar).
      t.view.viewInsets = FakeViewPadding.zero;
      t.view.physicalSize = const Size(393 * dpr, 817 * dpr);
      t.view.padding = const FakeViewPadding(top: 30 * dpr, bottom: 48 * dpr);
      await t.pump();
      await _settle(t);
      expect(t.takeException(), isNull);

      await env.stop(t);
    });

    testWidgets('note tabs, More picker with search, and New note', (t) async {
      final env = _Env();
      await env.start(t);
      await env.seedNotes(t, 6);
      await _pumpHome(t, env.c, const Size(1400, 900));

      expect(find.byKey(const ValueKey('note-panel')), findsOneWidget);
      // Current (empty) note + the 3 most recent saved ones.
      expect(_tabs(), findsNWidgets(4));
      expect(find.text('New note'), findsOneWidget);
      expect(find.text('Note 6'), findsOneWidget);
      expect(find.text('Note 1'), findsNothing);
      expect(find.text('More (3)'), findsOneWidget);

      await _tapIo(t, find.byKey(const ValueKey('note-tab-more')));
      expect(find.byKey(const ValueKey('note-more-search')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('note-more-item-'),
        ),
        findsNWidgets(3),
      );
      await t.enterText(find.byKey(const ValueKey('note-more-search')), 'note 1');
      await t.pump();
      expect(find.text('Note 1'), findsOneWidget);
      expect(find.text('Note 2'), findsNothing);
      await _tapIo(t, find.text('Note 1'));
      expect(env.c.notes.text, contains('body 1'));
      expect(find.byKey(const ValueKey('note-more-search')), findsNothing);

      // Clicking a tab opens that note.
      await _tapIo(t, find.text('Note 5'));
      expect(env.c.notes.text, contains('body 5'));

      // New note starts an empty one.
      final before = env.c.pipeline.conversation.id;
      await _tapIo(t, find.byKey(const ValueKey('note-new')));
      expect(env.c.pipeline.conversation.id, isNot(before));
      expect(env.c.notes.text, isEmpty);

      await env.stop(t);
    });

    testWidgets('Run sends the cursor line as a user turn shown in the chat', (t) async {
      final env = _Env();
      await env.start(t);
      await _pumpHome(t, env.c, const Size(900, 900));
      expect(env.c.pipeline.status, SessionStatus.connected);

      final editor = t.state<NoteEditorState>(find.byType(NoteEditor));
      env.c.notes.setText('# Plan\nlist the files in /tmp\n');
      await t.pump();
      editor.textController.selection = const TextSelection.collapsed(offset: 10);
      await t.pump();

      await t.tap(find.byKey(const ValueKey('note-run')));
      await _settle(t);
      final msgs = env.c.pipeline.conversation.messages;
      expect(msgs.last.kind, MessageKind.user);
      expect(msgs.last.text, 'list the files in /tmp');
      expect(env.backend!.texts, contains('list the files in /tmp'));

      // It is in the chat history.
      await t.tap(find.byKey(const ValueKey('view-chat')));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('list the files in /tmp'), findsOneWidget);
      // Message text is plain Text, selectable through the transcript's
      // SelectionArea (no SelectableText per bubble).
      expect(
        find.ancestor(of: find.text('list the files in /tmp'), matching: find.byType(SelectionArea)),
        findsOneWidget,
      );

      await env.stop(t);
    });
  });

  group('Settings', () {
    testWidgets('every choice is a radio list; picking one applies it', (t) async {
      final env = _Env();
      await env.start(t);
      await t.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(body: SettingsView(controller: env.c)),
        ),
      );
      await _settle(t);

      // Rare settings sit behind each group's "Advanced" expander.
      expect(find.byKey(const ValueKey('choices-compression-model')), findsNothing);
      for (final g in ['voice', 'context']) {
        final f = find.byKey(ValueKey('advanced-$g'));
        await _tapInSettings(t, f);
      }
      t.state<ScrollableState>(_settingsList).position.jumpTo(0);
      await t.pump();

      for (final id in [
        'backend',
        'voice-model',
        'realtime-model',
        'voice',
        'compression-model',
        'delegate-model',
        'theme',
      ]) {
        final group = find.byKey(ValueKey('choices-$id'));
        await t.scrollUntilVisible(group, 200, scrollable: _settingsList);
        expect(group, findsOneWidget, reason: id);
        expect(find.descendant(of: group, matching: find.byType(DropdownButtonFormField<String>)), findsNothing);
      }
      expect(find.byType(Radio<AppTheme>), findsNWidgets(3));
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('choices-backend')),
        -200,
        scrollable: _settingsList,
      );
      expect(find.byType(Radio<BackendMode>), findsNWidgets(BackendMode.values.length));

      final list = _settingsList;
      Future<void> pick(String key, {double delta = 150}) async {
        final f = find.byKey(ValueKey(key));
        await t.scrollUntilVisible(f, delta, scrollable: list);
        await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
        await t.pump();
        await t.tap(f);
        await _settle(t);
      }

      // Top to bottom, then back up.
      await t.scrollUntilVisible(find.byKey(const ValueKey('choices-backend')), -300, scrollable: list);
      await pick('radio-voice-model-gpt-live-1');
      expect(env.c.settings.voiceModel, 'gpt-live-1');
      await pick('radio-voice-maple');
      expect(env.c.settings.liveVoice, 'maple');
      await pick('radio-compression-model-gpt-6.1-sol');
      expect(env.c.settings.compressionModel, 'gpt-6.1-sol');
      await pick('radio-delegate-model-gpt-6-luna');
      expect(env.c.settings.delegateModel, 'gpt-6-luna');
      // Custom model id.
      await pick('radio-delegate-model-\u0000custom');
      expect(find.byKey(const ValueKey('custom-delegate-model')), findsOneWidget);
      await pick('radio-theme-dark');
      expect(env.c.settings.theme, AppTheme.dark);

      await pick('radio-backend-direct', delta: -150);
      expect(env.c.settings.backendMode, BackendMode.direct);
      expect(find.byKey(const ValueKey('choices-voice-model')), findsNothing);
      await pick('radio-voice-cedar', delta: -150);
      expect(env.c.settings.voice, 'cedar');

      await env.stop(t);
    });

    Future<void> pumpSettings(WidgetTester t, _Env env, Size size) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(body: SettingsView(controller: env.c)),
        ),
      );
      await _settle(t);
    }

    testWidgets('groups with headers, no cards; Advanced expands and collapses', (t) async {
      final env = _Env();
      await env.start(t);
      await pumpSettings(t, env, const Size(1000, 900));
      final list = _settingsList;
      for (final g in ['voice', 'audio', 'screen', 'context', 'editing', 'appearance', 'account', 'about']) {
        final f = find.byKey(ValueKey('settings-group-$g'));
        await t.scrollUntilVisible(f, 200, scrollable: list);
        expect(f, findsOneWidget, reason: g);
      }
      expect(find.byType(GlassPanel), findsNothing);
      // Android-only settings stay hidden on desktop.
      expect(find.byKey(const ValueKey('settings-group-android')), findsNothing);

      final adv = find.byKey(const ValueKey('advanced-editing'));
      t.state<ScrollableState>(list).position.jumpTo(0);
      await t.pump();
      expect(find.text('Workspace folder'), findsNothing);
      await _tapInSettings(t, adv);
      expect(find.text('Workspace folder'), findsWidgets);
      await _tapInSettings(t, adv);
      expect(find.text('Workspace folder'), findsNothing);
      await env.stop(t);
    });

    testWidgets('search filters rows and shows advanced matches', (t) async {
      final env = _Env();
      await env.start(t);
      await pumpSettings(t, env, const Size(1000, 900));
      await t.enterText(find.byKey(const ValueKey('settings-search')), 'delegate');
      await _settle(t);
      expect(find.byKey(const ValueKey('choices-delegate-model')), findsOneWidget);
      expect(find.byKey(const ValueKey('choices-backend')), findsNothing);
      expect(find.byKey(const ValueKey('settings-group-audio')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('settings-search')), 'stop word');
      await _settle(t);
      expect(find.text('Stop word detection'), findsOneWidget);
      expect(find.text('Stop words'), findsWidgets);
      expect(find.byKey(const ValueKey('settings-group-audio')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('settings-search')), 'zzzz');
      await _settle(t);
      expect(find.textContaining('No settings match'), findsOneWidget);
      await env.stop(t);
    });

    testWidgets('phone width: rows stack, everything expanded, no overflow', (t) async {
      final env = _Env();
      await env.start(t);
      await pumpSettings(t, env, const Size(360, 800));
      final list = _settingsList;
      for (final g in ['voice', 'screen', 'context', 'editing', 'account', 'about']) {
        await _tapInSettings(t, find.byKey(ValueKey('advanced-$g')));
        expect(t.takeException(), isNull, reason: g);
      }
      // A switch row keeps its switch on the label's line.
      final sw = find.byKey(const ValueKey('run-in-terminal-switch'));
      t.state<ScrollableState>(list).position.jumpTo(0);
      await t.pump();
      await t.scrollUntilVisible(sw, 200, scrollable: list);
      expect(t.getTopRight(sw).dx, lessThanOrEqualTo(360));
      expect(t.takeException(), isNull);
      await env.stop(t);
    });
  });
}

/// The settings list (the search field above it has a Scrollable too).
final _settingsList = find.descendant(
  of: find.byKey(const ValueKey('settings-list')),
  matching: find.byType(Scrollable),
).first;

Future<void> _tapInSettings(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 200, scrollable: _settingsList);
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await t.pump();
  await t.tap(f);
  await _settle(t);
}
