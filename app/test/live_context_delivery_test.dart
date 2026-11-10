import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/live_context_delivery.dart';

String _body(Map<String, Object?> event) => ((event['content']! as List).single as Map)['text'] as String;

Map<String, Object?> _receipt(Map<String, Object?> event) => {
  'type': event['type'] == 'delegation.context.append' ? 'delegation.context.appended' : 'session.context.appended',
  if (event['delegation_item_id'] != null) 'delegation_item_id': event['delegation_item_id'],
};

String _source(List<Map<String, Object?>> events) =>
    events.where((event) => event['channel'] == 'developer').map((event) {
      final body = _body(event);
      return body.substring(body.indexOf('\n') + 1);
    }).join();

class _Rig {
  _Rig({Duration timeout = const Duration(seconds: 15), bool throwOnSend = false}) {
    queue = LiveContextDeliveryQueue(
      send: (event) {
        sent.add(event);
        if (throwOnSend) throw StateError('synthetic socket closed');
      },
      onError: (message, code, fatal) => errors.add((message, code, fatal)),
      ackTimeout: timeout,
    );
  }
  final sent = <Map<String, Object?>>[];
  final errors = <(String, String, bool)>[];
  late final LiveContextDeliveryQueue queue;
  void ack() => queue.handleEvent(_receipt(sent.last));
  void drain() {
    var count = 0;
    while (!queue.isIdle) {
      if (++count > 1000) fail('delivery did not terminate');
      ack();
    }
  }
}

void main() {
  group('Unicode and byte boundaries', () {
    test('empty and 499/500/501 ASCII characters reassemble exactly', () {
      expect(splitLiveContextText(''), isEmpty);
      for (final length in [499, 500, 501, 1000, 1001]) {
        final text = 'x' * length;
        final chunks = splitLiveContextText(text);
        expect(chunks.join(), text);
        expect(chunks.every((part) => utf8.encode(part).length <= 500), isTrue);
        expect(chunks.length, (length / 500).ceil());
      }
    });

    test('mixed CJK, emoji, combining marks and whitespace remain lossless', () {
      final text = ('東京 👩🏽‍💻 e\u0301 🇯🇵\r\n  source https://example.test/one?q=雪  ' * 40);
      final chunks = splitLiveContextText(text);
      expect(chunks.join(), text);
      expect(chunks.length, greaterThan(2));
      expect(chunks.every((part) => utf8.encode(part).length <= 500), isTrue);
      expect(chunks.expand((part) => part.characters).toList(), text.characters.toList());
    });

    test('normal graphemes never split at a byte boundary', () {
      const family = '👨‍👩‍👧‍👦';
      final text = ['x' * 490, family, 'y' * 490, 'e\u0301' * 30].join();
      final chunks = splitLiveContextText(text);
      expect(chunks.join(), text);
      expect(chunks.expand((part) => part.characters).toList(), text.characters.toList());
      expect(chunks.every((part) => utf8.encode(part).length <= 500), isTrue);
    });

    test('a pathological oversized grapheme splits only between scalars', () {
      final text = ['😀a', '\u0301' * 700, '終'].join();
      final chunks = splitLiveContextText(text);
      expect(chunks.join(), text);
      expect(chunks.every((part) => utf8.encode(part).length <= 500), isTrue);
      expect(chunks.every((part) => utf8.decode(utf8.encode(part)) == part), isTrue);
    });

    test('ordinary source URL stays whole when it fits the budget', () {
      const url = 'https://example.test/evidence/first-middle-last?marker=CHARLIE';
      final text = ['prefix ' * 60, url, ' trailing ' * 60].join();
      final chunks = splitLiveContextText(text);
      expect(chunks.join(), text);
      expect(chunks.where((part) => part.contains(url)), hasLength(1));
    });

    test('invalid byte budget fails explicitly', () {
      expect(() => splitLiveContextText('😀', maxUtf8Bytes: 3), throwsArgumentError);
    });
  });

  group('provider event shapes', () {
    test('short text keeps the original single-event semantics', () {
      final events = buildLiveContextEvents('x' * 500, messageId: 'short');
      expect(events, hasLength(1));
      expect(events.single['type'], 'session.context.append');
      expect(events.single.containsKey('channel'), isFalse);
      expect(_body(events.single), 'x' * 500);
    });

    test('long source is silent, ordered, complete and bounded including labels', () {
      final text = ['First fact ALPHA. 東京 and 👩🏽‍💻. Middle fact BRAVO. ' * 30, 'Last fact CHARLIE.'].join();
      final events = buildLiveContextEvents(text, messageId: 'probe_9');
      final staged = events.take(events.length - 1).toList();
      expect(staged.length, greaterThan(2));
      expect(_source(events), text);
      for (var i = 0; i < staged.length; i++) {
        expect(staged[i]['type'], 'session.context.append');
        expect(staged[i]['channel'], 'developer');
        expect(_body(staged[i]), startsWith('Source text for probe_9, part ${i + 1}/${staged.length}.'));
      }
      for (final event in events) {
        expect(event['content'] as List, hasLength(1));
        expect(utf8.encode(_body(event)).length, lessThanOrEqualTo(500));
      }
      expect(events.last.containsKey('channel'), isFalse);
      expect(_body(events.last), contains('honor any request for silence'));
    });

    test('long background context keeps its silent channel and has no reply cue', () {
      final text = 'Background reference 東京 👩🏽‍💻. ' * 80;
      final events = buildLiveContextEvents(text, messageId: 'silent', channel: 'developer');
      expect(events.length, greaterThan(2));
      expect(events.every((event) => event['type'] == 'session.context.append'), isTrue);
      expect(events.every((event) => event['channel'] == 'developer'), isTrue);
      expect(events.map(_body).join(), text);
      expect(events.every((event) => utf8.encode(_body(event)).length <= 500), isTrue);
      expect(events.any((event) => _body(event).contains('Respond aloud')), isFalse);
    });

    test('an original speakable channel is preserved on its only completion', () {
      final events = buildLiveContextEvents('Reference facts ' * 100, messageId: 'spoken', channel: 'speakable');
      expect(events.take(events.length - 1).every((event) => event['channel'] == 'developer'), isTrue);
      expect(events.last['channel'], 'speakable');
      expect(_body(events.last), contains('is now complete'));
      expect(_body(events.last), contains('honor any request for silence'));
    });

    test('long delegation has one completion with the original delegation ID', () {
      final text = 'Search result and source URL. ' * 80;
      final events = buildLiveContextEvents(text, messageId: 'lookup', delegationId: 'del_original');
      final completions = events.where((event) => event['type'] == 'delegation.context.append').toList();
      expect(completions, hasLength(1));
      expect(identical(completions.single, events.last), isTrue);
      expect(completions.single['delegation_item_id'], 'del_original');
      expect(_source(events), text);
      expect(_body(completions.single), contains('Do not repeat the action'));
    });
  });

  group('acknowledged delivery', () {
    test('sends each part only after the prior receipt, then one completion', () async {
      final rig = _Rig();
      final done = rig.queue.append('source facts ' * 140, delegationId: 'del_1');
      expect(rig.sent, hasLength(1));
      expect(rig.sent.single['channel'], 'developer');
      for (var i = 0; !rig.queue.isIdle; i++) {
        expect(rig.sent.length, i + 1);
        rig.ack();
      }
      expect(await done, isTrue);
      expect(rig.sent.where((e) => e['type'] == 'delegation.context.append'), hasLength(1));
      expect(rig.sent.map((e) => e['event_id']).toSet().length, rig.sent.length);
      expect(rig.errors, isEmpty);
      rig.queue.close();
    });

    test('concurrent logical messages never interleave', () async {
      final rig = _Rig();
      final first = rig.queue.append('FIRST ' * 200);
      final second = rig.queue.append('SECOND');
      rig.drain();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(_body(rig.sent.last), 'SECOND');
      expect(rig.sent.where((e) => _body(e) == 'SECOND'), hasLength(1));
      rig.queue.close();
    });

    test('cancel drains pending receipt before newer work and sends no old completion', () async {
      final rig = _Rig();
      final first = rig.queue.append('cancelled data ' * 100);
      final queued = rig.queue.append('also cancelled');
      rig.queue.cancelPending();
      expect(await first, isFalse);
      expect(await queued, isFalse);
      final next = rig.queue.append('new explicit request');
      expect(rig.sent, hasLength(1));
      rig.ack();
      expect(rig.sent, hasLength(2));
      expect(_body(rig.sent.last), 'new explicit request');
      rig.ack();
      expect(await next, isTrue);
      expect(rig.sent.where((e) => e['channel'] == null), hasLength(1));
      rig.queue.close();
    });

    test('a correlated provider rejection aborts without replay or final narration', () async {
      final rig = _Rig();
      final first = rig.queue.append('long result ' * 100);
      rig.ack(); // The provider accepted only the first source part.
      final failing = rig.sent.last;
      final next = rig.queue.append('next request');
      expect(
        rig.queue.handleEvent({
          'type': 'error',
          'error': {'event_id': 'unrelated', 'code': 'invalid_value'},
        }),
        isFalse,
      );
      expect(rig.sent, hasLength(2));
      expect(
        rig.queue.handleEvent({
          'type': 'error',
          'error': {'event_id': failing['event_id'], 'code': 'invalid_value', 'param': 'content'},
        }),
        isTrue,
      );
      expect(await first, isFalse);
      expect(rig.sent, hasLength(3));
      expect(_body(rig.sent.last), 'next request');
      rig.ack();
      expect(await next, isTrue);
      expect(rig.sent.where((e) => _body(e).contains('is now complete')), isEmpty);
      rig.queue.close();
    });

    test('wrong delegation receipt cannot complete the pending result', () async {
      final rig = _Rig();
      final done = rig.queue.append('Done.', delegationId: 'right');
      expect(rig.queue.handleEvent({'type': 'session.context.appended'}), isFalse);
      expect(rig.queue.handleEvent({'type': 'delegation.context.appended', 'delegation_item_id': 'wrong'}), isFalse);
      expect(rig.queue.isIdle, isFalse);
      rig.ack();
      expect(await done, isTrue);
      expect(rig.queue.handleEvent(_receipt(rig.sent.last)), isFalse);
      rig.queue.close();
    });

    test('close prevents a late receipt or result from leaking to another session', () async {
      final old = _Rig();
      final oldDone = old.queue.append('old source ' * 100);
      old.queue.close();
      expect(await oldDone, isFalse);
      expect(old.queue.handleEvent(_receipt(old.sent.single)), isFalse);
      expect(await old.queue.append('late old result'), isFalse);
      expect(old.sent, hasLength(1));
      final fresh = _Rig();
      final freshDone = fresh.queue.append('fresh session');
      fresh.ack();
      expect(await freshDone, isTrue);
      expect(_body(fresh.sent.single), 'fresh session');
      fresh.queue.close();
    });

    test('ack timeout is fatal and never replays an ambiguous result', () {
      fakeAsync((clock) {
        final rig = _Rig(timeout: const Duration(seconds: 1));
        bool? first, next;
        rig.queue.append('unacknowledged ' * 100).then((ok) => first = ok);
        rig.queue.append('queued request').then((ok) => next = ok);
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(first, isFalse);
        expect(next, isFalse);
        expect(rig.sent, hasLength(1));
        expect(rig.errors, hasLength(1));
        expect(rig.errors.single.$2, 'context_append_timeout');
        expect(rig.errors.single.$3, isTrue);
        clock.elapse(const Duration(seconds: 30));
        expect(rig.sent, hasLength(1));
        rig.queue.close();
      });
    });

    test('socket write failure is contained and never retried', () async {
      final rig = _Rig(throwOnSend: true);
      expect(await rig.queue.append('failed write'), isFalse);
      expect(await rig.queue.append('another request'), isFalse);
      expect(rig.sent, hasLength(1));
      expect(rig.errors.single.$2, 'context_append_send_failed');
      expect(rig.errors.single.$3, isTrue);
      rig.queue.close();
    });

    test('optional diagnostics correlate receipts without exposing content', () async {
      final sent = <Map<String, Object?>>[];
      final diagnostics = <Map<String, Object?>>[];
      final queue = LiveContextDeliveryQueue(
        send: sent.add,
        onError: (_, _, _) => fail('unexpected error'),
        onDiagnostic: diagnostics.add,
      );
      const text = 'PRIVATE_SYNTHETIC_TEXT 東京';
      final done = queue.append(text, delegationId: 'del_qa');
      queue.handleEvent(_receipt(sent.single));
      expect(await done, isTrue);
      expect(diagnostics.map((d) => d['phase']), ['sending', 'acknowledged']);
      expect(diagnostics.map((d) => d['event_id']).toSet(), {sent.single['event_id']});
      expect(diagnostics.every((d) => d['text_utf8_bytes'] == utf8.encode(text).length), isTrue);
      expect(diagnostics.every((d) => d['delegation_item_id'] == 'del_qa'), isTrue);
      expect(jsonEncode(diagnostics), isNot(contains('PRIVATE_SYNTHETIC_TEXT')));
      queue.close();
    });

    test('synchronous receipts cannot recurse or duplicate a part', () async {
      late LiveContextDeliveryQueue queue;
      final sent = <Map<String, Object?>>[];
      queue = LiveContextDeliveryQueue(
        send: (event) {
          sent.add(event);
          queue.handleEvent(_receipt(event));
        },
        onError: (_, _, _) => fail('unexpected delivery error'),
      );
      expect(await queue.append('ordered ' * 1000), isTrue);
      expect(queue.isIdle, isTrue);
      expect(sent.map((e) => e['event_id']).toSet().length, sent.length);
      queue.close();
    });
  });
}
