import '../delegate/delegate_backend.dart';
import 'codex_usage.dart';

/// The inexpensive model background work falls back to.
const kCheapModel = 'gpt-6-luna';

/// Default [AppSettings.usageGuardPercent]: below this much remaining in
/// either window, background work uses [kCheapModel].
const kDefaultUsageGuardPercent = 20;

/// The model actually used for a background job, and why it differs from the
/// selected one ([reason] is null when it does not).
class ModelChoice {
  const ModelChoice(this.model, {required this.selected, this.reason});

  final String model;
  final String selected;
  final String? reason;

  bool get downgraded => model != selected;

  @override
  String toString() => reason == null ? model : '$model ($reason)';
}

/// Delegation and compaction use [kCheapModel] instead of [selected] (e.g.
/// gpt-6.1-sol) while either Codex window has less than [thresholdPercent]
/// remaining, or the usage limit was reached. [thresholdPercent] 0 disables.
ModelChoice guardModel(String selected, UsageSnapshot? usage, {int thresholdPercent = kDefaultUsageGuardPercent}) {
  if (selected == kCheapModel || usage == null) return ModelChoice(selected, selected: selected);
  final low = usage.lowWindow(thresholdPercent);
  if (low == null) return ModelChoice(selected, selected: selected);
  final (label, w) = low;
  final why = usage.limitReached
      ? 'ChatGPT usage limit reached'
      : '$label usage window has ${w.remainingPercent.round()}% left (< $thresholdPercent%)';
  return ModelChoice(kCheapModel, selected: selected, reason: '$why: using $kCheapModel instead of $selected');
}

/// A [DelegateBackend] that runs each task on the guarded model
/// ([guardModel]) and reports the reason in the result.
class GuardedDelegate implements DelegateBackend {
  GuardedDelegate(this.inner, this.choose, {this.onChoice});

  final DelegateBackend inner;

  /// The effective model for the selected one.
  final ModelChoice Function(String selected) choose;
  final void Function(ModelChoice choice)? onChoice;

  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    final c = choose(model);
    onChoice?.call(c);
    final r = await inner.runTask(task, model: c.model, context: context);
    if (!c.downgraded) return r;
    return DelegateResult(
      output: r.output,
      success: r.success,
      model: r.model ?? c.model,
      tokensUsed: r.tokensUsed,
      modelNote: c.reason,
    );
  }
}
