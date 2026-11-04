import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/auth.dart';
import '../util/usage_limit.dart';

/// The ChatGPT login's rate-limit status endpoint, the one Codex CLI's
/// `/status` reads (`backend-client`: `{base}/wham/usage`). Free: no model
/// quota is spent. Response (sanitised, probed 2026-11-04):
///
/// `{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
/// "primary_window":{"used_percent":28,"limit_window_seconds":18000,
/// "reset_after_seconds":2140,"reset_at":1793793596},"secondary_window":{...}},
/// "credits":{...},...}`
final kCodexUsageUrl = Uri.parse('https://chatgpt.com/backend-api/wham/usage');

/// One rate-limit window: the 5-hour "primary" or the weekly "secondary".
@immutable
class UsageWindow {
  const UsageWindow({required this.usedPercent, this.windowMinutes, this.resetsAt});

  /// 0..100 (may exceed 100 briefly on the server; clamped for display).
  final double usedPercent;
  final int? windowMinutes;
  final DateTime? resetsAt;

  double get remainingPercent => (100 - usedPercent).clamp(0, 100).toDouble();

  /// "5h", "week", "24h"... from the window length.
  String labelOr(String fallback) {
    final m = windowMinutes;
    if (m == null || m <= 0) return fallback;
    if (m >= 7 * 24 * 60 - 60 && m <= 7 * 24 * 60 + 60) return 'week';
    if (m % (24 * 60) == 0) return '${m ~/ (24 * 60)}d';
    if (m % 60 == 0) return '${m ~/ 60}h';
    return '${m}m';
  }

  @override
  bool operator ==(Object other) =>
      other is UsageWindow &&
      other.usedPercent == usedPercent &&
      other.windowMinutes == windowMinutes &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(usedPercent, windowMinutes, resetsAt);

  @override
  String toString() => 'UsageWindow(${usedPercent.toStringAsFixed(0)}% used, $windowMinutes min, resets $resetsAt)';
}

/// Where a [UsageSnapshot] came from.
enum UsageSource { endpoint, headers }

/// Both windows plus the plan, as last seen.
@immutable
class UsageSnapshot {
  const UsageSnapshot({
    this.primary,
    this.secondary,
    this.plan,
    this.limitReached = false,
    required this.updatedAt,
    required this.source,
  });

  /// The 5-hour window.
  final UsageWindow? primary;

  /// The weekly window.
  final UsageWindow? secondary;
  final String? plan;
  final bool limitReached;
  final DateTime updatedAt;
  final UsageSource source;

  String get primaryLabel => primary?.labelOr('5h') ?? '5h';
  String get secondaryLabel => secondary?.labelOr('week') ?? 'week';

  /// The window with the least remaining (null without data).
  (String label, UsageWindow window)? get tightest {
    final p = primary, s = secondary;
    if (p == null && s == null) return null;
    if (s == null || (p != null && p.remainingPercent <= s.remainingPercent)) return (primaryLabel, p!);
    return (secondaryLabel, s);
  }

  /// A window with less than [thresholdPercent] remaining (the tighter one),
  /// or null. A reached limit counts as 0% remaining.
  (String label, UsageWindow window)? lowWindow(int thresholdPercent) {
    if (thresholdPercent <= 0) return null;
    final t = tightest;
    if (t == null) return null;
    return t.$2.remainingPercent < thresholdPercent || limitReached ? t : null;
  }

  /// `/wham/usage` JSON. Null when it has no rate-limit windows.
  static UsageSnapshot? fromJson(Object? json, {DateTime? now}) {
    if (json is! Map) return null;
    final at = now ?? DateTime.now();
    final rl = json['rate_limit'];
    if (rl is! Map) return null;
    UsageWindow? window(Object? w) {
      if (w is! Map) return null;
      final used = _num(w['used_percent']);
      if (used == null) return null;
      final secs = _num(w['limit_window_seconds']);
      return UsageWindow(
        usedPercent: used.toDouble(),
        windowMinutes: secs == null ? null : (secs / 60).round(),
        resetsAt: _reset(w['reset_at'], w['reset_after_seconds'], at),
      );
    }

    final p = window(rl['primary_window']);
    final s = window(rl['secondary_window']);
    if (p == null && s == null) return null;
    return UsageSnapshot(
      primary: p,
      secondary: s,
      plan: json['plan_type'] is String ? json['plan_type'] as String : null,
      limitReached: rl['limit_reached'] == true || rl['allowed'] == false,
      updatedAt: at,
      source: UsageSource.endpoint,
    );
  }

  /// `x-codex-*` response headers (lower-case names), as the Responses API
  /// sends them: `x-codex-primary-used-percent`, `-window-minutes`,
  /// `-reset-at` (unix seconds) or `-reset-after-seconds`, the same for
  /// `secondary`, and `x-codex-plan-type`. Null when no window is present.
  static UsageSnapshot? fromHeaders(Map<String, String> headers, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value.trim()};
    UsageWindow? window(String which) {
      final used = double.tryParse(h['x-codex-$which-used-percent'] ?? '');
      if (used == null) return null;
      return UsageWindow(
        usedPercent: used,
        windowMinutes: int.tryParse(h['x-codex-$which-window-minutes'] ?? ''),
        resetsAt: _reset(h['x-codex-$which-reset-at'], h['x-codex-$which-reset-after-seconds'], at),
      );
    }

    final p = window('primary');
    final s = window('secondary');
    if (p == null && s == null) return null;
    final plan = h['x-codex-plan-type'];
    return UsageSnapshot(
      primary: p,
      secondary: s,
      plan: plan == null || plan.isEmpty ? null : plan,
      limitReached: (h['x-codex-rate-limit-reached-type'] ?? '').isNotEmpty,
      updatedAt: at,
      source: UsageSource.headers,
    );
  }

  /// Newer data on top of this (headers may carry only one window).
  UsageSnapshot merge(UsageSnapshot newer) => UsageSnapshot(
    primary: newer.primary ?? primary,
    secondary: newer.secondary ?? secondary,
    plan: newer.plan ?? plan,
    limitReached: newer.limitReached,
    updatedAt: newer.updatedAt,
    source: newer.source,
  );

  /// The same snapshot with [limit] (an HTTP 429) applied: limit reached
  /// (which [lowWindow] treats as no quota left) until the next fetch.
  UsageSnapshot withLimit(UsageLimit limit, {DateTime? now}) => UsageSnapshot(
    primary: primary,
    secondary: secondary,
    plan: limit.plan ?? plan,
    limitReached: true,
    updatedAt: now ?? DateTime.now(),
    source: source,
  );

  static String _pct(double v) => '${v.round()}%';

  /// "5h 34% used · week 71% used".
  String get compact => [
    if (primary != null) '$primaryLabel ${_pct(primary!.usedPercent)} used',
    if (secondary != null) '$secondaryLabel ${_pct(secondary!.usedPercent)} used',
  ].join(' · ');

  /// A sentence for the voice model / tool results.
  String describe() {
    String one(String label, UsageWindow w) {
      final r = w.resetsAt;
      return '$label window: ${_pct(w.usedPercent)} used, ${_pct(w.remainingPercent)} left'
          '${r == null ? '' : ', resets ${UsageLimit.formatReset(r)}'}';
    }

    return [
      if (primary != null) one(primaryLabel, primary!),
      if (secondary != null) one(secondaryLabel, secondary!),
      if (limitReached) 'usage limit reached',
      if (plan != null) 'plan $plan',
    ].join('; ');
  }

  Map<String, Object?> toJson() {
    Map<String, Object?>? w(UsageWindow? w) => w == null
        ? null
        : {
            'used_percent': w.usedPercent.round(),
            'remaining_percent': w.remainingPercent.round(),
            'window_minutes': ?w.windowMinutes,
            if (w.resetsAt != null) 'resets': UsageLimit.formatReset(w.resetsAt!),
          };
    return {
      if (primary != null) primaryLabel: w(primary),
      if (secondary != null) secondaryLabel: w(secondary),
      'plan': ?plan,
      if (limitReached) 'limit_reached': true,
    };
  }

  static num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

  static DateTime? _reset(Object? resetAt, Object? resetAfter, DateTime now) {
    final a = _num(resetAt);
    if (a != null && a > 1e9) return DateTime.fromMillisecondsSinceEpoch((a * 1000).round());
    final s = _num(resetAfter);
    if (s != null) return now.add(Duration(seconds: s.round()));
    return null;
  }

  @override
  String toString() => 'UsageSnapshot($compact, plan $plan, ${source.name})';
}

/// The ChatGPT/Codex rate-limit status (both windows). Fed by
/// [updateFromHeaders] (the `x-codex-*` headers of Woi's Responses calls) and
/// by fetching [endpoint] at launch and every [interval] while the app is
/// active ([setActive]); nothing runs while it is in the background.
/// Only with a Codex login: an API key has no ChatGPT plan windows.
class CodexUsage extends ChangeNotifier {
  CodexUsage({
    required this.credentials,
    Uri? endpoint,
    HttpClient Function()? httpClient,
    this.interval = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : endpoint = endpoint ?? kCodexUsageUrl,
       _httpClient = httpClient ?? HttpClient.new,
       _now = now ?? DateTime.now;

  final Future<Credentials?> Function() credentials;
  final Uri endpoint;
  final Duration interval;
  final HttpClient Function() _httpClient;
  final DateTime Function() _now;

  UsageSnapshot? _snapshot;
  UsageSnapshot? get snapshot => _snapshot;

  /// Last fetch error (redacted), cleared by a successful update.
  String? get error => _error;
  String? _error;

  /// Fetches made (diagnostics/tests).
  int fetchCount = 0;

  Timer? _timer;
  bool _active = false;
  bool _disposed = false;
  Future<UsageSnapshot?>? _inflight;

  bool get active => _active;

  /// Starts the periodic refresh (and fetches now) while [active]; stops it
  /// otherwise. On becoming active again it fetches only when stale.
  void setActive(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    _timer?.cancel();
    _timer = null;
    if (!active) return;
    if (_stale) unawaited(refresh());
    _timer = Timer.periodic(interval, (_) {
      if (_active && _stale) unawaited(refresh());
    });
  }

  /// Older than ~[interval] (headers count as fresh data too).
  bool get _stale {
    final s = _snapshot;
    return s == null || _now().difference(s.updatedAt) >= interval - const Duration(seconds: 30);
  }

  /// Fetches the usage endpoint now (single flight). Returns the new snapshot,
  /// or null (not signed in with Codex, or the request failed: see [error]).
  Future<UsageSnapshot?> refresh() => _inflight ??= _fetch().whenComplete(() => _inflight = null);

  Future<UsageSnapshot?> _fetch() async {
    try {
      final creds = await credentials();
      if (creds == null || creds.mode != AuthMode.codex) return null;
      fetchCount++;
      final client = _httpClient();
      try {
        final req = await client.getUrl(endpoint).timeout(const Duration(seconds: 15));
        creds.headers().forEach(req.headers.set);
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final res = await req.close().timeout(const Duration(seconds: 20));
        final text = await utf8.decodeStream(res).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          throw HttpException('usage HTTP ${res.statusCode}');
        }
        final snap = UsageSnapshot.fromJson(jsonDecode(text), now: _now());
        if (snap == null) throw const FormatException('usage response without rate-limit windows');
        _set(snap, replace: true);
        return snap;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      // Never the body or headers: only the error kind.
      _error = redactSecrets(e is HttpException ? e.message : '${e.runtimeType}: $e');
      if (_error!.length > 200) _error = _error!.substring(0, 200);
      debugPrint('Codex usage: $_error');
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  /// `x-codex-*` headers from any ChatGPT-backend response.
  void updateFromHeaders(Map<String, String> headers) {
    final snap = UsageSnapshot.fromHeaders(headers, now: _now());
    if (snap != null) _set(snap);
  }

  /// An HTTP 429 usage limit: mark it and refetch the exact numbers.
  void onUsageLimit(UsageLimit limit) {
    final s = _snapshot;
    if (s != null) _set(s.withLimit(limit, now: _now()), replace: true);
    unawaited(refresh());
  }

  /// Test/restore hook.
  @visibleForTesting
  void debugSet(UsageSnapshot? s) {
    _snapshot = s;
    notifyListeners();
  }

  void _set(UsageSnapshot snap, {bool replace = false}) {
    if (_disposed) return;
    final prev = _snapshot;
    _snapshot = replace || prev == null ? snap : prev.merge(snap);
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
