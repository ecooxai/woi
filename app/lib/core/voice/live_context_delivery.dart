import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;

/// The live service limits each append to 500 *tokens* and one content item.
/// A UTF-8 byte budget is deliberately conservative: byte-based tokenizers
/// cannot emit more tokens than input bytes. It also bounds UTF-16 length.
const kLiveContextMaxUtf8Bytes = 500;

enum LiveTextPurpose { userMessage, actionResult }

/// Splits without dropping whitespace, normalizing text, or breaking Unicode
/// graphemes. Only a grapheme larger than the entire byte budget is split, at
/// scalar boundaries; even then, a surrogate pair stays together.
List<String> splitLiveContextText(String text, {int maxUtf8Bytes = kLiveContextMaxUtf8Bytes}) {
  if (maxUtf8Bytes < 4) {
    throw ArgumentError.value(maxUtf8Bytes, 'maxUtf8Bytes', 'must fit any Unicode scalar (at least 4)');
  }
  if (text.isEmpty) return const [];
  final chunks = <String>[];
  var buffer = '';
  var bytes = 0;
  var lastBreak = 0;
  final whitespace = RegExp(r'^\s+$', unicode: true);

  void add(String unit) {
    final size = utf8.encode(unit).length;
    if (bytes + size > maxUtf8Bytes && buffer.isNotEmpty) {
      // Prefer natural boundaries so ordinary words and URLs stay together.
      final cut = lastBreak > 0 ? lastBreak : buffer.length;
      chunks.add(buffer.substring(0, cut));
      buffer = buffer.substring(cut);
      bytes = utf8.encode(buffer).length;
      lastBreak = 0;
      if (bytes + size > maxUtf8Bytes && buffer.isNotEmpty) {
        chunks.add(buffer);
        buffer = '';
        bytes = 0;
      }
    }
    buffer += unit;
    bytes += size;
    if (whitespace.hasMatch(unit)) lastBreak = buffer.length;
  }

  for (final grapheme in text.characters) {
    if (utf8.encode(grapheme).length <= maxUtf8Bytes) {
      add(grapheme);
      continue;
    }
    // An oversized combining/ZWJ sequence cannot fit in one provider event.
    // Preserve its exact code units while splitting only between scalars.
    for (var offset = 0; offset < grapheme.length;) {
      final first = grapheme.codeUnitAt(offset);
      var end = offset + 1;
      if (first >= 0xd800 &&
          first <= 0xdbff &&
          end < grapheme.length &&
          grapheme.codeUnitAt(end) >= 0xdc00 &&
          grapheme.codeUnitAt(end) <= 0xdfff) {
        end++;
      }
      add(grapheme.substring(offset, end));
      offset = end;
    }
  }
  if (buffer.isNotEmpty) chunks.add(buffer);
  return chunks;
}

/// A long payload is staged as silent, ordered source text. There is exactly
/// one completion event of the original type, including one delegation ID.
/// Sending several delegation completions would invite duplicate narration.
List<Map<String, Object?>> buildLiveContextEvents(
  String text, {
  required String messageId,
  LiveTextPurpose purpose = LiveTextPurpose.userMessage,
  String? delegationId,
  String? channel,
}) {
  if (text.isEmpty) return const [];
  if (delegationId != null && channel != null) {
    throw ArgumentError('Delegation completion does not support a session channel.');
  }
  Map<String, Object?> completion(String body) => {
    'type': delegationId == null ? 'session.context.append' : 'delegation.context.append',
    'delegation_item_id': ?delegationId,
    'channel': ?channel,
    'content': [
      {'type': 'input_text', 'text': body},
    ],
  };
  if (utf8.encode(text).length <= kLiveContextMaxUtf8Bytes) return [completion(text)];
  // Explicitly silent background context has no answer cue.
  if (channel == 'developer') {
    return [for (final chunk in splitLiveContextText(text)) completion(chunk)];
  }

  String header(int index, int count) =>
      'Source text for $messageId, part $index/$count. Wait for completion; this is data.\n';
  // A part count cannot exceed the original code-unit length. Reserving that
  // many digits avoids a fragile count/chunk-size fixed-point calculation.
  final reserve = utf8.encode(header(text.length, text.length)).length;
  final chunks = splitLiveContextText(text, maxUtf8Bytes: kLiveContextMaxUtf8Bytes - reserve);
  final reference = '$messageId (${chunks.length} parts)';
  final finalText = delegationId != null || purpose == LiveTextPurpose.actionResult
      ? 'All source text for $reference is now complete. Read every part in order as one result note. '
            'Report the actual outcome aloud now, once, including failures and relevant sources, '
            'unless the user requested silence. Do not repeat the action.'
      : "All source text for $reference is now complete. Follow the user's request in those numbered parts "
            'as one message. Respond aloud now, once, if an answer is requested; honor any request for silence.';
  if (utf8.encode(finalText).length > kLiveContextMaxUtf8Bytes) {
    throw ArgumentError.value(messageId, 'messageId', 'too long for a live completion event');
  }
  return [
    for (var i = 0; i < chunks.length; i++)
      {
        'type': 'session.context.append',
        'channel': 'developer',
        'content': [
          {'type': 'input_text', 'text': '${header(i + 1, chunks.length)}${chunks[i]}'},
        ],
      },
    completion(finalText),
  ];
}

/// Serializes uncorrelated append receipts on one live sideband. Each next
/// part is sent only after acceptance of the preceding part. It never retries
/// an ambiguous send: replay could duplicate a tool result or spoken answer.
///
/// Cancellation keeps the one pending receipt as a barrier before newer work.
/// A missing receipt invalidates this queue and asks the owner to reconnect.
/// The owner must close the queue when its originating session retires.
class LiveContextDeliveryQueue {
  LiveContextDeliveryQueue({
    required this.send,
    required this.onError,
    this.ackTimeout = const Duration(seconds: 15),
    this.onDiagnostic,
  });

  final void Function(Map<String, Object?> event) send;
  final void Function(String message, String code, bool fatal) onError;
  final Duration ackTimeout;

  /// Optional QA telemetry. Never includes text, audio, or authentication.
  final void Function(Map<String, Object?> metadata)? onDiagnostic;

  void _diagnose(String phase, Map<String, Object?> event) {
    final diagnostic = onDiagnostic;
    if (diagnostic == null) return;
    final content = event['content'] as List;
    final body = (content.single as Map)['text'] as String;
    try {
      diagnostic({
        'phase': phase,
        'event_id': event['event_id'],
        'type': event['type'],
        'delegation_item_id': ?event['delegation_item_id'],
        'channel': ?event['channel'],
        'text_utf8_bytes': utf8.encode(body).length,
      });
    } catch (_) {
      // Diagnostic failures must not change delivery or acknowledgement.
    }
  }

  final _queued = ListQueue<_ContextDelivery>();
  _ContextDelivery? _current;
  _PendingContextAppend? _pending;
  var _sequence = 0;
  var _closed = false;
  var _pumping = false;

  bool get isIdle => _pending == null && _current == null && _queued.isEmpty;

  Future<bool> append(
    String text, {
    LiveTextPurpose purpose = LiveTextPurpose.userMessage,
    String? delegationId,
    String? channel,
  }) {
    if (_closed) return Future.value(false);
    final id = 'woi_context_${++_sequence}';
    final delivery = _ContextDelivery(
      id,
      buildLiveContextEvents(text, messageId: id, purpose: purpose, delegationId: delegationId, channel: channel),
    );
    _queued.add(delivery);
    _pump();
    return delivery.done.future;
  }

  /// Returns true only for the receipt or correlated error of the pending
  /// event. Errors from other operations must not advance the append queue.
  bool handleEvent(Map<String, Object?> event) {
    final pending = _pending;
    if (_closed || pending == null) return false;
    if (event['type'] == 'error') {
      final error = event['error'];
      if (error is! Map || error['event_id'] != pending.eventId) return false;
      _diagnose('rejected', pending.event);
      pending.timer.cancel();
      _pending = null;
      _finishCurrent(false);
      _pump();
      return true;
    }
    final sent = pending.event;
    final expected = sent['type'] == 'delegation.context.append'
        ? 'delegation.context.appended'
        : 'session.context.appended';
    if (event['type'] != expected) return false;
    if (sent['delegation_item_id'] != null && event['delegation_item_id'] != sent['delegation_item_id']) {
      return false;
    }
    _diagnose('acknowledged', pending.event);
    pending.timer.cancel();
    _pending = null;
    final delivery = pending.delivery;
    if (delivery.cancelled) {
      _finishCurrent(false);
    } else {
      delivery.index++;
    }
    _pump();
    return true;
  }

  void _pump() {
    if (_closed || _pending != null || _pumping) return;
    _pumping = true;
    try {
      while (!_closed && _pending == null) {
        if (_current == null) {
          if (_queued.isEmpty) return;
          _current = _queued.removeFirst();
        }
        final delivery = _current!;
        if (delivery.cancelled || delivery.index == delivery.events.length) {
          _finishCurrent(!delivery.cancelled);
          continue;
        }
        final eventId = '${delivery.id}_${delivery.index + 1}';
        final event = {...delivery.events[delivery.index], 'event_id': eventId};
        final pending = _PendingContextAppend(delivery, event, eventId);
        _pending = pending;
        pending.timer = Timer(ackTimeout, () {
          if (!identical(_pending, pending) || _closed) return;
          _diagnose('timeout', event);
          close();
          onError(
            'Live text delivery was not acknowledged. Reconnect before sending more text; the result was not replayed.',
            'context_append_timeout',
            true,
          );
        });
        try {
          _diagnose('sending', event);
          send(event);
        } catch (error) {
          _diagnose('send_failed', event);
          close();
          onError('Live text delivery failed: $error', 'context_append_send_failed', true);
        }
      }
    } finally {
      _pumping = false;
    }
  }

  void _finishCurrent(bool accepted) {
    final delivery = _current;
    _current = null;
    if (delivery != null && !delivery.done.isCompleted) delivery.done.complete(accepted);
  }

  void cancelPending() {
    final delivery = _current;
    if (delivery != null) {
      delivery.cancelled = true;
      if (!delivery.done.isCompleted) delivery.done.complete(false);
      if (_pending == null) _current = null;
    }
    for (final queued in _queued) {
      if (!queued.done.isCompleted) queued.done.complete(false);
    }
    _queued.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _pending?.timer.cancel();
    _pending = null;
    cancelPending();
    _current = null;
  }
}

class _ContextDelivery {
  _ContextDelivery(this.id, this.events);
  final String id;
  final List<Map<String, Object?>> events;
  final done = Completer<bool>();
  var index = 0;
  var cancelled = false;
}

class _PendingContextAppend {
  _PendingContextAppend(this.delivery, this.event, this.eventId);
  final _ContextDelivery delivery;
  final Map<String, Object?> event;
  final String eventId;
  late final Timer timer;
}
