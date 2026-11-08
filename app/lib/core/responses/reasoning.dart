/// Public Responses reasoning choices. Support is model-specific.
const kTextReasoningEffortChoices = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

/// Documented capabilities, shared by Settings and text request builders.
/// Unknown/custom IDs keep their provider defaults rather than receiving an
/// unverified parameter. The model ID itself is never changed.
/// Sources: https://developers.openai.com/api/docs/guides/reasoning
/// and https://developers.openai.com/api/docs/models (checked 2026-11-08).
List<String> reasoningEffortChoices(String model) {
  final id = model.trim().toLowerCase().replaceFirst(RegExp(r'-\d{4}-\d{2}-\d{2}$'), '');
  return switch (id) {
    'gpt-6-astra' || 'gpt-6.1-sol' => const ['low', 'medium', 'high', 'xhigh', 'max'],
    'gpt-6-sol' ||
    'gpt-6-luna' ||
    'gpt-6.1-terra' ||
    'gpt-5.6-sol' ||
    'gpt-5.6-terra' => const ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
    'gpt-5.4' || 'gpt-5.5' => const ['none', 'low', 'medium', 'high', 'xhigh'],
    'gpt-5.1' => const ['none', 'low', 'medium', 'high'],
    'gpt-5' || 'gpt-5-mini' || 'gpt-5-nano' => const ['minimal', 'low', 'medium', 'high'],
    _ => const [],
  };
}

/// Applies the user's text preference only where it is supported. A stale
/// unsupported selection is reported before sending a request, never silently
/// substituted. Dedicated pointer requests supply their own fixed reasoning.
Map<String, Object?>? textReasoning(String model, String? effort) {
  if (effort == null) return null;
  final choices = reasoningEffortChoices(model);
  if (choices.isEmpty) return null;
  if (!choices.contains(effort)) {
    throw ArgumentError.value(effort, 'thinking level', '$model supports ${choices.join(', ')}');
  }
  return {'effort': effort};
}
