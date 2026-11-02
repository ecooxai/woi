import 'dart:async';
import 'dart:io';

/// Minimal text WebSocket used by the realtime backend; faked in tests.
abstract class RealtimeSocket {
  /// Incoming text frames. Completes when the socket closes.
  Stream<String> get messages;

  void send(String text);

  Future<void> close([int? code, String? reason]);

  /// Close code once closed (null while open or when unknown).
  int? get closeCode;
  String? get closeReason;
}

/// Opens a [RealtimeSocket]; throws on handshake failure.
typedef RealtimeConnector = Future<RealtimeSocket> Function(Uri uri, Map<String, String> headers);

/// dart:io implementation.
class IoRealtimeSocket implements RealtimeSocket {
  IoRealtimeSocket._(this._ws) : messages = _ws.where((m) => m is String).cast<String>().asBroadcastStream();

  final WebSocket _ws;

  @override
  final Stream<String> messages;

  static Future<RealtimeSocket> connect(
    Uri uri,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ws = await WebSocket.connect(uri.toString(), headers: headers).timeout(timeout);
    ws.pingInterval = const Duration(seconds: 20);
    return IoRealtimeSocket._(ws);
  }

  @override
  void send(String text) {
    if (_ws.readyState == WebSocket.open) _ws.add(text);
  }

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code ?? WebSocketStatus.normalClosure, reason);

  @override
  int? get closeCode => _ws.closeCode;
  @override
  String? get closeReason => _ws.closeReason;
}
