import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:woi/core/net/realtime_socket.dart';
import 'package:woi/core/voice/delegation_executor.dart';
import 'package:woi/core/voice/live_rtc_transport.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';

/// WebRTC transport stand-in: records what the backend asks of it.
class FakeLiveTransport implements LiveRtcTransport {
  String? answer;
  bool micEnabled = true;
  bool speakerEnabled = true;
  bool captureSuspended = false;
  bool? captureSuspendedAtOffer;
  Completer<void>? captureSuspendGate;
  Object? captureSuspendError;
  final captureSuspensions = <bool>[];
  bool closed = false;
  final micToggles = <bool>[];

  /// Mic state when the track is created (createOffer): the real transport
  /// creates the track in the state set by earlier setMicEnabled() calls.
  bool? micAtOffer;
  final _states = StreamController<String>.broadcast();

  @override
  Future<String> createOffer() async {
    micAtOffer = micEnabled;
    captureSuspendedAtOffer = captureSuspended;
    return 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
  }

  @override
  Future<void> setAnswer(String sdp) async => answer = sdp;
  @override
  void setMicEnabled(bool enabled) {
    micEnabled = enabled;
    micToggles.add(enabled);
  }

  @override
  Future<void> setCaptureSuspended(bool suspended) async {
    captureSuspended = suspended;
    captureSuspensions.add(suspended);
    if (suspended) {
      await captureSuspendGate?.future;
      if (captureSuspendError != null) throw captureSuspendError!;
    }
  }

  @override
  void setSpeakerEnabled(bool enabled) => speakerEnabled = enabled;
  @override
  Stream<String> get connectionStates => _states.stream;
  @override
  String get description => 'fake';
  @override
  Future<void> close() async {
    closed = true;
    await _states.close();
  }
}

/// Sideband WebSocket; the test plays the server.
class FakeSideband implements RealtimeSocket {
  FakeSideband(this.uri, this.headers, {this.autoAcknowledgeContext = false});
  final bool autoAcknowledgeContext;
  final Uri uri;
  final Map<String, String> headers;
  final _in = StreamController<String>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];
  bool closed = false;
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Stream<String> get messages => _in.stream;

  void push(Map<String, Object?> ev) {
    if (!_in.isClosed) _in.add(jsonEncode(ev));
  }

  @override
  void send(String text) {
    final event = (jsonDecode(text) as Map).cast<String, Object?>();
    sent.add(event);
    if (autoAcknowledgeContext &&
        (event['type'] == 'session.context.append' || event['type'] == 'delegation.context.append')) {
      Timer.run(
        () => push({
          'type': event['type'] == 'session.context.append'
              ? 'session.context.appended'
              : 'delegation.context.appended',
          if (event['delegation_item_id'] != null) 'delegation_item_id': event['delegation_item_id'],
        }),
      );
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    closeCode = code ?? 1000;
    await _in.close();
  }

  List<Map<String, Object?>> ofType(String t) => [
    for (final e in sent)
      if (e['type'] == t) e,
  ];

  // ---- server event helpers (shapes from research/REALTIME_API.md §3.3)

  void audio(int startMs, Uint8List pcm) => push({
    'type': 'session.output_audio.delta',
    'delta': base64Encode(pcm),
    'start_ms': startMs,
    'end_ms': startMs + pcm.length ~/ 48,
  });
  void micEcho(Uint8List pcm) => push({'type': 'session.input_audio.append', 'audio': base64Encode(pcm)});
  void inputWords(String t, int startMs) => push({
    'type': 'input_transcript.added',
    'item': {'text': t},
    'start_ms': startMs,
    'end_ms': startMs + 300,
  });
  void outputWords(String t, int startMs) => push({
    'type': 'output_transcript.added',
    'item': {'text': t},
    'start_ms': startMs,
    'end_ms': startMs + 300,
  });
  void turn(String phase, String role, int startMs, int endMs, String transcript) => push({
    'type': 'turn.$phase',
    'turn': {'id': 'turn_$role$startMs', 'role': role, 'start_ms': startMs, 'end_ms': endMs, 'transcript': transcript},
  });
  void delegation(String id, String text) => push({
    'type': 'delegation.created',
    'item': {
      'id': id,
      'type': 'delegation',
      'content': [
        {'type': 'input_text', 'text': text},
      ],
    },
  });
}

/// Records call creation and hands out [FakeSideband]s.
class FakeLiveServer {
  final calls = <(Uri, Map<String, String>, Map<String, Object?>)>[];
  final sockets = <FakeSideband>[];
  bool autoStart = true;
  bool autoAcknowledgeContext = false;

  FakeSideband get socket => sockets.last;

  Future<LiveCall> createCall(Uri uri, Map<String, String> headers, Map<String, Object?> body) async {
    calls.add((uri, headers, body));
    return LiveCall(callId: 'rtc_test${calls.length}', answerSdp: 'v=0\r\nanswer\r\n');
  }

  Future<RealtimeSocket> connect(Uri uri, Map<String, String> headers) async {
    final s = FakeSideband(uri, headers, autoAcknowledgeContext: autoAcknowledgeContext);
    sockets.add(s);
    if (autoStart) {
      Timer.run(() => s.push({'type': 'session.started', 'session': <String, Object?>{}}));
    }
    return s;
  }
}

/// Scripted Responses model: each [respond] pops the next turn.
class FakeDelegationModel extends DelegationModel {
  final receivedInstructions = <String>[];
  FakeDelegationModel(this.turns, {this.latency = Duration.zero});
  final List<DelegationModelTurn> turns;
  final Duration latency;
  final requests = <({String model, List<Map<String, Object?>> input, List<Map<String, Object?>> tools})>[];
  final reasoningEfforts = <String?>[];
  bool closed = false;

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    requests.add((model: model, input: List.of(input), tools: tools));
    receivedInstructions.add(instructions);
    reasoningEfforts.add(reasoningEffort);
    await Future<void>.delayed(latency);
    final t = turns.isEmpty ? const DelegationModelTurn(text: 'Nothing to do.', calls: []) : turns.removeAt(0);
    for (final c in t.calls) {
      onToolCall?.call(c);
    }
    return DelegationModelTurn(text: t.text, calls: t.calls, firstEvent: latency);
  }

  @override
  void close() => closed = true;
}

DelegationToolCall call(String name, Map<String, Object?> args, {String? id}) =>
    DelegationToolCall(callId: id ?? 'call_$name', name: name, arguments: jsonEncode(args));
