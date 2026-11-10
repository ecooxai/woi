import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/chat_draft.dart';
import 'package:woi/ui/widgets/input_bar.dart';

import '../fakes/fakes.dart';

class _PausedBackend extends ScriptedBackend {
  bool paused = false;
  @override
  bool get voiceInputNeedsReconnect => paused;
  @override
  void cancelPendingTools() => paused = true;
}

Future<void> _drain(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
}

void main() {
  testWidgets('paused connected voice offers Reconnect and preserves the exact draft and image', (tester) async {
    late FakePlatform platform;
    late AppController controller;
    final backends = <_PausedBackend>[];
    final draft = ChatDraftController();
    await tester.runAsync(() async {
      platform = await FakePlatform.create();
      await SettingsStore(platform.services.paths.settingsFile)
          .save(const AppSettings(backendMode: BackendMode.direct, micMode: MicMode.handsFree, autoScreenshot: false));
      controller = AppController(
        platform: platform.services,
        confirmations: FakeConfirmations(),
        backendFactory: () {
          final backend = _PausedBackend();
          backends.add(backend);
          return backend;
        },
        authManager: CodexAuthManager(path: '${platform.root.path}/no-auth.json'),
      );
      await controller.init();
      await waitFor(() => controller.pipeline.status == SessionStatus.connected);
    });
    try {
      draft.insertText('Keep this exact unsent question.');
      final pixels = Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3)));
      draft.stageClipboard(
        ClipboardContent(
          image: ClipboardImage(bytes: pixels, name: 'retained.png'),
        ),
      );
      final originalFiles = draft.attachments;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: InputBar(controller: controller, draft: draft),
            ),
          ),
        ),
      );
      await _drain(tester);
      expect(controller.pipeline.phase, AssistantPhase.listening);
      controller.pipeline.interrupt();
      await _drain(tester);
      expect(controller.pipeline.status, SessionStatus.connected);
      expect(controller.pipeline.phase, AssistantPhase.idle);
      final button = find.byKey(const ValueKey('voice-status-button'));
      final tooltip = tester.widget<PopupMenuButton<String>>(button).tooltip!;
      expect(tooltip, contains('Voice input is paused'));
      expect(tooltip, isNot(contains('Listening')));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Reconnect'), findsOneWidget);
      await tester.tap(find.text('Reconnect'));
      await _drain(tester, 30);
      expect(backends, hasLength(2));
      expect(controller.pipeline.status, SessionStatus.connected);
      expect(controller.pipeline.voiceInputNeedsReconnect, isFalse);
      expect(controller.pipeline.phase, AssistantPhase.listening);
      expect(draft.text.text, 'Keep this exact unsent question.');
      expect(draft.attachments, originalFiles);
      expect(draft.attachments.single.bytes, pixels);
      expect(
        backends.every((backend) => backend.texts.isEmpty),
        isTrue,
        reason: 'Reconnect never sends the unsent draft.',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      Object? failure;
      await tester.runAsync(() async {
        unawaited(
          controller.shutdown().then(
            (_) => closed = true,
            onError: (Object e) {
              failure = e;
              closed = true;
            },
          ),
        );
      });
      for (var i = 0; !closed && i < 500; i++) {
        await _drain(tester, 1);
      }
      expect(closed, isTrue);
      if (failure != null) throw failure!;
      draft.dispose();
      await tester.runAsync(platform.dispose);
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
