import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/util/usage_limit.dart';

void main() {
  const body =
      'StateError: gpt-live call failed: HTTP 429 {"error":{"type":"usage_limit_reached",'
      '"message":"The usage limit has been reached","plan_type":"plus","resets_at":1793900663,'
      '"limit_window_minutes":10080,"resets_in_seconds":142680}}';

  test('parses the ChatGPT 429 body: reset time and plan', () {
    final l = UsageLimit.parse(body)!;
    expect(l.resetsAt, DateTime.fromMillisecondsSinceEpoch(1793900663 * 1000));
    expect(l.plan, 'plus');
    expect(l.message, startsWith('ChatGPT usage limit reached, resets '));
    expect(l.message, isNot(contains('{')));
    expect(l.activeAt(DateTime.fromMillisecondsSinceEpoch(1793900000 * 1000)), isTrue);
    expect(l.activeAt(DateTime.fromMillisecondsSinceEpoch(1793900700 * 1000)), isFalse);
  });

  test('resets_in_seconds when there is no resets_at', () {
    final now = DateTime(2026, 11, 3, 12);
    final l = UsageLimit.parse('HTTP 429 {"error":{"type":"usage_limit_reached","resets_in_seconds":60}}', now: now)!;
    expect(l.resetsAt, now.add(const Duration(seconds: 60)));
  });

  test('a bare HTTP 429 counts (an hour without a reset time); other errors do not', () {
    final l = UsageLimit.parse('HTTP 429 Too Many Requests')!;
    expect(l.resetsAt, isNull);
    final seen = DateTime(2026, 11, 3, 12);
    expect(l.activeAt(seen.add(const Duration(minutes: 30)), seenAt: seen), isTrue);
    expect(l.activeAt(seen.add(const Duration(minutes: 61)), seenAt: seen), isFalse);
    expect(UsageLimit.parse('HTTP 401 unauthorized'), isNull);
    expect(UsageLimit.parse('connection lost after 4290 ms'), isNull);
    expect(UsageLimit.parse(null), isNull);
  });

  test('formatReset is short and local', () {
    expect(UsageLimit.formatReset(DateTime(2026, 11, 5, 14, 31)), 'Thu 5 Nov 14:31');
  });
}
