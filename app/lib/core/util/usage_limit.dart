/// The ChatGPT account's usage limit (HTTP 429 `usage_limit_reached`), as
/// returned by gpt-live call creation, the Responses API and compaction:
///
/// `{"error":{"type":"usage_limit_reached","message":"The usage limit has been
/// reached","plan_type":"plus","resets_at":1793900663,
/// "limit_window_minutes":10080,"resets_in_seconds":142680}}`
///
/// Retrying before [resetsAt] only burns requests, so callers stop retrying
/// and show [message] instead of the raw JSON.
class UsageLimit {
  const UsageLimit({this.resetsAt, this.plan});

  /// When the limit resets (local time), if the server said.
  final DateTime? resetsAt;

  /// Plan name from the error ("plus", "pro"...), if any.
  final String? plan;

  static final _resetsAt = RegExp(r'"resets_at"\s*:\s*(\d{9,})');
  static final _resetsIn = RegExp(r'"resets_in_seconds"\s*:\s*(\d+)');
  static final _plan = RegExp(r'"plan_type"\s*:\s*"([^"]+)"');

  /// The limit described by [error] (an exception or its text), or null when
  /// it is some other error. A bare HTTP 429 without the JSON body counts too
  /// (rate limited), without a reset time.
  static UsageLimit? parse(Object? error, {DateTime? now}) {
    if (error == null) return null;
    if (error is UsageLimitException) return error.limit;
    final text = '$error';
    final typed = text.contains('usage_limit_reached');
    final http429 =
        RegExp(r'\b429\b').hasMatch(text) &&
        (text.contains('HTTP') || text.contains('status') || text.contains('Too Many'));
    if (!typed && !http429) return null;
    DateTime? at;
    final a = _resetsAt.firstMatch(text);
    if (a != null) {
      at = DateTime.fromMillisecondsSinceEpoch(int.parse(a[1]!) * 1000);
    } else {
      final r = _resetsIn.firstMatch(text);
      if (r != null) at = (now ?? DateTime.now()).add(Duration(seconds: int.parse(r[1]!)));
    }
    return UsageLimit(resetsAt: at, plan: _plan.firstMatch(text)?[1]);
  }

  /// Still in effect at [now]? Without a reset time: assume an hour.
  bool activeAt(DateTime now, {DateTime? seenAt}) {
    final r = resetsAt;
    if (r != null) return now.isBefore(r);
    return seenAt != null && now.difference(seenAt) < const Duration(hours: 1);
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Thu 5 Nov 14:31" (local time).
  static String formatReset(DateTime t) {
    final l = t.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '${_days[l.weekday - 1]} ${l.day} ${_months[l.month - 1]} $hh:$mm';
  }

  /// "ChatGPT usage limit reached, resets Thu 5 Nov 14:31".
  String get message {
    final r = resetsAt;
    return 'ChatGPT usage limit reached${r == null ? '' : ', resets ${formatReset(r)}'}';
  }

  @override
  String toString() => message;
}

/// Thrown instead of retrying while a [UsageLimit] is known to be active.
class UsageLimitException implements Exception {
  const UsageLimitException(this.limit, {this.what});
  final UsageLimit limit;

  /// What was skipped ("gpt-live", "compaction"...).
  final String? what;

  @override
  String toString() => what == null ? limit.message : '${limit.message} ($what)';
}
