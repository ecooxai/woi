import 'dart:convert';

import '../voice/delegation_executor.dart';
import 'agent_runs.dart';

/// Records the existing gpt-live tool planner. It never invokes a model or
/// authorizes a tool, and keeps the planner separate from its actual tool runs.
class AgentPlannerRuns implements DelegationObserver {
  AgentPlannerRuns({required this.store, this.conversationId});

  final AgentRunStore store;
  final String Function()? conversationId;
  final Map<DelegationReport, AgentRun> _runs = {};
  final Map<DelegationReport, void Function()> _cancel = {};
  final Map<DelegationToolRun, AgentStep> _steps = {};
  final Map<DelegationReport, Set<DelegationToolRun>> _pending = {};

  @override
  void started(DelegationReport report, void Function() cancel) {
    if (_runs.containsKey(report)) return;
    final run = store.create(
      task: 'Voice tool planner: ${report.request}',
      toolName: 'voice_tool_planner',
      model: report.model,
      callId: report.id,
      conversationId: conversationId?.call() ?? '',
    );
    _runs[report] = run;
    _cancel[report] = cancel;
    _pending[report] = {};
    store.markRunning(run);
    store.setCancellation(run, cancel);
  }

  @override
  void toolStarted(DelegationReport report, DelegationToolRun tool) {
    final run = _runs[report];
    if (run == null || _steps.containsKey(tool)) return;
    _steps[tool] = store.beginStep(run, tool.name, tool.argsJson);
    _pending[report]!.add(tool);
    // A child already has its own execution/cancellation capability. Do not
    // claim that cancelling this planner can undo an in-flight device action.
    store.setCancellation(run, null);
  }

  @override
  void toolFinished(DelegationReport report, DelegationToolRun tool) {
    final run = _runs[report];
    if (run == null) return;
    final step = _steps[tool];
    if (step != null && tool.resultJson != null) store.finishStep(run, step, tool.resultJson!);
    _pending[report]?.remove(tool);
    if (_pending[report]?.isEmpty == true && !report.cancelled) {
      store.setCancellation(run, _cancel[report]);
    }
  }

  @override
  void finished(DelegationReport report) {
    final run = _runs[report];
    if (run == null) return;
    for (final tool in report.tools) {
      toolStarted(report, tool);
      if (tool.resultJson != null) toolFinished(report, tool);
    }
    final relevant = report.tools.where((tool) => !(report.freshCapture && identical(tool, report.tools.first)));
    final success = report.ok && relevant.every((tool) => tool.ok);
    final result = jsonEncode({
      'ok': success && !report.cancelled,
      'planner_id': report.id,
      'model': report.model,
      'output': report.resultText,
      if (report.answerText.isNotEmpty) 'answer': report.answerText,
      'tool_results': [
        for (final tool in report.tools)
          {
            'call_id': tool.callId,
            'tool': tool.name,
            'arguments': _decode(tool.argsJson),
            'status': tool.doneAt == null ? 'pending' : (tool.ok ? 'success' : 'error'),
            if (tool.resultJson != null) 'result': _decode(tool.resultJson!),
          },
      ],
      if (report.total != null) 'duration_ms': report.total!.inMilliseconds,
      if (report.cancelled) 'cancelled': true,
    });
    store.finish(
      run,
      status: report.cancelled
          ? AgentRunStatus.cancelled
          : (success ? AgentRunStatus.completed : AgentRunStatus.failed),
      result: result,
      error: report.cancelled
          ? 'Planner cancelled. No further tools were started; completed actions are preserved in the results.'
          : (success ? null : report.error?.toString() ?? 'One or more tools reported failure.'),
    );
    for (final tool in report.tools) {
      _steps.remove(tool);
    }
    _runs.remove(report);
    _cancel.remove(report);
    _pending.remove(report);
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}
