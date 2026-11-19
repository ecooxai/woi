import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/auth.dart' show redactSecrets;
import '../models/message.dart' show newId;
import '../usage/model_guard.dart' show kCheapModel;

enum AgentRunStatus { queued, running, completed, failed, cancelled }

class AgentStep {
  AgentStep({required this.toolName, required this.arguments, DateTime? startedAt, this.finishedAt, this.result})
    : startedAt = startedAt ?? DateTime.now();

  final String toolName;
  final String arguments;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? result;

  Map<String, Object?> toJson() => {
    'tool': toolName,
    'arguments': redactSecrets(arguments),
    'started_at': startedAt.toIso8601String(),
    if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
    if (result != null) 'result': redactSecrets(result!),
  };

  factory AgentStep.fromJson(Map<String, dynamic> value) => AgentStep(
    toolName: value['tool'] as String? ?? '',
    arguments: value['arguments'] as String? ?? '{}',
    startedAt: DateTime.tryParse(value['started_at'] as String? ?? ''),
    finishedAt: DateTime.tryParse(value['finished_at'] as String? ?? ''),
    result: value['result'] as String?,
  );
}

class AgentRun {
  AgentRun({
    String? id,
    required this.task,
    required this.toolName,
    this.model = kCheapModel,
    this.callId = '',
    this.conversationId = '',
    this.status = AgentRunStatus.queued,
    DateTime? createdAt,
    this.startedAt,
    this.finishedAt,
    this.result,
    this.error,
    this.cancellationRequested = false,
    List<AgentStep>? steps,
  }) : id = id ?? newId('agent'),
       createdAt = createdAt ?? DateTime.now(),
       steps = steps ?? [];

  final String id;
  final String task;
  final String toolName;
  final String model;
  final String callId;
  final String conversationId;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  AgentRunStatus status;
  String? result;
  String? error;
  final List<AgentStep> steps;
  bool cancellationRequested;
  bool _cancellable = false;

  bool get terminal =>
      status == AgentRunStatus.completed || status == AgentRunStatus.failed || status == AgentRunStatus.cancelled;
  bool get canCancel => _cancellable && !terminal && !cancellationRequested;

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'task': redactSecrets(task),
    'tool': toolName,
    'model': model,
    'call_id': callId,
    'conversation_id': conversationId,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
    if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
    if (result != null) 'result': redactSecrets(result!),
    if (error != null) 'error': redactSecrets(error!),
    'cancellation_requested': cancellationRequested,
    'steps': [for (final step in steps) step.toJson()],
  };

  factory AgentRun.fromJson(Map<String, dynamic> value) => AgentRun(
    id: value['id'] as String?,
    task: value['task'] as String? ?? '',
    toolName: value['tool'] as String? ?? '',
    model: value['model'] as String? ?? kCheapModel,
    callId: value['call_id'] as String? ?? '',
    conversationId: value['conversation_id'] as String? ?? '',
    status: AgentRunStatus.values.asNameMap()[value['status']] ?? AgentRunStatus.failed,
    createdAt: DateTime.tryParse(value['created_at'] as String? ?? ''),
    startedAt: DateTime.tryParse(value['started_at'] as String? ?? ''),
    finishedAt: DateTime.tryParse(value['finished_at'] as String? ?? ''),
    result: value['result'] as String?,
    error: value['error'] as String?,
    cancellationRequested: value['cancellation_requested'] == true,
    steps: [
      for (final item in value['steps'] as List? ?? const [])
        if (item is Map) AgentStep.fromJson(item.cast<String, dynamic>()),
    ],
  );
}

/// All runs are kept as individual app-data records. Only the newest page is
/// read at startup; older results are available through [loadOlder]. No
/// retention limit deletes history, and recovery never replays work.
class AgentRunStore extends ChangeNotifier {
  AgentRunStore({this.path, this.pageSize = 100});

  final String? path;
  final int pageSize;
  final List<AgentRun> _runs = [];
  final Map<String, VoidCallback> _cancellers = {};
  final List<File> _older = [];
  int _offset = 0;
  bool _restored = false;
  bool _disposed = false;
  bool loading = false;
  String? loadError;
  Future<void> _writes = Future<void>.value();

  List<AgentRun> get runs => List.unmodifiable(_runs);
  bool get hasMore => _offset < _older.length;
  int get activeCount => _runs.where((run) => !run.terminal).length;

  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final directoryPath = path;
    if (directoryPath == null) return;
    try {
      final directory = Directory(directoryPath);
      if (!await directory.exists()) return;
      await for (final entry in directory.list()) {
        if (entry is File && entry.path.endsWith('.json')) _older.add(entry);
      }
      _older.sort((a, b) => b.path.compareTo(a.path));
      await loadOlder();
    } catch (error) {
      loadError = redactSecrets('Could not load agent history: $error');
      _notify();
    }
  }

  Future<void> loadOlder() async {
    if (loading || _disposed || !hasMore) return;
    loading = true;
    _notify();
    final end = (_offset + pageSize).clamp(0, _older.length);
    try {
      while (_offset < end) {
        final file = _older[_offset++];
        try {
          final data = jsonDecode(await file.readAsString());
          if (data is! Map) throw const FormatException('Invalid agent record');
          final run = AgentRun.fromJson(data.cast<String, dynamic>());
          if (_runs.any((existing) => existing.id == run.id)) continue;
          if (!run.terminal) {
            run
              ..status = AgentRunStatus.failed
              ..finishedAt = DateTime.now()
              ..error =
                  'Interrupted by app restart. The final outcome of an already-started action is unknown. '
                  'No action was replayed.';
            _persist(run);
          }
          _runs.add(run);
        } catch (error) {
          loadError = redactSecrets('An agent history record could not be read: $error');
        }
      }
      _runs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } finally {
      loading = false;
      _notify();
    }
  }

  AgentRun create({
    required String task,
    required String toolName,
    String model = kCheapModel,
    String callId = '',
    String conversationId = '',
  }) {
    final run = AgentRun(task: task, toolName: toolName, model: model, callId: callId, conversationId: conversationId);
    _runs.insert(0, run);
    _changed(run);
    return run;
  }

  void setCancellation(AgentRun run, VoidCallback? cancel) {
    if (cancel == null) {
      _cancellers.remove(run.id);
      run._cancellable = false;
    } else {
      _cancellers[run.id] = cancel;
      run._cancellable = true;
    }
    _notify();
  }

  bool cancel(String id) {
    final run = _runs.where((item) => item.id == id).firstOrNull;
    final callback = _cancellers[id];
    if (run == null || !run.canCancel || callback == null) return false;
    run.cancellationRequested = true;
    callback();
    _changed(run);
    return true;
  }

  void cancelAll() {
    for (final run in List<AgentRun>.of(_runs)) {
      if (run.canCancel) cancel(run.id);
    }
  }

  void markRunning(AgentRun run) {
    run
      ..status = AgentRunStatus.running
      ..startedAt ??= DateTime.now();
    _changed(run);
  }

  AgentStep beginStep(AgentRun run, String toolName, String arguments) {
    final step = AgentStep(toolName: toolName, arguments: arguments);
    run.steps.add(step);
    _changed(run);
    return step;
  }

  void finishStep(AgentRun run, AgentStep step, String result) {
    step
      ..result = result
      ..finishedAt = DateTime.now();
    _changed(run);
  }

  void finish(AgentRun run, {required AgentRunStatus status, String? result, String? error}) {
    if (run.terminal) return;
    run
      ..status = status
      ..result = result
      ..error = error
      ..finishedAt = DateTime.now()
      .._cancellable = false;
    _cancellers.remove(run.id);
    _changed(run);
  }

  void _changed(AgentRun run) {
    _persist(run);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _persist(AgentRun run) {
    final directoryPath = path;
    if (directoryPath == null) return;
    final stamp = run.createdAt.microsecondsSinceEpoch.toString().padLeft(20, '0');
    final file = File('$directoryPath/$stamp-${run.id}.json');
    final json = jsonEncode(run.toJson());
    _writes = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(json, flush: true);
        await temporary.rename(file.path);
      } catch (error) {
        loadError = redactSecrets('Could not save agent history: $error');
        _notify();
      }
    });
  }

  Future<void> flush() => _writes;

  @override
  void dispose() {
    _disposed = true;
    _cancellers.clear();
    super.dispose();
  }
}
