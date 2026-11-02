class DelegateResult {
  const DelegateResult({required this.output, this.success = true, this.model, this.tokensUsed});
  final String output;
  final bool success;
  final String? model;
  final int? tokensUsed;

  Map<String, Object?> toJson() => {
    'ok': success,
    'output': output,
    if (model != null) 'model': model,
    if (tokensUsed != null) 'tokens': tokensUsed,
  };
}

/// Hands complex, multi-step work to a stronger text model
/// (e.g. gpt-6.1-sol via the Responses API).
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
