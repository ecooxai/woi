import 'dart:async';
import 'dart:convert';

import 'package:woi/core/net/realtime_socket.dart';

/// In-memory WebSocket: the test plays the server.
class FakeSocket implements RealtimeSocket {
  FakeSocket(this.uri, this.headers, this.server);
  final Uri uri;
  final Map<String, String> headers;
  final FakeRealtimeServer server;
  // Single-subscription: buffers until the client listens, like a real socket.
  final _in = StreamController<String>(sync: true);
  final sent = <Map<String, Object?>>[];

  /// Server-side item order (ids).
  final items = <String>[];
  bool closed = false;
  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Stream<String> get messages => _in.stream;

  /// Server-originated item (e.g. user audio, assistant reply), appended.
  void addItem(Map<String, Object?> item) {
    final prev = items.isEmpty ? null : items.last;
    items.add(item['id'] as String);
    push({'type': 'conversation.item.added', 'previous_item_id': prev, 'item': item});
  }

  /// Server → client.
  void push(Map<String, Object?> ev) {
    if (!closed) _in.add(jsonEncode(ev));
  }

  @override
  void send(String text) {
    if (closed) return;
    final ev = (jsonDecode(text) as Map).cast<String, Object?>();
    sent.add(ev);
    server._onClientEvent(this, ev);
  }

  /// Server-side close (unexpected disconnect).
  Future<void> drop([int code = 1006]) async {
    closeCode = code;
    closed = true;
    await _in.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    closeCode = code ?? 1000;
    await _in.close();
  }

  List<Map<String, Object?>> ofType(String t) => [
    for (final e in sent)
      if (e['type'] == t) e,
  ];
  List<String> get types => [for (final e in sent) e['type'] as String];
}

/// Scripted server behaviour shared by all sockets.
class FakeRealtimeServer {
  final sockets = <FakeSocket>[];
  bool autoHandshake = true;
  bool autoItems = true;
  bool failDeletes = false;
  String? connectErrorCode;
  int _seq = 0;

  FakeSocket get last => sockets.last;

  Future<RealtimeSocket> connect(Uri uri, Map<String, String> headers) async {
    final s = FakeSocket(uri, headers, this);
    sockets.add(s);
    if (autoHandshake) {
      scheduleMicrotask(() {
        if (connectErrorCode != null) {
          s.push({
            'type': 'error',
            'error': {'type': 'invalid_request_error', 'code': connectErrorCode, 'message': 'nope'},
          });
          return;
        }
        s.push({
          'type': 'session.created',
          'session': {'id': 'sess_${sockets.length}'},
        });
      });
    }
    return s;
  }

  void _onClientEvent(FakeSocket s, Map<String, Object?> ev) {
    switch (ev['type']) {
      case 'session.update':
        if (autoHandshake) scheduleMicrotask(() => s.push({'type': 'session.updated', 'session': ev['session']}));
      case 'conversation.item.create':
        if (!autoItems) return;
        final item = Map<String, Object?>.from(ev['item'] as Map);
        item['id'] ??= 'item_srv_${_seq++}';
        final req = ev['previous_item_id'] as String?;
        final prev = req == 'root' ? null : (req ?? (s.items.isEmpty ? null : s.items.last));
        final at = prev == null ? 0 : s.items.indexOf(prev) + 1;
        s.items.insert(at, item['id'] as String);
        scheduleMicrotask(() => s.push({'type': 'conversation.item.added', 'previous_item_id': prev, 'item': item}));
      case 'conversation.item.delete':
        if (!autoItems) return;
        scheduleMicrotask(() {
          if (failDeletes) {
            s.push({
              'type': 'error',
              'error': {'type': 'invalid_request_error', 'code': 'unsupported', 'message': 'delete not supported'},
            });
          } else {
            s.items.remove(ev['item_id']);
            s.push({'type': 'conversation.item.deleted', 'item_id': ev['item_id']});
          }
        });
    }
  }
}
