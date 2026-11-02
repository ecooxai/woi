import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../auth/auth.dart';
import '../responses/responses_client.dart';
import 'voice_backend.dart';

// ---------------------------------------------------------------- model API

/// A function call produced by the delegation model.
class DelegationToolCall {
  const DelegationToolCall({required this.callId, required this.name, required this.arguments});
  final String callId;
  final String name;
  final String arguments;
}

/// One completed model turn.
class DelegationModelTurn {
  const DelegationModelTurn({required this.text, required this.calls, this.firstEvent, this.usage});
  final String text;
  final List<DelegationToolCall> calls;

  /// Time from request start to the first streamed output item.
  final Duration? firstEvent;
  final Map<String, Object?>? usage;
}

class DelegationModelException implements Exception {
  DelegationModelException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'DelegationModelException(${status ?? '-'}): $message';
}

/// The text model that resolves delegations (Responses API, §4).
abstract class DelegationModel {
  /// Runs one streamed turn. [onToolCall] fires as soon as each function
  /// call item is complete, before the response finishes, so the caller can
  /// start executing early.
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  });

  void close() {}
}

/// [DelegationModel] over the shared [ResponsesClient] with a kept-alive
/// connection (no TLS handshake per delegation) and early tool execution.
class ResponsesDelegationModel implements DelegationModel {
  ResponsesDelegationModel(Future<Credentials?> Function() credentials, {Uri? endpoint})
    : client = ResponsesClient(credentials: credentials, codexEndpoint: endpoint, reuseConnections: true);

  final ResponsesClient client;

  Future<void> warmUp() => client.warmUp();

  @override
  Future<DelegationModelTurn> respond({
    required String model,
    required String instructions,
    required List<Map<String, Object?>> input,
    List<Map<String, Object?>> tools = const [],
    String? reasoningEffort,
    void Function(DelegationToolCall call)? onToolCall,
  }) async {
    final ResponsesResult r;
    try {
      r = await client.create(
        model: model,
        instructions: instructions,
        input: input,
        tools: tools,
        reasoning: reasoningEffort == null ? null : {'effort': reasoningEffort},
        parallelToolCalls: true,
        onFunctionCall: onToolCall == null
            ? null
            : (c) => onToolCall(DelegationToolCall(callId: c.callId, name: c.name, arguments: c.arguments)),
      );
    } on ResponsesException catch (e) {
      throw DelegationModelException(e.message, status: e.status);
    }
    return DelegationModelTurn(
      text: r.text.trim(),
      calls: [
        for (final c in r.functionCalls) DelegationToolCall(callId: c.callId, name: c.name, arguments: c.arguments),
      ],
      firstEvent: r.timeToFirstToken ?? r.timeToFirstEvent,
      usage: r.usage,
    );
  }

  @override
  void close() => client.close();
}

// ---------------------------------------------------------------- executor

/// Screenshot the delegation model gets to see.
class DelegationImage {
  const DelegationImage({required this.png, required this.capturedAt, this.note});
  final Uint8List png;
  final DateTime capturedAt;
  final String? note;
}

/// Runs a registry tool (through the app's confirmation UI) and returns the
/// compact JSON result.
typedef DelegationToolRunner = Future<String> Function(String callId, String name, String argsJson);

class DelegationToolRun {
  DelegationToolRun(this.name, this.argsJson, this.startedAt);
  final String name;
  final String argsJson;
  final Duration startedAt;
  Duration? doneAt;
  String? resultJson;

  bool get ok {
    final r = resultJson;
    if (r == null) return false;
    try {
      final j = jsonDecode(r);
      return j is Map && j['ok'] != false;
    } catch (_) {
      return false;
    }
  }
}

/// Outcome + timings of one delegation (all durations from `delegation.created`).
class DelegationReport {
  DelegationReport({required this.id, required this.request});
  final String id;
  final String request;
  String model = '';
  int steps = 0;
  bool usedScreenshot = false;
  bool freshCapture = false;
  final List<DelegationToolRun> tools = [];
  String resultText = '';
  Object? error;

  Duration? firstModelEvent;
  Duration? firstToolCall;
  Duration? toolsDone;
  Duration? total;

  /// Filled by the backend: ack of `delegation.context.append` and first
  /// assistant words after it.
  Duration? appended;
  Duration? spoken;

  bool get ok => error == null;

  String timingSummary() {
    String f(Duration? d) => d == null ? '-' : '${d.inMilliseconds}ms';
    return 'model=$model steps=$steps tools=[${tools.map((t) => t.name).join(',')}] '
        'first_event=${f(firstModelEvent)} first_tool=${f(firstToolCall)} tools_done=${f(toolsDone)} '
        'result=${f(total)} appended=${f(appended)} spoken=${f(spoken)}';
  }
}

/// Resolves gpt-live `delegation.created` requests on the client (server-side
/// delegation is broken, §3.3): a short streamed Responses tool loop with the
/// latest screenshot and the app's tool specs, executing tools as soon as each
/// call is complete. Returns a concise result for `delegation.context.append`.
class DelegationExecutor {
  DelegationExecutor({
    required this.model,
    required this.tools,
    required this.runTool,
    this.latestScreenshot,
    this.fastModel = 'gpt-6-luna',
    this.reasoningEffort = 'low',
    this.maxSteps = 4,
    this.freshScreenshotAfter = const Duration(seconds: 20),
    this.maxResultChars = 2400,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DelegationModel model;
  final List<ToolSpec> tools;
  final DelegationToolRunner runTool;
  final DelegationImage? Function()? latestScreenshot;

  /// Model for the tool loop. Complex work is escalated by the model itself
  /// through `delegate_task` (the app's DelegateBackend, gpt-6.1-sol).
  final String fastModel;
  final String? reasoningEffort;
  final int maxSteps;
  final Duration freshScreenshotAfter;
  final int maxResultChars;
  final DateTime Function() _now;

  static const instructions =
      'You carry out a voice assistant\'s request on the user\'s Linux desktop by calling tools. '
      'Act at once, never ask questions. Call every tool the current step needs in one reply. '
      'click_screen coordinates are pixels of the attached screenshot. '
      'For complex work (writing code, analysis, long text) call delegate_task. '
      'If no tool fits, answer in one short sentence.';

  /// Tools whose result the model must see before it can act or answer.
  static const observeTools = {'take_screenshot', 'list_dir'};

  int _seq = 0;

  Future<DelegationReport> execute(String request, {String? id}) async {
    final sw = Stopwatch()..start();
    final report = DelegationReport(id: id ?? 'dlg_${++_seq}', request: request)..model = fastModel;
    try {
      await _run(request, report, sw);
    } catch (e) {
      report.error = e;
      report.resultText = 'Failed: ${_clip('$e', 300)}';
    }
    report.total = sw.elapsed;
    return report;
  }

  Future<void> _run(String request, DelegationReport report, Stopwatch sw) async {
    final specs = [for (final t in tools) t.toJson()];
    final hasScreenshotTool = tools.any((t) => t.name == 'take_screenshot');

    var shot = latestScreenshot?.call();
    if (hasScreenshotTool && (shot == null || _now().difference(shot.capturedAt) > freshScreenshotAfter)) {
      // No usable screenshot yet: capture through the app so it is attached
      // to the conversation and click_screen maps coordinates against it.
      report.freshCapture = true;
      await _exec(report, sw, 'take_screenshot', '{}', 'shot_${report.id}');
      shot = latestScreenshot?.call();
    }

    final input = <Map<String, Object?>>[_userMessage(request, shot)];
    report.usedScreenshot = shot != null;
    final texts = <String>[];

    for (var step = 0; step < maxSteps; step++) {
      report.steps = step + 1;
      // Execute calls in arrival order as they stream in.
      var chain = Future<void>.value();
      final turn = await model.respond(
        model: fastModel,
        instructions: instructions,
        input: input,
        tools: specs,
        reasoningEffort: reasoningEffort,
        onToolCall: (c) {
          report.firstToolCall ??= sw.elapsed;
          chain = chain.then((_) => _exec(report, sw, c.name, c.arguments, c.callId));
        },
      );
      report.firstModelEvent ??= turn.firstEvent;
      await chain;
      if (turn.text.isNotEmpty) texts.add(turn.text);
      if (turn.calls.isEmpty) break;
      report.toolsDone = sw.elapsed;

      final names = turn.calls.map((c) => c.name).toSet();
      final needsLook = names.every(observeTools.contains);
      if (!needsLook || step == maxSteps - 1) break;

      // Observation step: feed results (and a fresh screenshot) back.
      for (final c in turn.calls) {
        final run = report.tools.lastWhere((t) => t.name == c.name, orElse: () => DelegationToolRun(c.name, '', sw.elapsed));
        input
          ..add({'type': 'function_call', 'call_id': c.callId, 'name': c.name, 'arguments': c.arguments})
          ..add({'type': 'function_call_output', 'call_id': c.callId, 'output': run.resultJson ?? '{"ok":false}'});
      }
      if (names.contains('take_screenshot')) {
        final s = latestScreenshot?.call();
        if (s != null) input.add(_userMessage('Fresh screenshot.', s));
      }
    }
    report.resultText = _summarize(report, texts);
  }

  Map<String, Object?> _userMessage(String text, DelegationImage? shot) => {
    'type': 'message',
    'role': 'user',
    'content': [
      if (shot != null) {'type': 'input_image', 'image_url': 'data:image/png;base64,${base64Encode(shot.png)}'},
      {'type': 'input_text', 'text': shot?.note == null ? text : '$text\n(${shot!.note})'},
    ],
  };

  Future<void> _exec(DelegationReport report, Stopwatch sw, String name, String args, String callId) async {
    final run = DelegationToolRun(name, args, sw.elapsed);
    report.tools.add(run);
    try {
      run.resultJson = await runTool(callId, name, args);
    } catch (e) {
      run.resultJson = jsonEncode({'ok': false, 'error': '$e'});
    }
    run.doneAt = sw.elapsed;
  }

  String _summarize(DelegationReport r, List<String> texts) {
    final b = StringBuffer();
    final runs = r.tools.where((t) => !(r.freshCapture && identical(t, r.tools.first)));
    if (runs.isNotEmpty) {
      b.write(runs.every((t) => t.ok) ? 'Done. ' : 'Not fully done. ');
      for (final t in runs) {
        b.write('${t.name}(${_clip(_compactArgs(t.argsJson), 200)}) -> ${_compactResult(t.resultJson)}\n');
      }
    }
    if (texts.isNotEmpty) b.write(texts.join(' '));
    final s = b.toString().trim();
    return _clip(s.isEmpty ? 'Nothing to do.' : s, maxResultChars);
  }

  static String _compactArgs(String json) {
    try {
      final j = jsonDecode(json);
      if (j is Map) return j.entries.map((e) => '${e.key}=${e.value is String ? jsonEncode(e.value) : e.value}').join(', ');
    } catch (_) {}
    return json;
  }

  String _compactResult(String? json) {
    if (json == null) return 'no result';
    try {
      final j = jsonDecode(json);
      if (j is Map) {
        if (j['denied'] == true) return 'the user declined';
        final m = Map.of(j)..remove('ok');
        if (m.isEmpty) return 'ok';
        return _clip(jsonEncode(m), 1500);
      }
    } catch (_) {}
    return _clip(json, 1500);
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n - 1)}…';
}
