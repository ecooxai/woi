import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/context/compressor.dart';
import 'package:woi/core/context/context_manager.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/net/realtime_socket.dart';
import 'package:woi/core/pipeline/turn_pipeline.dart';
import 'package:woi/core/storage/history_store.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/tools/tool_registry.dart';
import 'package:woi/core/voice/live_rtc_transport.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';
import 'fakes/fakes.dart' as platform_fakes;

class _ControlRtc extends FakeLiveTransport implements LiveRtcEventSource {
  _ControlRtc({bool ready = true}) {
    if (ready) open();
  }
  final _control = StreamController<String>.broadcast();
  final _ready = Completer<void>();
  int readyWaits = 0;
  Completer<void>? offerGate;
  @override
  Future<String> createOffer() async {
    await offerGate?.future;
    return super.createOffer();
  }

  @override
  Stream<String> get controlEvents => _control.stream;
  @override
  Future<void> waitForControlReady() {
    readyWaits++;
    return _ready.future;
  }

  void open() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void push(Map<String, Object?> event) {
    if (!_control.isClosed) _control.add(jsonEncode(event));
  }

  void fail() =>
      _control.addError(StateError('synthetic control channel failed'));
  @override
  Future<void> close() async {
    // Release a startup waiter without introducing an unobserved error future.
    if (!_ready.isCompleted) _ready.complete();
    await _control.close();
    await super.close();
  }
}

class _HeldCloseSocket implements RealtimeSocket {
  _HeldCloseSocket(this.inner, this.gate);
  final RealtimeSocket inner;
  final Completer<void> gate;
  @override
  Stream<String> get messages => inner.messages;
  @override
  int? get closeCode => inner.closeCode;
  @override
  String? get closeReason => inner.closeReason;
  @override
  void send(String text) => inner.send(text);
  @override
  Future<void> close([int? code, String? reason]) async {
    await gate.future;
    await inner.close(code, reason);
  }
}

class _Rig {
  _Rig({bool firstReady = true}) {
    transports.add(_ControlRtc(ready: firstReady));
    backend = LiveWebRtcBackend(
      transportFactory: () {
        if (_created++ > 0) transports.add(_ControlRtc(ready: nextReady));
        return transports.last;
      },
      sideband: (uri, headers) async {
        final socket = await server.connect(uri, headers);
        await sidebandConnectGate?.future;
        final closeGate = sidebandCloseGate;
        return closeGate == null ? socket : _HeldCloseSocket(socket, closeGate);
      },
      createCall: server.createCall,
      delegationModelFactory: (_) => model,
      swapQuiet: const Duration(milliseconds: 5),
      swapPoll: const Duration(milliseconds: 2),
      sessionStartTimeout: const Duration(milliseconds: 250),
    )..setInputEnabled(false);
    sub = backend.events.listen(events.add);
  }
  final server = FakeLiveServer();
  final model = FakeDelegationModel([]);
  final transports = <_ControlRtc>[];
  final events = <BackendEvent>[];
  int _created = 0;
  bool nextReady = true;
  Completer<void>? sidebandConnectGate;
  Completer<void>? sidebandCloseGate;
  late final LiveWebRtcBackend backend;
  late final StreamSubscription<BackendEvent> sub;
  _ControlRtc get rtc => transports.last;
  FakeSideband get socket => server.socket;
  Future<void> connect() => backend.connect(
    const SessionConfig(
      model: 'gpt-live-1.1',
      voice: 'himari',
      instructions: 'Synthetic test.',
      credentials: Credentials(
        mode: AuthMode.codex,
        bearerToken: 'synthetic-token',
      ),
    ),
  );
  Future<void> close() async {
    await backend.close();
    await sub.cancel();
  }
}

class _PipelineRig {
  _PipelineRig(this.rig, this.platform, this.conversation, this.saved);
  final _Rig rig;
  final platform_fakes.FakePlatform platform;
  final Conversation conversation;
  final Message saved;
  late final TurnPipeline pipeline;
  int factories = 0;

  static Future<_PipelineRig> create(String fullResult) async {
    final rig = _Rig();
    final fp = await platform_fakes.FakePlatform.create();
    final store = HistoryStore(fp.services.paths);
    await store.init();
    final origin = Message(
      kind: MessageKind.user,
      text: 'Describe the attached synthetic image.',
    );
    final saved = Message(
      kind: MessageKind.assistant,
      text: fullResult,
      meta: {
        'type': 'attachment_analysis',
        'sourceMessageId': origin.id,
        'model': 'fixture',
      },
    );
    final conversation = Conversation()..messages.addAll([origin, saved]);
    final value = _PipelineRig(rig, fp, conversation, saved);
    value.pipeline = TurnPipeline(
      backendFactory: () {
        value.factories++;
        return rig.backend;
      },
      audio: fp.audio,
      screen: fp.screen,
      tools: ToolRegistry(),
      context: ContextManager(
        compressor: StubCompressor(latency: Duration.zero),
        threshold: 100000,
      ),
      store: store,
      conversation: conversation,
      sessionConfig: (_) async => const SessionConfig(
        model: 'gpt-live-1.1',
        voice: 'himari',
        instructions: 'Synthetic test.',
        credentials: Credentials(
          mode: AuthMode.codex,
          bearerToken: 'synthetic-token',
        ),
      ),
      options: () => const PipelineOptions(autoScreenshot: false),
    )..reconnectBaseDelay = const Duration(milliseconds: 15);
    await value.pipeline.start();
    await _until(() => value.pipeline.status == SessionStatus.connected);
    return value;
  }

  Future<void> close() async {
    await pipeline.shutdown();
    await rig.close();
    await platform.dispose();
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await _tick();
  }
  expect(ready(), isTrue, reason: 'Expected synthetic pipeline boundary');
}

List<Map<String, Object?>> _appends(FakeSideband socket) =>
    socket.sent.where((e) => e['type'] == 'session.context.append').toList();
Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 15));
String _body(Map<String, Object?> event) =>
    ((event['content'] as List).single as Map)['text'] as String;
const _ack = {'type': 'session.context.appended'};

void main() {
  test(
    'DC-only receipt advances the real multipart queue without sideband ACK',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      rig.backend.sendText(
        'Synthetic complete source ${'東京 source. ' * 70} END-714',
      );
      expect(_appends(rig.socket), hasLength(1));
      rig.rtc.push(_ack);
      await _tick();
      expect(_appends(rig.socket), hasLength(2));
    },
  );

  test('native readiness is required before connect accepts input', () async {
    final rig = _Rig(firstReady: false);
    addTearDown(rig.close);
    var connected = false;
    final connection = rig.connect().then((_) => connected = true);
    await _tick();
    expect(rig.server.sockets, hasLength(1));
    expect(connected, isFalse);
    rig.rtc.open();
    await connection;
    expect(rig.rtc.readyWaits, 1);
  });

  test('sideband duplicate cannot acknowledge the next part or duplicate completion', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    await rig.connect();
    final original = 'Exact source 東京 👩🏽‍💻 ${'alpha beta. ' * 130} END-714';
    rig.backend.sendText(original);
    while (true) {
      final sent = _appends(rig.socket);
      final current = sent.last;
      expect(utf8.encode(_body(current)).length, lessThanOrEqualTo(500));
      rig.socket.push(_ack);
      await _tick();
      expect(_appends(rig.socket), hasLength(sent.length));
      rig.rtc.push(_ack);
      await _tick();
      // The sideband copy can arrive after the next part is already pending.
      rig.socket.push(_ack);
      await _tick();
      if (current['channel'] == null) break;
      expect(_appends(rig.socket), hasLength(sent.length + 1));
    }
    final sent = _appends(rig.socket);
    final source = sent.where((e) => e['channel'] == 'developer').map((e) {
      final body = _body(e);
      return body.substring(body.indexOf('\n') + 1);
    }).join();
    expect(source, 'The user typed (instead of speaking): $original');
    expect(sent.where((e) => e['channel'] == null), hasLength(1));
  });

  test(
    'native transcript and turn events use only the selected control source',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      const words = {
        'type': 'output_transcript.added',
        'item': {'text': 'MARKER-714'},
        'start_ms': 0,
        'end_ms': 200,
      };
      const done = {
        'type': 'turn.done',
        'turn': {
          'id': 'one-turn',
          'role': 'assistant',
          'start_ms': 0,
          'end_ms': 0,
          'transcript': 'MARKER-714',
        },
      };
      rig.socket.push(words);
      rig.rtc.push(words);
      rig.rtc.push(done);
      rig.socket.push(done);
      await _tick();
      expect(
        rig.events.whereType<AssistantTranscriptDelta>().map((e) => e.text),
        ['MARKER-714'],
      );
      expect(
        rig.events.whereType<AssistantTranscriptDone>().map((e) => e.text),
        ['MARKER-714'],
      );
      expect(rig.events.whereType<ResponseDone>(), hasLength(1));
    },
  );

  test(
    'Stop during multipart staging suppresses remaining parts and completion',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      rig.backend.sendText('Synthetic ${'full result. ' * 150} END');
      expect(_appends(rig.socket), hasLength(1));
      rig.backend.cancelPendingTools();
      rig.socket.push(_ack);
      rig.rtc.push(_ack);
      await _tick();
      expect(_appends(rig.socket), hasLength(1));
      expect(_appends(rig.socket).where((e) => e['channel'] == null), isEmpty);
    },
  );

  test(
    'a selected correlated rejection stops staging without a completion',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      rig.backend.sendText('Synthetic ${'full result. ' * 150} END');
      final first = _appends(rig.socket).single;
      final rejected = {
        'type': 'error',
        'error': {
          'event_id': first['event_id'],
          'code': 'synthetic_rejected',
          'message': 'Synthetic rejection',
        },
      };
      rig.socket.push(rejected);
      await _tick();
      expect(rig.events.whereType<BackendError>(), isEmpty);
      rig.rtc.push(rejected);
      await _tick();
      expect(_appends(rig.socket), hasLength(1));
      expect(
        rig.events.whereType<BackendError>().any(
          (e) => e.code == 'synthetic_rejected',
        ),
        isTrue,
      );
    },
  );

  test(
    'lost selected control closes delivery once and never changes to sideband',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      rig.backend.sendText('Synthetic ${'full result. ' * 150} END');
      rig.rtc.fail();
      await _tick();
      rig.socket.push(_ack);
      await _tick();
      expect(_appends(rig.socket), hasLength(1));
      expect(
        rig.events.whereType<BackendError>().where(
          (e) => e.code == 'live_control_channel_lost',
        ),
        hasLength(1),
      );
      expect(rig.rtc.closed, isTrue);
      expect(rig.server.calls, hasLength(1));
    },
  );

  test('a retired old control cannot acknowledge a replacement part', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    await rig.connect();
    final old = rig.rtc;
    expect(
      await rig.backend.prepareTypedInputContext(
        writtenContext: 'Saved full result.',
        recentContext: '',
        isCurrent: () => true,
      ),
      isTrue,
    );
    expect(old.closed, isTrue);
    rig.backend.sendText('Synthetic ${'new result. ' * 150} END');
    old.push(_ack);
    await _tick();
    expect(_appends(rig.socket), hasLength(1));
    rig.rtc.push(_ack);
    await _tick();
    expect(_appends(rig.socket), hasLength(2));
    expect(
      rig.events.whereType<BackendError>().where(
        (e) => e.code == 'live_control_channel_lost',
      ),
      isEmpty,
    );
  });

  test(
    'Stop during readiness closes the preparation and cannot activate late',
    () async {
      final rig = _Rig();
      addTearDown(rig.close);
      await rig.connect();
      rig.nextReady = false;
      final pending = Future<bool>.value(
        rig.backend.prepareTypedInputContext(
          writtenContext: 'Saved result.',
          recentContext: '',
          isCurrent: () => true,
        ),
      );
      for (var i = 0; i < 30 && rig.transports.length < 2; i++) {
        await _tick();
      }
      final retired = rig.rtc;
      expect(retired.readyWaits, 1);
      rig.backend.cancelPendingTools();
      expect(await pending.timeout(const Duration(milliseconds: 100)), isFalse);
      await _tick();
      expect(retired.closed, isTrue);
      retired.open();
      await _tick();
      expect(rig.backend.callId, 'rtc_test1');
      expect(_appends(rig.socket), isEmpty);
      expect(
        rig.events.whereType<BackendError>().where(
          (e) => e.code == 'live_control_channel_lost',
        ),
        isEmpty,
      );
    },
  );

  test('readiness timeout closes the unaccepted native session', () async {
    final rig = _Rig(firstReady: false);
    addTearDown(rig.close);
    await expectLater(rig.connect(), throwsA(isA<LiveCallException>()));
    expect(rig.rtc.closed, isTrue);
    expect(rig.socket.closed, isTrue);
    expect(_appends(rig.socket), isEmpty);
  });

  test(
    'close joins pending readiness without emitting a connection loss',
    () async {
      final rig = _Rig(firstReady: false);
      addTearDown(rig.close);
      final pending = rig.connect();
      final failure = expectLater(pending, throwsA(isA<LiveCallException>()));
      await _tick();
      await rig.backend.close();
      await failure;
      expect(rig.rtc.closed, isTrue);
      expect(
        rig.events.whereType<BackendError>().where(
          (e) => e.code == 'live_control_channel_lost',
        ),
        isEmpty,
      );
    },
  );
  test('control failure during offer cannot create a late call or unhandled startup error', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    final offer = Completer<void>();
    rig.rtc.offerGate = offer;
    final connection = rig.connect();
    final failed = expectLater(connection, throwsA(isA<LiveCallException>()));
    await _tick();
    rig.rtc.fail();
    await _tick();
    expect(rig.rtc.closed, isTrue);
    offer.complete();
    await failed;
    expect(rig.server.calls, isEmpty);
    expect(
      rig.events.whereType<BackendError>().where(
        (e) => e.code == 'live_control_channel_lost',
      ),
      hasLength(1),
    );
  });
  test('pipeline keeps the full written result and never reconnects or redispatches after control loss', () async {
    final full = 'Exact saved result 東京 ${'source detail. ' * 100} END-714';
    final p = await _PipelineRig.create(full);
    addTearDown(p.close);
    p.rig.model.turns.add(DelegationModelTurn(text: full, calls: []));
    const question = 'What does the saved analysis say?';
    expect(await p.pipeline.sendText(question), isTrue);
    await _until(
      () => p.conversation.messages.any(
        (m) => m.meta['type'] == 'attachment_reference_answer',
      ),
    );
    final written = p.conversation.messages.singleWhere(
      (m) => m.meta['type'] == 'attachment_reference_answer',
    );
    expect(written.text, full);
    expect(p.rig.model.requests, hasLength(1));
    final callCount = p.rig.server.calls.length;
    final appendCount = _appends(p.rig.socket).length;
    p.rig.rtc.fail();
    await _until(() => p.pipeline.status == SessionStatus.error);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(p.pipeline.reconnecting, isFalse);
    expect(p.pipeline.autoReconnects, 0);
    expect(p.factories, 1);
    expect(p.rig.server.calls, hasLength(callCount));
    expect(p.rig.model.requests, hasLength(1));
    expect(_appends(p.rig.socket), hasLength(appendCount));
    expect(p.saved.text, full);
    expect(written.text, full);
    expect(
      p.conversation.messages.where(
        (m) => m.kind == MessageKind.user && m.text == question,
      ),
      hasLength(1),
    );
    expect(p.rig.rtc.closed, isTrue);
    expect(
      p.rig.events.whereType<BackendError>().where(
        (e) => e.code == 'connection_lost',
      ),
      isEmpty,
    );
  });

  test('pipeline retains an undispatched draft and full saved result when prepared control fails', () async {
    final full = 'Exact saved result 東京 ${'source detail. ' * 100} END-714';
    final p = await _PipelineRig.create(full);
    addTearDown(p.close);
    p.rig.nextReady = false;
    const draft =
        'What does the saved analysis say?\nUnsent exact draft こんにちは-714';
    final sent = p.pipeline.sendText(draft);
    await _until(
      () => p.rig.transports.length == 2 && p.rig.rtc.readyWaits == 1,
    );
    p.rig.rtc.fail();
    expect(await sent.timeout(const Duration(milliseconds: 250)), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      p.conversation.messages.any(
        (m) => m.kind == MessageKind.user && m.text == draft,
      ),
      isFalse,
    );
    expect(p.saved.text, full);
    expect(p.rig.model.requests, isEmpty);
    expect(_appends(p.rig.socket), isEmpty);
    expect(p.factories, 1);
    expect(p.pipeline.reconnecting, isFalse);
    expect(p.pipeline.autoReconnects, 0);
    expect(p.rig.rtc.closed, isTrue);
  });
  test('native cleanup starts while network close is held during pending readiness', () async {
    final rig = _Rig(firstReady: false);
    addTearDown(rig.close);
    final gate = Completer<void>();
    rig.sidebandCloseGate = gate;
    final connecting = rig.connect();
    final failed = expectLater(connecting, throwsA(isA<LiveCallException>()));
    await _tick();
    final closing = rig.backend.close();
    try {
      await _tick();
      expect(
        rig.rtc.closed,
        isTrue,
        reason: 'Native capture cleanup cannot wait for the network close handshake',
      );
      expect(rig.rtc._ready.isCompleted, isTrue);
      expect(rig.socket.closed, isFalse);
    } finally {
      gate.complete();
      await closing;
      await failed;
    }
    expect(rig.socket.closed, isTrue);
    expect(rig.events.whereType<BackendError>(), isEmpty);
  });

  test('Stop closes a late sideband socket before publishing a retired preparation', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    await rig.connect();
    final gate = Completer<void>();
    rig.sidebandConnectGate = gate;
    final pending = Future<bool>.value(
      rig.backend.prepareTypedInputContext(
        writtenContext: 'Full saved note.',
        recentContext: '',
        isCurrent: () => true,
      ),
    );
    await _until(() => rig.server.sockets.length == 2);
    final lateSocket = rig.socket;
    final retired = rig.rtc;
    rig.backend.cancelPendingTools();
    expect(await pending.timeout(const Duration(milliseconds: 100)), isFalse);
    await _tick();
    expect(retired.closed, isTrue);
    gate.complete();
    await _tick();
    try {
      expect(
        lateSocket.closed,
        isTrue,
        reason: 'Socket acquired after retirement must be closed even though cached session.close completed',
      );
      expect(_appends(lateSocket), isEmpty);
      expect(rig.backend.callId, 'rtc_test1');
      expect(
        rig.events.whereType<BackendError>().where((e) => e.fatal),
        isEmpty,
      );
    } finally {
      if (!lateSocket.closed) await lateSocket.close();
    }
  });
}
