import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/app_controller.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/voice/voice_backend.dart';
import 'package:woi/platform/android/android_bridge.dart';
import 'package:woi/platform/android/android_integration.dart';
import 'package:woi/platform/platform_services.dart';

import 'fakes/fakes.dart';

class _HandoffEnvironment {
  late FakePlatform fp;
  late AppController controller;
  late AndroidIntegration integration;
  final backends = <ScriptedBackend>[];
  Completer<void>? connectGate;
  bool _stopped = false;

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      fp = await FakePlatform.create();
      final services = fp.services;
      controller = AppController(
        platform: PlatformServices(
          paths: services.paths,
          audio: services.audio,
          screen: services.screen,
          input: services.input,
          shell: services.shell,
          files: services.files,
          viewer: services.viewer,
          isMobile: true,
        ),
        confirmations: FakeConfirmations(),
        backendFactory: () {
          final backend = ScriptedBackend()..connectGate = connectGate;
          backends.add(backend);
          return backend;
        },
        authManager: CodexAuthManager(path: '${fp.root.path}/no-auth.json'),
      );
      await controller.init();
    });
    // Subscribe in the test clock's zone: lifecycle timers are advanced by
    // pump(), while only filesystem/bootstrap work uses runAsync.
    integration = AndroidIntegration(controller)..start();
    addTearDown(() => stop(tester));
  }

  Future<void> event(WidgetTester tester, Map<String, Object?> value) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'woi/android/events',
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> stop(WidgetTester tester) async {
    if (_stopped) return;
    _stopped = true;
    integration.dispose();
    await tester.runAsync(() async {
      await controller.shutdown();
      await fp.dispose();
    });
    await tester.pump(const Duration(seconds: 5));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const events = MethodChannel('woi/android/events');

  setUp(() {
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(AndroidBridge.method, (_) async => true);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(AndroidBridge.method, null);
  });

  test('overlay handoff is explicit and older native dismissals remain dismissals', () {
    final handoff = AndroidEvent.parse({'type': 'overlay', 'on': false, 'toApp': true}) as OverlayEvent;
    final dismissal = AndroidEvent.parse({'type': 'overlay', 'on': false}) as OverlayEvent;
    expect(handoff.on, isFalse);
    expect(handoff.toApp, isTrue);
    expect(dismissal.toApp, isFalse);
  });

  testWidgets('assistant to app keeps the model session, streaming response and text image audio context', (
    tester,
  ) async {
    final env = _HandoffEnvironment();
    await env.start(tester);
    final controller = env.controller;
    final conversation = controller.pipeline.conversation;
    final prior = Message(
      kind: MessageKind.user,
      text: 'Remember that the project is called North Star.',
      audio: AudioClip(path: '${env.fp.root.path}/prior-audio.wav', durationMs: 1200),
    );
    conversation
      ..summary = 'The project budget was agreed earlier.'
      ..add(prior);
    await tester.runAsync(() async {
      // Load the seeded history before sending media to this session.
      // init() already opened a session, so this deliberate setup reconnect
      // must not be mistaken for an additional connection during handoff.
      await controller.pipeline.connect();
      await controller.pipeline.attachScreenshot(
        await env.fp.screen.capture(),
        note: 'Project reference image',
        to: prior,
        activation: true,
      );
      expect(await controller.pipeline.sendText('Continue planning this project.'), isTrue);
    });
    final backend = controller.pipeline.backend! as ScriptedBackend;
    final connectionCount = env.backends.length;
    final config = backend.config!;
    final image = prior.image;
    final audio = prior.audio;
    expect(config.priorContext, conversation.summary);
    expect(config.recentContext, contains('North Star'));
    expect(config.instructions, controller.contextInstructions);
    expect(backend.images, isNotEmpty);
    final imageCount = backend.images.length;
    env.fp.audio.mic!.push(pcm(20, amplitude: 3000));
    final deliveredAudio = backend.audioBytes;
    expect(deliveredAudio, greaterThan(0));
    backend.emit(const AssistantTranscriptDelta('The next step is '));
    final response = conversation.messages.lastWhere((message) => message.kind == MessageKind.assistant);
    final cancellations = backend.cancels;

    // The underlying Activity can already be backgrounded when its shared
    // Flutter engine is shown in the assistant panel.
    controller.onLifecycle(AppLifecycleState.paused);
    await env.event(tester, {'type': 'overlay', 'on': false, 'toApp': true});
    controller.onLifecycle(AppLifecycleState.resumed);
    await _settle(tester);

    expect(identical(controller.pipeline.backend, backend), isTrue);
    expect(identical(controller.pipeline.conversation, conversation), isTrue);
    expect(identical(backend.config, config), isTrue);
    expect(controller.pipeline.idleWarm, isFalse);
    expect(controller.pipeline.suspended, isFalse);
    expect(backend.closed, isFalse);
    expect(backend.cancels, cancellations);
    expect(response.interrupted, isFalse);
    expect(response.streaming, isTrue);
    backend.emit(const AssistantTranscriptDelta('unchanged after opening the app.'));
    backend.emit(const ResponseDone());
    expect(response.text, 'The next step is unchanged after opening the app.');
    expect(prior.image, same(image));
    expect(prior.audio, same(audio));

    await tester.runAsync(() async {
      expect(await controller.pipeline.sendText('What is the project name from before?'), isTrue);
    });
    // The follow-up reaches the same server-side conversation that received
    // the earlier instructions, turns, image and audio; nothing is rebuilt.
    expect(backend.texts, ['Continue planning this project.', 'What is the project name from before?']);
    expect(backend.images.length, imageCount);
    expect(backend.audioBytes, greaterThanOrEqualTo(deliveredAudio));
    expect(conversation.messages.where((message) => message.id == prior.id), hasLength(1));
    expect(env.backends, hasLength(connectionCount));

    // Duplicate/late handoff notifications must not create another session.
    await env.event(tester, {'type': 'overlay', 'on': false, 'toApp': true});
    expect(env.backends, hasLength(connectionCount));
    expect(controller.pipeline.conversation.id, conversation.id);
    await env.stop(tester);
  });

  testWidgets('handoff keeps a queued text and image while a connection is pending', (tester) async {
    final env = _HandoffEnvironment();
    await env.start(tester);
    final controller = env.controller;
    env.connectGate = Completer<void>();
    late Future<void> connecting;
    await tester.runAsync(() async {
      connecting = controller.pipeline.connect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    final backend = controller.pipeline.backend! as ScriptedBackend;
    final connectionCount = env.backends.length;
    expect(backend.connectStarted, isTrue);
    expect(controller.pipeline.status, SessionStatus.connecting);
    final conversationId = controller.pipeline.conversation.id;
    final clip = AudioClip(path: '${env.fp.root.path}/queued-audio.wav', durationMs: 900);
    late Future<bool> accepted;
    bool? sendResult;
    await tester.runAsync(() async {
      await controller.pipeline.attachScreenshot(
        await env.fp.screen.capture(),
        note: 'Pending screen',
        activation: true,
      );
      accepted = controller.pipeline.sendText('Pending assistant turn', audioClip: clip);
      unawaited(accepted.then((value) => sendResult = value));
    });
    expect(sendResult, isNull);
    expect(backend.texts, isEmpty);
    controller.onLifecycle(AppLifecycleState.paused);
    await env.event(tester, {'type': 'overlay', 'on': false, 'toApp': true});
    expect(sendResult, isNull, reason: 'presentation changes do not reject queued input');

    env.connectGate!.complete();
    await tester.runAsync(() async {
      await connecting;
      expect(await accepted, isTrue);
    });
    expect(controller.pipeline.backend, same(backend));
    expect(controller.pipeline.conversation.id, conversationId);
    expect(backend.texts, ['Pending assistant turn']);
    expect(backend.images, hasLength(1));
    expect(
      controller.pipeline.conversation.messages.where((message) => message.text == 'Pending assistant turn'),
      hasLength(1),
    );
    expect(
      controller.pipeline.conversation.messages
          .singleWhere((message) => message.text == 'Pending assistant turn')
          .audio,
      same(clip),
    );
    expect(env.backends, hasLength(connectionCount));
    await env.stop(tester);
  });

  testWidgets('ordinary assistant dismissal still interrupts and suspends', (tester) async {
    final env = _HandoffEnvironment();
    await env.start(tester);
    final controller = env.controller;
    controller.assistantKeepAliveOverride = const Duration(milliseconds: 100);
    await tester.runAsync(() => controller.pipeline.sendText('Please continue.'));
    final backend = controller.pipeline.backend! as ScriptedBackend;
    backend.emit(const AssistantTranscriptDelta('A response in progress'));
    final response = controller.pipeline.conversation.messages.lastWhere(
      (message) => message.kind == MessageKind.assistant,
    );
    final cancellations = backend.cancels;
    controller.onLifecycle(AppLifecycleState.paused);
    await env.event(tester, {'type': 'overlay', 'on': false});
    await _settle(tester);
    expect(backend.cancels, greaterThan(cancellations));
    expect(response.interrupted, isTrue);
    expect(controller.pipeline.idleWarm, isTrue);
    await tester.pump(const Duration(milliseconds: 150));
    await _settle(tester);
    expect(controller.pipeline.suspended, isTrue);
    expect(backend.closed, isTrue);
    await env.stop(tester);
  });

  testWidgets('opening the app cancels an old dismissal timer before another app switch', (tester) async {
    final env = _HandoffEnvironment();
    await env.start(tester);
    final controller = env.controller;
    controller.assistantKeepAliveOverride = const Duration(milliseconds: 250);
    final backend = controller.pipeline.backend;
    controller.onLifecycle(AppLifecycleState.paused);
    await env.event(tester, {'type': 'overlay', 'on': false});
    await _settle(tester);
    expect(controller.pipeline.idleWarm, isTrue);

    await env.event(tester, {'type': 'overlay', 'on': false, 'toApp': true});
    await _settle(tester);
    expect(controller.pipeline.idleWarm, isFalse);
    // A later ordinary app switch must not inherit the former panel's timer.
    controller.onLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    expect(controller.pipeline.suspended, isFalse);
    expect(controller.pipeline.backend, same(backend));
    await env.stop(tester);
  });
}
