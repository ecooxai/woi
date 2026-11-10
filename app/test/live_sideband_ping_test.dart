import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/net/realtime_socket.dart';
import 'package:woi/core/voice/live_webrtc_backend.dart';
import 'package:woi/core/voice/voice_backend.dart';

import 'fakes/live_fakes.dart';

/// A raw peer deliberately omits Pong while still delivering application data.
/// WebSocketTransformer cannot model this: it automatically answers Ping.
class _NoPongPeer {
  _NoPongPeer(this.socket, this.path) {
    subscription = socket.listen(
      _read,
      onDone: _done,
      onError: (Object _) => _done(),
    );
    send({'type': 'session.started'});
    ticks = Timer.periodic(const Duration(milliseconds: 250), (_) {
      send({'type': 'fixture.application.data'});
    });
  }

  final Socket socket;
  final String path;
  final clock = Stopwatch()..start();
  final bytes = <int>[];
  final fragments = <int>[];
  final appends = <Map<String, Object?>>[];
  late final StreamSubscription<Uint8List> subscription;
  Timer? ticks;
  Timer? response;
  bool ended = false;
  bool closeSent = false;
  int pings = 0;
  int? firstPingMs;
  final receivedClose = Completer<int?>();
  int? clientCloseCode;
  int? clientCloseMs;
  int? appendMs;
  int acknowledgments = 0;

  void send(Map<String, Object?> event) {
    if (!ended && !closeSent) _frame(1, utf8.encode(jsonEncode(event)));
  }

  void _frame(int opcode, List<int> payload) {
    final prefix = <int>[0x80 | opcode];
    if (payload.length < 126) {
      prefix.add(payload.length);
    } else {
      prefix.addAll([126, (payload.length >> 8) & 255, payload.length & 255]);
    }
    socket.add([...prefix, ...payload]);
  }

  void _read(Uint8List incoming) {
    bytes.addAll(incoming);
    while (bytes.length >= 2) {
      final first = bytes[0];
      final masked = (bytes[1] & 0x80) != 0;
      var length = bytes[1] & 0x7f;
      var offset = 2;
      if (length == 126) {
        if (bytes.length < 4) return;
        length = (bytes[2] << 8) | bytes[3];
        offset = 4;
      } else if (length == 127) {
        if (bytes.length < 10) return;
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = (length << 8) | bytes[i];
        }
        offset = 10;
      }
      if (length > 1024 * 1024) {
        throw StateError('Unexpected local fixture frame size');
      }
      if (!masked) throw StateError('Expected a masked client frame');
      if (bytes.length < offset + 4 + length) return;
      final mask = bytes.sublist(offset, offset + 4);
      offset += 4;
      final payload = [
        for (var i = 0; i < length; i++) bytes[offset + i] ^ mask[i % 4],
      ];
      bytes.removeRange(0, offset + length);
      final opcode = first & 0x0f;
      if (opcode == 9) {
        pings++;
        firstPingMs ??= clock.elapsedMilliseconds;
        // Deliberately no Pong: application data must not satisfy the SDK watchdog.
      } else if (opcode == 8) {
        clientCloseCode = payload.length >= 2
            ? (payload[0] << 8) | payload[1]
            : null;
        clientCloseMs = clock.elapsedMilliseconds;
        if (!receivedClose.isCompleted) receivedClose.complete(clientCloseCode);
        closeSent = true;
        ticks?.cancel();
        response?.cancel();
        _frame(8, payload);
        unawaited(socket.close());
      } else if (opcode == 1 || opcode == 0) {
        if (opcode == 1) fragments.clear();
        fragments.addAll(payload);
        if ((first & 0x80) != 0) {
          _message(utf8.decode(fragments));
          fragments.clear();
        }
      }
    }
  }

  void _message(String text) {
    final event = (jsonDecode(text) as Map).cast<String, Object?>();
    if (event['type'] != 'session.context.append') return;
    appends.add(event);
    appendMs = clock.elapsedMilliseconds;
    acknowledgments++;
    send({'type': 'session.context.appended'});
    response = Timer(const Duration(milliseconds: 20), () {
      send({
        'type': 'turn.created',
        'turn': {
          'id': 'delayed-assistant',
          'role': 'assistant',
          'start_ms': 45000,
        },
      });
      send({
        'type': 'output_transcript.added',
        'item': {'text': 'Local delayed reply'},
        'start_ms': 45000,
      });
      send({
        'type': 'turn.done',
        'turn': {
          'id': 'delayed-assistant',
          'role': 'assistant',
          'start_ms': 45000,
          'end_ms': 45100,
          'transcript': 'Local delayed reply',
        },
      });
    });
  }

  void _done() {
    ended = true;
    ticks?.cancel();
    response?.cancel();
  }

  Future<void> dispose() async {
    _done();
    socket.destroy();
    await subscription.cancel();
  }
}

class _NoPongServer {
  _NoPongServer(this.http) {
    subscription = http.listen((request) async {
      final key = request.headers.value('sec-websocket-key')!;
      final accept = base64Encode(
        sha1
            .convert(
              utf8.encode(
                '$key'
                '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
              ),
            )
            .bytes,
      );
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.add(
        utf8.encode(
          'HTTP/1.1 101 Switching Protocols\r\n'
          'Upgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Accept: $accept\r\n\r\n',
        ),
      );
      peers.add(_NoPongPeer(socket, request.uri.path));
    });
  }

  static Future<_NoPongServer> start() async =>
      _NoPongServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer http;
  late final StreamSubscription<HttpRequest> subscription;
  final peers = <_NoPongPeer>[];
  Uri get uri => Uri(scheme: 'ws', host: '127.0.0.1', port: http.port);
  _NoPongPeer peer(String path) => peers.singleWhere((p) => p.path == path);

  Future<void> close() async {
    await http.close(force: true);
    await subscription.cancel();
    for (final peer in peers) {
      await peer.dispose();
    }
  }
}

void main() {
  test('live sideband survives missing Pong while generic default keeps its watchdog', () async {
    final server = await _NoPongServer.start();
    RealtimeSocket? generic;
    StreamSubscription<String>? genericSub;
    LiveWebRtcBackend? backend;
    StreamSubscription<BackendEvent>? backendSub;
    try {
      var genericData = 0;
      var genericDone = false;
      generic = await IoRealtimeSocket.connect(
        server.uri.replace(path: '/generic'),
        {},
      );
      genericSub = generic.messages.listen(
        (_) => genericData++,
        onDone: () => genericDone = true,
      );

      final rtc = FakeLiveTransport();
      final events = <BackendEvent>[];
      final completed = Completer<String>();
      var calls = 0;
      backend = LiveWebRtcBackend(
        transportFactory: () => rtc,
        sidebandBase: '${server.uri}/live',
        createCall: (_, _, _) async {
          calls++;
          return LiveCall(callId: 'local', answerSdp: 'v=0\r\nanswer\r\n');
        },
        delegationModelFactory: (_) => FakeDelegationModel([]),
      );
      backendSub = backend.events.listen((event) {
        events.add(event);
        if (event is AssistantTranscriptDone && !completed.isCompleted) {
          completed.complete(event.text);
        }
      });
      await backend.connect(
        const SessionConfig(
          model: 'gpt-live-1.1',
          voice: 'cove',
          instructions: 'Local transport fixture only.',
          credentials: Credentials(
            mode: AuthMode.codex,
            bearerToken: 'local-fixture-token',
          ),
        ),
      );
      final livePeer = server.peer('/live/local');
      final genericPeer = server.peer('/generic');
      final remaining = const Duration(seconds: 45) - livePeer.clock.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);

      // Both peers keep sending data, but only generic providers use the
      // 20s Ping +20s missing-Pong watchdog. No production timing knobs.
      expect(genericData, greaterThan(100));
      expect(genericPeer.pings, 1);
      expect(genericPeer.firstPingMs, inInclusiveRange(19000, 25000));
      expect(genericPeer.clientCloseCode, WebSocketStatus.goingAway);
      expect(genericPeer.clientCloseMs, inInclusiveRange(39000, 45000));
      expect(genericDone, isTrue);
      expect(generic.closeCode, WebSocketStatus.goingAway);
      expect(
        events.whereType<BackendError>().where(
          (e) => e.code == 'connection_lost',
        ),
        isEmpty,
        reason: 'A live sideband must not retire at the generic missed-Pong deadline.',
      );
      expect(livePeer.pings, 0);
      expect(livePeer.ended, isFalse);
      expect(rtc.closed, isFalse);
      expect(calls, 1);

      backend.sendText('Say Local delayed reply.');
      expect(
        await completed.future.timeout(const Duration(seconds: 3)),
        'Local delayed reply',
      );
      expect(livePeer.appends, hasLength(1));
      expect(livePeer.appendMs, greaterThanOrEqualTo(45000));
      expect(livePeer.acknowledgments, 1);
      final content = livePeer.appends.single['content'] as List;
      expect(
        (content.single as Map)['text'],
        'The user typed (instead of speaking): Say Local delayed reply.',
      );
      expect(events.whereType<BackendError>(), isEmpty);
      expect(calls, 1);

      await backend.close().timeout(const Duration(seconds: 4));
      expect(
        await livePeer.receivedClose.future.timeout(const Duration(seconds: 2)),
        WebSocketStatus.normalClosure,
      );
      expect(rtc.closed, isTrue);
    } finally {
      await backend?.close().timeout(const Duration(seconds: 4));
      await generic?.close().timeout(const Duration(seconds: 4));
      await backendSub?.cancel();
      await genericSub?.cancel();
      await server.close();
    }
  }, timeout: const Timeout(Duration(seconds: 65)));
}
