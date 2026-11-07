import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/core/voice/backend_factory.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/ui/notes/note_editor.dart';
import 'package:woi/ui/notes/note_tabs.dart';
import 'package:woi/ui/screens/home_screen.dart';
import 'package:woi/ui/screens/settings_screen.dart';
import 'package:woi/ui/login/login_screen.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/tab_strip.dart';
import 'package:woi/ui/widgets/voice_status.dart';
import 'package:woi/ui/widgets/input_bar.dart';

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

  Future<void> start(WidgetTester t, {AppSettings? savedSettings}) async {
    await t.runAsync(() async {
      fp = await FakePlatform.create();
      if (savedSettings != null) await SettingsStore(fp.services.paths.settingsFile).save(savedSettings);
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
        'voice-status-button',
        'context-indicator',
        'composer-controls',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      // The status lives inside the input bar.
      final bar = find.byKey(const ValueKey('input-bar'));
      for (final k in ['voice-status-button', 'context-indicator', 'mic-button', 'send']) {
        expect(
          find.descendant(of: bar, matching: find.byKey(ValueKey(k))),
          findsOneWidget,
          reason: k,
        );
      }
      expect(find.descendant(of: bar, matching: find.textContaining('gpt-live')), findsNothing);
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
      await t.tap(find.byKey(const ValueKey('mic-button')));
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.muted);

      // Tapping the meter shows the breakdown.
      await t.tap(find.byKey(const ValueKey('context-indicator')));
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
      expect(t.widget<VoiceStatusButton>(find.byType(VoiceStatusButton)).mode, VoiceMode.compacting);
      gated.gate.completeError(Exception('Responses API error 429: The usage limit has been reached'));
      await _settle(t);
      expect(env.c.contextManager.compressing, isFalse);
      expect(t.widget<VoiceStatusButton>(find.byType(VoiceStatusButton)).mode, isNot(VoiceMode.compacting));
      await env.stop(t);
    });

    testWidgets('saved legacy PTT starts visibly off and one mic tap enables listening', (t) async {
      final env = _Env();
      await env.start(t, savedSettings: AppSettings.fromJson({'micMode': 'pushToTalk'}));
      await _pumpHome(t, env.c, const Size(400, 860));
      expect(env.c.settings.micMode, MicMode.pushToTalk);
      expect(t.widget<VoiceStatusButton>(find.byType(VoiceStatusButton)).mode, VoiceMode.idle);
      final mic = find.byKey(const ValueKey('mic-button'));
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic_off_rounded)), findsOneWidget);
      await t.tap(mic);
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.handsFree);
      expect(t.widget<VoiceStatusButton>(find.byType(VoiceStatusButton)).mode, VoiceMode.listening);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic_rounded)), findsOneWidget);
      expect(t.takeException(), isNull);
      await env.stop(t);
    });

    testWidgets('phone: compact controls keep 48dp targets and tap toggles microphone', (t) async {
      final env = _Env();
      await env.start(t);
      await _pumpHome(t, env.c, const Size(400, 860));
      expect(find.byKey(const ValueKey('mic-mode-menu')), findsNothing);
      expect(find.byKey(const ValueKey('split-toggle')), findsNothing);
      for (final k in ['voice-status-button', 'mic-button', 'note-new', 'note-tab-more', 'context-indicator', 'send']) {
        final f = find.byKey(ValueKey(k));
        final size = t.getSize(f);
        expect(size.height, greaterThanOrEqualTo(kTouchTarget), reason: k);
        expect(size.width, greaterThanOrEqualTo(kTouchTarget), reason: k);
      }
      await t.tap(find.byKey(const ValueKey('mic-button')));
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.muted);
      await t.tap(find.byKey(const ValueKey('mic-button')));
      await _settle(t);
      expect(env.c.settings.micMode, MicMode.handsFree);
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
        // Icons share one bottom row, with send at the far right.
        final status = find.byKey(const ValueKey('voice-status-button'));
        final mic = find.byKey(const ValueKey('mic-button'));
        final send = find.byKey(const ValueKey('send'));
        final field = find.byKey(const ValueKey('composer-field'));
        expect(find.byKey(const ValueKey('voice-label')), findsNothing);
        expect(find.byKey(const ValueKey('connection-status')), findsNothing);
        expect(t.getCenter(status).dy, closeTo(t.getCenter(send).dy, 1));
        expect(t.getCenter(mic).dy, closeTo(t.getCenter(send).dy, 1));
        expect(t.getTopLeft(send).dx, greaterThan(t.getTopLeft(mic).dx));
        expect(t.getBottomLeft(field).dy, lessThanOrEqualTo(t.getTopLeft(send).dy));
        expect(find.textContaining('gpt-live'), findsNothing);
        expect(find.byType(VoiceStatusButton), findsOneWidget);
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
      expect(find.byKey(const ValueKey('settings-group-connection')), findsOneWidget);
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

    Future<void> choose(WidgetTester t, String id, String label) async {
      final field = find.byKey(ValueKey('select-$id'));
      await _showInSettings(t, field);
      await t.tap(field);
      await _settle(t);
      await t.tap(find.text(label).hitTestable().last);
      await _settle(t);
    }

    Future<void> search(WidgetTester t, String query) async {
      await t.enterText(find.byKey(const ValueKey('settings-search')), query);
      await _settle(t);
    }

    testWidgets('backend and audio choices preserve saved models and compatible voices', (t) async {
      GptLiveHook.register((_) => ScriptedBackend());
      addTearDown(GptLiveHook.unregister);
      final env = _Env();
      await env.start(
        t,
        savedSettings: const AppSettings(
          backendMode: BackendMode.apiKey,
          apiKey: 'qa-only-key',
          realtimeModel: 'custom-realtime-id',
          voice: 'echo',
          liveVoice: 'maple',
          micMode: MicMode.muted,
        ),
      );
      await pumpSettings(t, env, const Size(1000, 1000));
      expect(find.byKey(const ValueKey('codex-login-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('setting-api-key')), findsOneWidget);
      final live = find.byKey(const ValueKey('radio-audio-model-gpt-live-1.1'));
      await _showInSettings(t, live);
      expect(t.widget<InkWell>(live).onTap, isNull);
      expect(find.text('API uses realtime audio models. gpt-live requires Codex login.'), findsWidgets);

      await _tapInSettings(t, find.byKey(const ValueKey('radio-backend-codex')));
      expect(env.c.settings.backendMode, BackendMode.direct);
      expect(env.c.settings.realtimeModel, 'custom-realtime-id');
      final audio = find.byKey(const ValueKey('select-audio-model'));
      await _showInSettings(t, audio);
      expect(t.widget<DropdownButton<(AudioModelFamily, String)>>(audio).value, (
        AudioModelFamily.realtime,
        'custom-realtime-id',
      ));
      await _tapInSettings(t, live);
      expect(env.c.settings.backendMode, BackendMode.gptLive);
      expect(env.c.settings.liveVoice, 'maple');
      final marin = find.byKey(const ValueKey('radio-voice-marin'));
      await _showInSettings(t, marin);
      expect(t.widget<InkWell>(marin).onTap, isNull);
      expect(env.c.settings.voice, 'echo');
      await choose(t, 'voice', 'Cove');
      expect(env.c.settings.liveVoice, 'cove');
      expect(env.c.settings.voiceModel, 'gpt-live-1.1');
      expect(env.c.settings.backendMode, BackendMode.gptLive);
      await _tapInSettings(t, find.byKey(const ValueKey('radio-audio-model-gpt-realtime-2.1')));
      await _tapInSettings(t, find.byKey(const ValueKey('radio-voice-marin')));
      expect(env.c.settings.backendMode, BackendMode.direct);
      expect(env.c.settings.realtimeModel, 'gpt-realtime-2.1');
      expect(env.c.settings.voice, 'marin');
      expect(env.c.settings.liveVoice, 'cove');
      final saved = await t.runAsync(() => SettingsStore(env.fp.services.paths.settingsFile).load());
      expect(saved!.toJson(), env.c.settings.toJson());
      expect(t.takeException(), isNull);
      await env.stop(t);
    });

    testWidgets('custom text and compression model edits persist independently', (t) async {
      final env = _Env();
      await env.start(t);
      await pumpSettings(t, env, const Size(1000, 900));
      await search(t, 'delegated');
      await choose(t, 'delegate-model', 'Custom model…');
      await t.enterText(find.byKey(const ValueKey('custom-delegate-model')), 'private-reasoner-v2');
      await t.pump(const Duration(milliseconds: 701));
      await _settle(t);
      expect(env.c.settings.delegateModel, 'private-reasoner-v2');
      expect(env.c.settings.compressionModel, 'gpt-6-luna');
      await search(t, 'Compression model');
      await choose(t, 'compression-model', 'Custom model…');
      await t.enterText(find.byKey(const ValueKey('custom-compression-model')), 'private-compactor-v3');
      await t.pump(const Duration(milliseconds: 701));
      await _settle(t);
      expect(env.c.settings.delegateModel, 'private-reasoner-v2');
      expect(env.c.settings.compressionModel, 'private-compactor-v3');
      await t.pumpWidget(const SizedBox());
      await _settle(t);
      final saved = await t.runAsync(() => SettingsStore(env.fp.services.paths.settingsFile).load());
      expect(saved!.delegateModel, 'private-reasoner-v2');
      expect(saved.compressionModel, 'private-compactor-v3');
      await env.stop(t);
    });

    testWidgets('one Advanced fold keeps tuning reachable and search opens only matching rows', (t) async {
      final env = _Env();
      await env.start(t);
      await pumpSettings(t, env, const Size(1000, 900));
      for (final id in ['connection', 'model', 'preferences']) {
        await _showInSettings(t, find.byKey(ValueKey('settings-group-$id')));
      }
      final advanced = find.byKey(const ValueKey('advanced-settings'));
      await _showInSettings(t, advanced);
      expect(advanced, findsOneWidget);
      expect(find.byKey(const ValueKey('setting-workspace')), findsNothing);
      expect(find.byKey(const ValueKey('settings-group-android')), findsNothing);
      await _tapInSettings(t, advanced);
      await _showInSettings(t, find.byKey(const ValueKey('setting-workspace')));
      expect(find.byKey(const ValueKey('setting-workspace')), findsOneWidget);
      await _tapInSettings(t, advanced);
      expect(find.byKey(const ValueKey('setting-workspace')), findsNothing);
      await search(t, 'stop word');
      expect(find.text('Stop word detection'), findsOneWidget);
      expect(find.byKey(const ValueKey('setting-stop-words')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-group-connection')), findsNothing);
      expect(advanced, findsOneWidget);
      await search(t, 'workspace');
      expect(find.byKey(const ValueKey('setting-workspace')), findsOneWidget);
      await search(t, 'delegated');
      expect(find.byKey(const ValueKey('select-delegate-model')), findsOneWidget);
      expect(advanced, findsNothing);
      await search(t, 'zzzz');
      expect(find.textContaining('No settings match'), findsOneWidget);
      await search(t, '');
      expect(find.byKey(const ValueKey('setting-workspace')), findsNothing);
      await env.stop(t);
    });

    testWidgets('effective text model and full usage reason update while Advanced is closed', (t) async {
      final env = _Env();
      await env.start(t, savedSettings: const AppSettings(delegateModel: 'gpt-6.1-sol'));
      await pumpSettings(t, env, const Size(1000, 1000));
      await _showInSettings(t, find.byKey(const ValueKey('select-delegate-model')));
      expect(find.byKey(const ValueKey('effective-text-model')), findsNothing);
      env.c.usage.updateFromHeaders({'x-codex-primary-used-percent': '90', 'x-codex-primary-window-minutes': '300'});
      await t.pump();
      expect(find.text('Active text model: gpt-6-luna'), findsOneWidget);
      expect(
        find.text('5h usage window has 10% left (< 20%): using gpt-6-luna instead of gpt-6.1-sol'),
        findsOneWidget,
      );
      expect(env.c.settings.delegateModel, 'gpt-6.1-sol');
      expect(find.byKey(const ValueKey('settings-group-diagnostics')), findsNothing);
      env.c.usage.updateFromHeaders({'x-codex-primary-used-percent': '30', 'x-codex-primary-window-minutes': '300'});
      await t.pump();
      expect(find.byKey(const ValueKey('effective-text-model')), findsNothing);
      await env.stop(t);
    });

    testWidgets('pending model draft and caret survive auth notifications and unrelated external settings', (t) async {
      final env = _Env();
      await env.start(t, savedSettings: const AppSettings(delegateModel: 'stored-custom-model'));
      await pumpSettings(t, env, const Size(1000, 900));
      await search(t, 'delegated');
      final field = find.byKey(const ValueKey('custom-delegate-model'));
      await t.enterText(field, 'pending-custom-model');
      final editor = t.widget<TextField>(field).controller!;
      editor.selection = const TextSelection.collapsed(offset: 7);
      await t.runAsync(
        () => env.c.updateSettings(env.c.settings.copyWith(theme: AppTheme.dark, confirmBeforeBash: false)),
      );
      await t.runAsync(env.c.refreshCodexAuth);
      env.c.usage.debugSet(null);
      await t.pump();
      expect(editor.text, 'pending-custom-model');
      expect(editor.selection, const TextSelection.collapsed(offset: 7));
      expect(env.c.settings.delegateModel, 'stored-custom-model');
      await t.pump(const Duration(milliseconds: 699));
      expect(env.c.settings.delegateModel, 'stored-custom-model');
      await t.pump(const Duration(milliseconds: 1));
      expect(env.c.settings.delegateModel, 'pending-custom-model');
      expect(env.c.settings.theme, AppTheme.dark);
      expect(env.c.settings.confirmBeforeBash, isFalse);
      expect(editor.selection, const TextSelection.collapsed(offset: 7));
      await _settle(t);
      final saved = await t.runAsync(() => SettingsStore(env.fp.services.paths.settingsFile).load());
      expect(saved!.delegateModel, 'pending-custom-model');
      expect(saved.theme, AppTheme.dark);
      await env.stop(t);
    });

    testWidgets('leaving Settings flushes a pending API key without losing an external backend change', (t) async {
      final env = _Env();
      await env.start(
        t,
        savedSettings: const AppSettings(backendMode: BackendMode.direct, apiKey: 'old-qa-key'),
      );
      await pumpSettings(t, env, const Size(1000, 900));
      final field = find.byKey(const ValueKey('setting-api-key'));
      await t.enterText(field, '  new-qa-key  ');
      await t.runAsync(() => env.c.updateSettings(env.c.settings.copyWith(backendMode: BackendMode.apiKey)));
      await t.pump();
      expect(t.widget<TextField>(field).controller!.text, '  new-qa-key  ');
      expect(env.c.settings.apiKey, 'old-qa-key');
      await t.pumpWidget(const SizedBox());
      expect(env.c.settings.apiKey, 'new-qa-key');
      expect(env.c.settings.backendMode, BackendMode.apiKey);
      await _settle(t);
      final saved = await t.runAsync(() => SettingsStore(env.fp.services.paths.settingsFile).load());
      expect(saved!.apiKey, 'new-qa-key');
      expect(saved.backendMode, BackendMode.apiKey);
      await env.stop(t);
    });

    testWidgets('selected model dropdown remains a full touch target on narrow and desktop layouts', (t) async {
      final env = _Env();
      await env.start(t);
      for (final size in [const Size(360, 740), const Size(1000, 900)]) {
        await pumpSettings(t, env, size);
        await search(t, 'delegated');
        final button = find.byKey(const ValueKey('select-delegate-model'));
        await _showInSettings(t, button);
        final bounds = t.getRect(button);
        expect(
          bounds.height,
          greaterThanOrEqualTo(kTouchTarget),
          reason: 'actual dropdown hit area at ${size.width}px',
        );
        // A decorated box can be tall while its child button stays too small.
        // The lower edge must actually open a menu and accept a new selection.
        await t.tapAt(Offset(bounds.center.dx, bounds.bottom - 2));
        await _settle(t);
        expect(find.text('Custom model…').hitTestable(), findsOneWidget);
        final selected = size.width < 600 ? 'gpt-6.1-sol' : 'gpt-6-luna';
        await t.tap(find.text(selected).hitTestable().last);
        await _settle(t);
        expect(env.c.settings.delegateModel, selected);
        expect(t.takeException(), isNull);
      }
      await env.stop(t);
    });

    testWidgets('Codex sign-in can be dismissed by Back or Escape without changing settings', (t) async {
      final env = _Env();
      await env.start(
        t,
        savedSettings: const AppSettings(backendMode: BackendMode.apiKey, realtimeModel: 'saved-audio'),
      );
      await pumpSettings(t, env, const Size(1000, 900));
      final before = env.c.settings.toJson();
      await t.tap(find.text('Sign in'));
      await _settle(t);
      expect(find.byType(LoginScreen), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await _settle(t);
      expect(find.byType(LoginScreen), findsNothing);
      await t.tap(find.text('Sign in'));
      await _settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(find.byType(LoginScreen), findsNothing);
      expect(env.c.settings.toJson(), before);
      expect(t.takeException(), isNull);
      await env.stop(t);
    });

    testWidgets('narrow settings preserve long custom values and reach Advanced controls without overflow', (t) async {
      GptLiveHook.register((_) => ScriptedBackend());
      addTearDown(GptLiveHook.unregister);
      const liveModel = 'private-audio-model-with-a-long-customer-specific-release-identifier-2026-11';
      const realtimeModel = 'another-private-realtime-model-with-a-long-release-identifier-2026-11';
      const unknownVoice = 'preserved-legacy-voice-with-a-long-identifier';
      final env = _Env();
      await env.start(
        t,
        savedSettings: const AppSettings(
          voiceModel: liveModel,
          realtimeModel: realtimeModel,
          liveVoice: unknownVoice,
          delegateModel: 'private-reasoning-model-with-a-long-release-identifier-2026-11',
          compressionModel: 'private-compression-model-with-a-long-release-identifier-2026-11',
        ),
      );
      await pumpSettings(t, env, const Size(360, 740));
      final audio = find.byKey(const ValueKey('select-audio-model'));
      await _showInSettings(t, audio);
      expect(t.widget<DropdownButton<(AudioModelFamily, String)>>(audio).value, (AudioModelFamily.live, liveModel));
      await t.tap(audio);
      await _settle(t);
      expect(t.takeException(), isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      final voice = find.byKey(const ValueKey('select-voice'));
      await _showInSettings(t, voice);
      expect(t.widget<DropdownButton<String>>(voice).value, unknownVoice);
      await t.tap(voice);
      await _settle(t);
      expect(t.takeException(), isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      for (final query in ['Compression model', 'Screenshot tiers', 'workspace']) {
        await search(t, query);
        expect(t.takeException(), isNull, reason: query);
      }
      await t.enterText(find.byKey(const ValueKey('setting-workspace')), ' /qa/custom/project ');
      await t.pumpWidget(const SizedBox());
      expect(env.c.settings.workspaceDir, '/qa/custom/project');
      expect(env.c.settings.voiceModel, liveModel);
      expect(env.c.settings.realtimeModel, realtimeModel);
      expect(env.c.settings.liveVoice, unknownVoice);
      await _settle(t);
      await pumpSettings(t, env, const Size(600, 740));
      await _tapInSettings(t, find.byKey(const ValueKey('advanced-settings')));
      await _showInSettings(t, find.byKey(const ValueKey('run-in-terminal-switch')));
      expect(t.takeException(), isNull);
      await _showInSettings(t, find.byKey(const ValueKey('settings-shortcuts')));
      expect(t.takeException(), isNull);
      await env.stop(t);
    });
  });
}

/// The settings list (the search field above it has a Scrollable too).
final _settingsList = find
    .descendant(of: find.byKey(const ValueKey('settings-list')), matching: find.byType(Scrollable))
    .first;

Future<void> _showInSettings(WidgetTester t, Finder f) async {
  t.state<ScrollableState>(_settingsList).position.jumpTo(0);
  await t.pump();
  await t.scrollUntilVisible(f, 200, scrollable: _settingsList);
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await t.pump();
}

Future<void> _tapInSettings(WidgetTester t, Finder f) async {
  await _showInSettings(t, f);
  await t.tap(f);
  await _settle(t);
}
