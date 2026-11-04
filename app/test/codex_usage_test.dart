import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/auth.dart';
import 'package:woi/core/responses/responses_client.dart';
import 'package:woi/core/usage/codex_usage.dart';
import 'package:woi/core/util/usage_limit.dart';

/// `GET chatgpt.com/backend-api/wham/usage`, recorded 2026-11-04 with a Plus
/// login; ids, email and balance replaced.
const kRecordedUsage = '''
{"user_id":"user-REDACTED","account_id":"acct-REDACTED","email":"user@example.com","plan_type":"plus",
 "rate_limit":{"allowed":true,"limit_reached":false,
  "primary_window":{"used_percent":28,"limit_window_seconds":18000,"reset_after_seconds":2140,"reset_at":1793793596},
  "secondary_window":{"used_percent":4,"limit_window_seconds":604800,"reset_after_seconds":588957,"reset_at":1794380414}},
 "code_review_rate_limit":null,"additional_rate_limits":null,
 "model_usage":{"gpt-6-astra":{"available":true,"available_at":null,"credits_would_enable":false}},
 "credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0",
  "approx_local_messages":[0,0],"approx_cloud_messages":[0,0]},
 "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null,
 "rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}
''';

/// `x-codex-*` headers of a Responses API reply (names as Codex CLI reads
/// them, codex-api/src/rate_limits.rs; values made up).
const kRecordedHeaders = {
  'x-codex-plan-type': 'plus',
  'x-codex-primary-used-percent': '66.0',
  'x-codex-primary-window-minutes': '300',
  'x-codex-primary-reset-at': '1793793596',
  'x-codex-secondary-used-percent': '83.5',
  'x-codex-secondary-window-minutes': '10080',
  'x-codex-secondary-reset-after-seconds': '3600',
  'x-codex-active-limit': 'codex',
};

Credentials _codex() => const Credentials(mode: AuthMode.codex, bearerToken: 'tok-test', accountId: 'acct-1');

class _UsageServer {
  late HttpServer http;
  int status = 200;
  String body = kRecordedUsage;
  final requests = <HttpRequest>[];
  final auth = <String?>[];
  final account = <String?>[];

  Uri get url => Uri.parse('http://127.0.0.1:${http.port}/backend-api/wham/usage');

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      requests.add(req);
      auth.add(req.headers.value('authorization'));
      account.add(req.headers.value('chatgpt-account-id'));
      req.response.statusCode = status;
      req.response.write(body);
      await req.response.close();
    });
  }
}

void main() {
  final now = DateTime(2026, 11, 4, 12);

  group('UsageSnapshot', () {
    test('parses the recorded wham/usage payload', () {
      final s = UsageSnapshot.fromJson(jsonDecode(kRecordedUsage), now: now)!;
      expect(s.plan, 'plus');
      expect(s.source, UsageSource.endpoint);
      expect(s.limitReached, isFalse);
      expect(s.primary!.usedPercent, 28);
      expect(s.primary!.remainingPercent, 72);
      expect(s.primary!.windowMinutes, 300);
      expect(s.primaryLabel, '5h');
      expect(s.secondaryLabel, 'week');
      expect(s.primary!.resetsAt, DateTime.fromMillisecondsSinceEpoch(1793793596 * 1000));
      expect(s.compact, '5h 28% used · week 4% used');
      expect(s.describe(), contains('5h window: 28% used, 72% left, resets '));
      expect(s.describe(), contains('plan plus'));
      expect(s.toJson()['week'], containsPair('remaining_percent', 96));
      // No personal fields leak into what the tools / UI see.
      expect(jsonEncode(s.toJson()), isNot(contains('example.com')));
      expect(s.lowWindow(20), isNull);
    });

    test('reset_after_seconds when reset_at is missing; junk is null', () {
      final s = UsageSnapshot.fromJson({
        'rate_limit': {
          'primary_window': {'used_percent': 90.5, 'reset_after_seconds': 60},
        },
      }, now: now)!;
      expect(s.primary!.resetsAt, now.add(const Duration(minutes: 1)));
      expect(s.secondary, isNull);
      expect(s.compact, '5h 91% used');
      expect(UsageSnapshot.fromJson({'detail': 'Unauthorized'}), isNull);
      expect(UsageSnapshot.fromJson('nope'), isNull);
      expect(UsageSnapshot.fromJson({'rate_limit': null}), isNull);
    });

    test('parses x-codex-* headers (reset-at and reset-after-seconds)', () {
      final s = UsageSnapshot.fromHeaders({
        for (final e in kRecordedHeaders.entries) e.key.toUpperCase(): e.value,
      }, now: now)!;
      expect(s.source, UsageSource.headers);
      expect(s.plan, 'plus');
      expect(s.primary!.usedPercent, 66);
      expect(s.primary!.resetsAt, DateTime.fromMillisecondsSinceEpoch(1793793596 * 1000));
      expect(s.secondary!.usedPercent, 83.5);
      expect(s.secondary!.resetsAt, now.add(const Duration(hours: 1)));
      expect(s.compact, '5h 66% used · week 84% used');
      expect(UsageSnapshot.fromHeaders({'x-codex-turn-state': 'x'}), isNull);
    });

    test('merge keeps the window a header update does not carry', () {
      final base = UsageSnapshot.fromJson(jsonDecode(kRecordedUsage), now: now)!;
      final upd = UsageSnapshot.fromHeaders({'x-codex-primary-used-percent': '40'}, now: now)!;
      final m = base.merge(upd);
      expect(m.primary!.usedPercent, 40);
      expect(m.secondary!.usedPercent, 4);
      expect(m.plan, 'plus');
    });

    test('lowWindow: the tighter window below the threshold; a reached limit counts', () {
      UsageSnapshot snap(double p, double s, {bool reached = false}) => UsageSnapshot(
        primary: UsageWindow(usedPercent: p, windowMinutes: 300),
        secondary: UsageWindow(usedPercent: s, windowMinutes: 10080),
        limitReached: reached,
        updatedAt: now,
        source: UsageSource.endpoint,
      );
      expect(snap(50, 79).lowWindow(20), isNull);
      expect(snap(50, 81).lowWindow(20)!.$1, 'week');
      expect(snap(85, 81).lowWindow(20)!.$1, '5h');
      expect(snap(85, 81).lowWindow(10), isNull);
      expect(snap(85, 81).lowWindow(0), isNull);
      expect(snap(10, 10, reached: true).lowWindow(20), isNotNull);
    });
  });

  group('CodexUsage', () {
    late _UsageServer server;
    setUp(() async {
      server = _UsageServer();
      await server.start();
    });
    tearDown(() => server.http.close(force: true));

    test('fetches the endpoint with the Codex headers', () async {
      final u = CodexUsage(credentials: () async => _codex(), endpoint: server.url, now: () => now);
      final s = await u.refresh();
      expect(s, isNotNull);
      expect(u.snapshot!.compact, '5h 28% used · week 4% used');
      expect(server.requests.single.method, 'GET');
      expect(server.requests.single.uri.path, '/backend-api/wham/usage');
      expect(server.auth.single, 'Bearer tok-test');
      expect(server.account.single, 'acct-1');
      expect(u.error, isNull);
      u.dispose();
    });

    test('errors keep the status only, never the body', () async {
      server
        ..status = 401
        ..body = '{"detail":"token tok-test expired"}';
      final u = CodexUsage(credentials: () async => _codex(), endpoint: server.url);
      expect(await u.refresh(), isNull);
      expect(u.error, 'usage HTTP 401');
      expect(u.snapshot, isNull);
      u.dispose();
    });

    test('no fetch without a Codex login (API key or signed out)', () async {
      final key = CodexUsage(
        credentials: () async => const Credentials(mode: AuthMode.apiKey, bearerToken: 'sk-x'),
        endpoint: server.url,
      );
      final none = CodexUsage(credentials: () async => null, endpoint: server.url);
      expect(await key.refresh(), isNull);
      expect(await none.refresh(), isNull);
      expect(server.requests, isEmpty);
      key.dispose();
      none.dispose();
    });

    test('single flight', () async {
      final u = CodexUsage(credentials: () async => _codex(), endpoint: server.url);
      await Future.wait([u.refresh(), u.refresh(), u.refresh()]);
      expect(server.requests, hasLength(1));
      u.dispose();
    });

    test('polls only while active; resuming fetches only when stale', () async {
      final u = CodexUsage(
        credentials: () async => _codex(),
        endpoint: server.url,
        interval: const Duration(milliseconds: 80),
      );
      u.setActive(true); // launch fetch
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(u.fetchCount, greaterThanOrEqualTo(3));
      u.setActive(false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final stopped = u.fetchCount;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(u.fetchCount, stopped);
      u.dispose();

      // Fresh data (e.g. from headers): becoming active does not refetch.
      var t = now;
      final fresh = CodexUsage(credentials: () async => _codex(), endpoint: server.url, now: () => t);
      fresh.updateFromHeaders(kRecordedHeaders);
      fresh.setActive(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fresh.fetchCount, 0);
      fresh.setActive(false);
      t = now.add(const Duration(minutes: 11));
      fresh.setActive(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fresh.fetchCount, 1);
      expect(fresh.snapshot!.source, UsageSource.endpoint);
      fresh.dispose();
    });

    test('a 429 usage limit marks the limit and refetches', () async {
      final u = CodexUsage(credentials: () async => _codex(), endpoint: server.url);
      u.updateFromHeaders(kRecordedHeaders);
      server.body = kRecordedUsage.replaceFirst('"limit_reached":false', '"limit_reached":true');
      var notified = 0;
      u.addListener(() => notified++);
      u.onUsageLimit(UsageLimit(resetsAt: now, plan: 'plus'));
      expect(u.snapshot!.limitReached, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.requests, hasLength(1));
      expect(u.snapshot!.limitReached, isTrue);
      expect(notified, 2);
      u.dispose();
    });
  });

  test('ResponsesClient hands the x-codex quota headers to onQuotaHeaders', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      await req.drain<void>();
      kRecordedHeaders.forEach(req.response.headers.set);
      req.response.headers.set('x-codex-turn-state', 'secret');
      req.response.write(
        'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {'status': 'completed', 'output': []},
        })}\n\n',
      );
      await req.response.close();
    });
    final u = CodexUsage(credentials: () async => null);
    final seen = <Map<String, String>>[];
    ResponsesClient.onQuotaHeaders = (q) {
      seen.add(q);
      u.updateFromHeaders(q);
    };
    try {
      final client = ResponsesClient(
        credentials: () async => _codex(),
        codexEndpoint: Uri.parse('http://127.0.0.1:${http.port}/responses'),
      );
      await client.create(model: 'gpt-6-luna', input: const []);
      expect(seen.single.keys, isNot(contains('x-codex-turn-state')));
      expect(u.snapshot!.compact, '5h 66% used · week 84% used');
    } finally {
      ResponsesClient.onQuotaHeaders = null;
      await http.close(force: true);
      u.dispose();
    }
  });
}
