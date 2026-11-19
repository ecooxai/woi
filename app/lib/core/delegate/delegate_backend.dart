class DelegateResult {
  const DelegateResult({
    required this.output,
    this.success = true,
    this.model,
    this.tokensUsed,
    this.modelNote,
    this.toolResults = const [],
  });
  final String output;
  final bool success;
  final String? model;
  final int? tokensUsed;

  /// Why [model] differs from the selected one (the usage guard), if it does.
  final String? modelNote;

  /// Actual execution receipts, kept separately from the model's summary.
  final List<Map<String, Object?>> toolResults;

  Map<String, Object?> toJson() => {
    'ok': success,
    'output': output,
    if (model != null) 'model': model,
    if (tokensUsed != null) 'tokens': tokensUsed,
    'model_note': ?modelNote,
    if (toolResults.isNotEmpty) 'tool_results': toolResults,
  };
}

/// Hands complex, multi-step work to a text model through the Responses API.
/// Automatic app delegation selects GPT Luna.
abstract class DelegateBackend {
  Future<DelegateResult> runTask(String task, {required String model, String? context});
}

/// Placeholder until the Responses API client lands.
class StubDelegateBackend implements DelegateBackend {
  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return DelegateResult(
      success: false,
      model: model,
      output:
          'Delegation is not connected yet (stub). Task was: '
          '${task.length > 200 ? '${task.substring(0, 200)}…' : task}',
    );
  }
}
