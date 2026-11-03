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
  DateTime _lastUse = DateTime(2000);

  Future<void> warmUp() {
    _lastUse = DateTime.now();
    return client.warmUp();
  }

  /// Re-opens the kept-alive connection if it has been idle long enough that
  /// the server may have dropped it (called when the user starts talking, so
  /// the TLS handshake is done before `delegation.created`).
  Future<void> warmUpIfIdle({Duration idle = const Duration(seconds: 40)}) async {
    if (DateTime.now().difference(_lastUse) < idle) return;
    await warmUp();
  }

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
    _lastUse = DateTime.now();
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
  DelegationReport({required this.id, required this.request}) : createdAt = DateTime.now();
  final String id;
  final String request;

  /// Wall clock when the delegation started (≈ `delegation.created` receipt).
  final DateTime createdAt;
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
    this.contextNote,
    this.environment,
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

  /// Conversation memory (the compaction summary) given to the model with
  /// each request, so a compacted conversation still resolves "that file".
  final String? Function()? contextNote;

  /// Real user, \$HOME and workspace dir (appended to [instructions]).
  final String? Function()? environment;

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
      'The request is transcribed speech: "readme dot md" means README.md. Relative paths resolve against the workspace dir given below; use only the real paths given there. '
      'Show, open, view or play a file: show_file. Never change files with run_bash: read_file, then edit_file '
      '(the user approves a diff). '
      'click_screen coordinates are pixels of the attached screenshot. '
      'For complex work (writing code, analysis, long text) call delegate_task; when the user wants code or text '
      'written or saved, say so in the task (it saves files with write_file). '
      'Never press keys, click or type for a stop, cancel or never-mind request: do nothing. '
      'If no tool fits, answer in one short sentence. Never claim something was done unless a tool result shows it.';

  String get _instructions {
    final env = environment?.call()?.trim();
    return env == null || env.isEmpty ? instructions : '$instructions\n$env';
  }

  /// Tools whose result the model must see before it can act or answer.
  static const observeTools = {'take_screenshot', 'list_dir', 'read_file'};

  /// Read-only shell commands (locating / inspecting files).
  static final _lookupCommand = RegExp(
    r'^\s*(find|ls|locate|which|whereis|stat|file|cat|head|tail|grep|rg|fd|test|readlink|realpath|du|wc)\b',
  );
  static final _explicitCommand = RegExp(r'\b(run|execute|command)\b', caseSensitive: false);

  /// Whether [c] only gathers information the model needs to finish the
  /// request (so its result is fed back for another step). A shell lookup
  /// the user asked for ("run ls") is the action itself.
  static bool isObservation(DelegationToolCall c, String request) {
    if (observeTools.contains(c.name)) return true;
    if (c.name != 'run_bash' || _explicitCommand.hasMatch(request)) return false;
    try {
      final cmd = (jsonDecode(c.arguments) as Map)['command'];
      return cmd is String && _lookupCommand.hasMatch(cmd) && !cmd.contains('>');
    } catch (_) {
      return false;
    }
  }

  static final _showRequest = RegExp(
    r'^\s*(?:please\s+)?(?:show|open|view|display|play)(?:\s+me)?(?:\s+the)?'
    r'(?:\s+(?:file|video|movie|clip|image|picture|photo|song|audio|track|document))?'
    r'(?:\s+(?:called|named))?\s+(.+?)[\s.!?]*$',
    caseSensitive: false,
  );
  static const _spokenDigits = {
    'zero': '0',
    'one': '1',
    'two': '2',
    'three': '3',
    'four': '4',
    'five': '5',
    'six': '6',
    'seven': '7',
    'eight': '8',
    'nine': '9',
  };

  /// File path of a plain "show / open / play FILE" request, with spoken
  /// names normalized ("readme dot md" → readme.md, "demo dot mp four" →
  /// demo.mp4), or null. Such requests skip the model ([execute] fast path).
  static String? showFastPath(String request) {
    final m = _showRequest.firstMatch(request.replaceAll(RegExp('[“”"]'), ''));
    if (m == null) return null;
    var name = m.group(1)!.trim();
    name = name.replaceAllMapped(
      RegExp(
        r'\s+dot\s+([a-z0-9]+)((?:\s+(?:zero|one|two|three|four|five|six|seven|eight|nine))*)',
        caseSensitive: false,
      ),
      (d) =>
          '.${d[1]}${d[2]!.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => _spokenDigits[w.toLowerCase()]).join()}',
    );
    final file = RegExp(r'^[~/\w.-]*\w\.[A-Za-z0-9]{1,5}$');
    return file.hasMatch(name) ? name : null;
  }

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

  /// Requests that refer to what is on screen (and so need the image).
  static final _visual = RegExp(
    r"\b(click|tap|press|screen|see|look|visible|button|icon|window|tab|menu|link|field|dialog|popup|this|that|"
    r"these|those|here|there|top|bottom|left|right|corner|center|centre|middle|scroll|select|highlight|drag|hover|"
    r"image|picture|photo|describe|what'?s on|what is on|showing|open (it|the one)|close (it|this|that))\b",
    caseSensitive: false,
  );

  /// Whether [request] needs the screenshot (otherwise it is not sent: the
  /// image upload and its tokens cost several hundred ms).
  static bool needsScreen(String request) => _visual.hasMatch(request);

  Future<void> _run(String request, DelegationReport report, Stopwatch sw) async {
    // Fast path: "show me README.md" needs no model round trip.
    final fastPath = showFastPath(request);
    if (fastPath != null && tools.any((t) => t.name == 'show_file')) {
      final n = report.tools.length;
      final run = await _showFast(report, sw, fastPath);
      if (run != null) {
        report.tools
          ..removeRange(n, report.tools.length)
          ..add(run);
        report
          ..model = 'fast-path'
          ..steps = 0
          ..firstToolCall = report.tools[n].startedAt
          ..toolsDone = run.doneAt
          ..resultText = _summarize(report, const []);
        return;
      }
      report.tools.removeRange(n, report.tools.length); // not found: let the model look
    }
    final visual = needsScreen(request);
    final hasScreenshotTool = tools.any((t) => t.name == 'take_screenshot');

    var shot = latestScreenshot?.call();
    Future<void>? capture;
    if (hasScreenshotTool && (shot == null || _now().difference(shot.capturedAt) > freshScreenshotAfter)) {
      // No usable screenshot: capture through the app so it is attached to
      // the conversation and click_screen maps coordinates against it. Only
      // visual requests wait for it; the others start the model right away.
      report.freshCapture = true;
      capture = _exec(report, sw, 'take_screenshot', '{}', 'shot_${report.id}');
      if (visual) {
        await capture;
        shot = latestScreenshot?.call();
      } else {
        shot = null;
      }
    } else if (!visual) {
      shot = null;
    }
    // With the image attached, a take_screenshot call would only cost
    // another round trip; without it the model can still ask for a look.
    final specs = [
      for (final t in tools)
        if (!(shot != null && t.name == 'take_screenshot')) t.toJson(),
    ];

    final input = <Map<String, Object?>>[_userMessage(request, shot)];
    report.usedScreenshot = shot != null;
    final texts = <String>[];

    for (var step = 0; step < maxSteps; step++) {
      report.steps = step + 1;
      // Execute calls in arrival order as they stream in.
      var chain = Future<void>.value();
      final turn = await model.respond(
        model: fastModel,
        instructions: _instructions,
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
      final needsLook = turn.calls.every((c) => isObservation(c, request));
      if (!needsLook || step == maxSteps - 1) break;

      // Observation step: feed results (and a fresh screenshot) back.
      for (final c in turn.calls) {
        final run = report.tools.lastWhere(
          (t) => t.name == c.name,
          orElse: () => DelegationToolRun(c.name, '', sw.elapsed),
        );
        input
          ..add({'type': 'function_call', 'call_id': c.callId, 'name': c.name, 'arguments': c.arguments})
          ..add({'type': 'function_call_output', 'call_id': c.callId, 'output': run.resultJson ?? '{"ok":false}'});
      }
      if (names.contains('take_screenshot')) {
        final s = latestScreenshot?.call();
        if (s != null) input.add(_userMessage('Fresh screenshot.', s));
      }
    }
    await capture;
    report.resultText = _summarize(report, texts);
  }

  /// show_file([path]); if missing, retries with a case-insensitive match
  /// in its directory (speech gives "readme.md" for README.md). Returns the
  /// successful run or null.
  Future<DelegationToolRun?> _showFast(DelegationReport report, Stopwatch sw, String path) async {
    await _exec(report, sw, 'show_file', jsonEncode({'path': path}), 'fast_${report.id}');
    if (report.tools.last.ok || !tools.any((t) => t.name == 'list_dir')) {
      return report.tools.last.ok ? report.tools.last : null;
    }
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '~' : (slash == 0 ? '/' : path.substring(0, slash));
    final base = path.substring(slash + 1).toLowerCase();
    await _exec(report, sw, 'list_dir', jsonEncode({'path': dir}), 'fast_ls_${report.id}');
    String? match;
    try {
      final entries = (jsonDecode(report.tools.last.resultJson ?? '{}') as Map)['entries'];
      if (entries is List) {
        for (final e in entries.whereType<Map>()) {
          if (e['t'] != 'd' && '${e['name']}'.toLowerCase() == base) match = '${e['name']}';
        }
      }
    } catch (_) {}
    if (match == null) return null;
    final full = slash < 0 ? match : '${path.substring(0, slash + 1)}$match';
    await _exec(report, sw, 'show_file', jsonEncode({'path': full}), 'fast2_${report.id}');
    return report.tools.last.ok ? report.tools.last : null;
  }

  Map<String, Object?> _userMessage(String text, DelegationImage? shot) {
    final note = contextNote?.call()?.trim();
    return {
      'type': 'message',
      'role': 'user',
      'content': [
        if (note != null && note.isNotEmpty)
          {'type': 'input_text', 'text': 'Conversation memory (background only):\n$note'},
        if (shot != null) {'type': 'input_image', 'image_url': 'data:image/png;base64,${base64Encode(shot.png)}'},
        {'type': 'input_text', 'text': shot?.note == null ? text : '$text\n(${shot!.note})'},
      ],
    };
  }

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
      if (j is Map) {
        return j.entries.map((e) => '${e.key}=${e.value is String ? jsonEncode(e.value) : e.value}').join(', ');
      }
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
