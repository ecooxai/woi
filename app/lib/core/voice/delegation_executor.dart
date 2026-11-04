import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../platform/key_chords.dart';
import '../auth/auth.dart';
import '../media/media_context.dart' show isMediaQuestion, cameraCommand;
import '../notes/pinned_note.dart';
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
    this.contextImages,
    this.contextNote,
    this.environment,
    this.pinnedNote,
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

  /// Camera frame and media image (gpt-live keeps them per slot); attached
  /// to every request while fresh ([contextImageMaxAge]).
  final List<DelegationImage> Function()? contextImages;
  static const contextImageMaxAge = Duration(seconds: 45);

  /// Conversation memory (the compaction summary) given to the model with
  /// each request, so a compacted conversation still resolves "that file".
  final String? Function()? contextNote;

  /// Real user, \$HOME and workspace dir (appended to [instructions]).
  final String? Function()? environment;

  /// The conversation note (pinned, current at every delegation).
  final String? Function()? pinnedNote;

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
      'Keys or shortcuts in another app (copy, paste, select all, "press ctrl c", escape): send_keys; it targets the '
      'app the user was using (never Woi), or `window` when the user names one ("in the xterm" -> window "xterm"). '
      'A live camera frame (webcam) or a media image (open in Woi\'s viewer) may be attached: they are not the '
      'screen. Answer questions about what the camera sees or what the media shows directly from that image, in '
      'one or two sentences, without tools. '
      'For complex work (writing code, analysis, long text) call delegate_task; when the user wants code or text '
      'written or saved, say so in the task (it saves files with write_file). '
      'The conversation note is attached: answer questions from it, record decisions, todos, facts and '
      'paths with update_note or note_control (append/insert/replace/delete_text); edits show a short preview and '
      'apply themselves. Other notes (new, switch, rename, delete, list) and the note\'s undo/redo: note_control. '
      'Woi itself (switch view note/chat/terminal/split, settings such as theme, voice, mic mode, terminal tabs, the '
      'media viewer, apply/reject the edit preview, "undo that" = your last note or file edit): app_control. '
      'Never press keys, click or type for a stop, cancel or never-mind request: do nothing. '
      'If no tool fits, answer in one short sentence. Never claim something was done unless a tool result shows it.';

  String get _instructions {
    final env = environment?.call()?.trim();
    return env == null || env.isEmpty ? instructions : '$instructions\n$env';
  }

  /// Tools whose result the model must see before it can act or answer.
  static const observeTools = {'take_screenshot', 'list_dir', 'read_file', 'read_note', 'inspect_media', 'camera'};

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
    r'(?:\s+(?:file|video|movie|clip|image|picture|photo|song|audio|sound|track|document)){0,2}'
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

  static final _typeRequest = RegExp(
    r'^\s*(?:(?:ok(?:ay)?|please|can you|could you|now)[\s,]+)*type(?:\s+out)?(?:\s+(?:the\s+)?(?:text|words?))?[\s:,]+(.+?)\s*$',
    caseSensitive: false,
  );
  static final _generative = RegExp(
    r"\b(a|an|some|the|my|your|this|that|summary|poem|email|letter|code|reply|answer|about|list|it|me)\b",
    caseSensitive: false,
  );

  /// Literal text of a plain "type X" request (quoted, or a few words that
  /// are clearly the text itself), or null when the text must be written
  /// first ("type a short email to Bob"). Such requests skip the model.
  static String? typeFastPath(String request) {
    final m = _typeRequest.firstMatch(request);
    if (m == null) return null;
    var body = m.group(1)!.trim();
    final quoted = RegExp('["\'“”‘’]').hasMatch(body);
    body = body.replaceAll(RegExp('^["\'“”‘’]+|["\'“”‘’.!?]+\$'), '').trim();
    final tail = RegExp(r'\s+(?:please|for me|now)\$', caseSensitive: false);
    body = body.replaceAll(tail, '').trim();
    if (body.isEmpty || body.length > 200) return null;
    if (!quoted && (body.split(RegExp(r'\s+')).length > 4 || _generative.hasMatch(body))) return null;
    return body;
  }

  static final _politePrefix = RegExp(
    r'^\s*(?:(?:ok(?:ay)?|please|now|so|and|then|hey|woi|can you|could you|would you)[\s,]+)*',
    caseSensitive: false,
  );
  static final _windowSuffix = RegExp(
    r'\s+(?:in|into|on|inside)\s+(?:the\s+)?([\w .-]+?)(?:\s+(?:window|app|application|terminal window))?$',
    caseSensitive: false,
  );
  static final _pressRequest = RegExp(
    r'^(?:press|hit|push|tap|send)(?:\s+the)?\s+(.+?)(?:\s+(?:keys?|button|shortcut|combination|combo))?$',
    caseSensitive: false,
  );
  static final _keyActions = <(RegExp, List<KeyAction>)>[
    (RegExp(r'^copy\s+(?:all|everything)(?:\s+(?:the\s+)?text)?$'), [KeyAction.selectAll, KeyAction.copy]),
    (RegExp(r'^copy(?:\s+(?:that|this|it|the\s+selection|selection|the\s+selected\s+text|the\s+text))?$'), [KeyAction.copy]),
    (RegExp(r'^paste(?:\s+(?:that|this|it|the\s+clipboard|clipboard))?(?:\s+here)?$'), [KeyAction.paste]),
    (RegExp(r'^cut(?:\s+(?:that|this|it|the\s+selection|selection))?$'), [KeyAction.cut]),
    (RegExp(r'^(?:select|highlight|mark)\s+(?:all|everything)(?:\s+(?:the\s+)?text)?$'), [KeyAction.selectAll]),
    (RegExp(r'^(?:press\s+)?esc(?:ape)?$'), [KeyAction.escape]),
  ];

  /// App-control calls for plain requests ("undo that", "switch to
  /// terminal", "dark mode", "add buy milk to my note"), as (tool, args).
  static List<(String, Map<String, Object?>)>? appFastPath(String request) {
    var t = request.trim().toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '').trim();
    t = t.replaceFirst(RegExp(r"^(?:(?:ok(?:ay)?|hey|woi|please|now|so|and|then)[\s,]+)*"), '');
    t = t.replaceFirst(RegExp(r"^(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|go\s+ahead\s+and\s+)"), '');
    t = t.replaceFirst(RegExp(r'\s+please$'), '').trim();
    if (RegExp(r"^(?:undo|revert|take back|roll back)(?:\s+(?:it|that|this|the (?:last )?(?:edit|change)|your (?:last )?(?:edit|change)))?$").hasMatch(t)) {
      return [('app_control', {'action': 'undo_edit'})];
    }
    if (RegExp(r'^(?:apply|accept|approve)(?:\s+(?:it|that|the (?:edit|change)))?(?:\s+now)?$').hasMatch(t)) {
      return [('app_control', {'action': 'apply_edit'})];
    }
    if (RegExp(r'^(?:reject|discard|decline)(?:\s+(?:it|that|the (?:edit|change)))?$|^cancel the (?:edit|change)$').hasMatch(t)) {
      return [('app_control', {'action': 'reject_edit'})];
    }
    final view = RegExp(
      r'^(?:switch|go|change|flip|jump)\s+(?:back\s+)?to\s+(?:the\s+)?(terminal|chat|note|notes|split|side by side)(?:\s+(?:view|tab|panel|screen|mode))?$'
      r'|^(?:show|open)\s+(?:me\s+)?(?:the\s+)?(terminal|chat|split)(?:\s+(?:view|tab|panel|screen))?$'
      r'|^(?:show|open)\s+(?:me\s+)?(?:the\s+)?(note|notes)\s+(?:view|tab|panel|screen)$',
    ).firstMatch(t);
    if (view != null) {
      final v = view.group(1) ?? view.group(2) ?? view.group(3)!;
      return [('app_control', {'action': 'show_view', 'view': v})];
    }
    final theme = RegExp(
      r'^(?:(?:change|set|switch|make|turn|put)\s+(?:the\s+)?(?:theme|app|woi|it|appearance|colou?rs?)?\s*(?:to|into|in)?\s*(?:the\s+)?)?'
      r'(dark|light|system)(?:\s+(?:mode|theme))?$'
      r'|^(?:change|set|switch)\s+(?:the\s+)?theme\s+to\s+(?:the\s+)?(dark|light|system)(?:\s+(?:mode|theme|one))?$'
      r'|^(?:switch|go|change)\s+to\s+(dark|light|system)\s+(?:mode|theme)$',
    ).firstMatch(t);
    if (theme != null && RegExp(r'theme|mode|change|set|switch|make|turn|put').hasMatch(t)) {
      final v = theme.group(1) ?? theme.group(2) ?? theme.group(3)!;
      return [('app_control', {'action': 'set_setting', 'key': 'theme', 'value': v})];
    }
    final mic = RegExp(r'^(?:mute|unmute)\s+(?:the\s+)?(?:mic|microphone)$').firstMatch(t);
    if (mic != null) {
      final on = t.startsWith('un');
      return [('app_control', {'action': 'set_setting', 'key': 'mic_mode', 'value': on ? 'hands_free' : 'muted'})];
    }
    if (RegExp(r'^(?:start|create|make|open)\s+(?:a\s+)?new\s+note$|^new note$').hasMatch(t)) {
      return [('note_control', {'action': 'new'})];
    }
    if (RegExp(r'^(?:open|start|create)\s+(?:a\s+)?new\s+(?:terminal|shell)(?:\s+tab)?$|^new\s+terminal\s+tab$').hasMatch(t)) {
      return [('app_control', {'action': 'terminal_new'})];
    }
    // "add 'buy milk' to my note" (original casing for the text).
    final add = RegExp(
      r'''^(?:(?:ok(?:ay)?|please|now)[\s,]+)*(?:add|append|put|write(?:\s+down)?|jot(?:\s+down)?)\s+(.+?)\s+(?:to|in|into|on|at the end of)\s+(?:my|the|this)\s+(?:note|notes|todo list|to-do list|list|shopping list)$''',
      caseSensitive: false,
    ).firstMatch(request.trim().replaceAll(RegExp(r'[.!?]+$'), ''));
    if (add != null) {
      var text = add.group(1)!.trim();
      final q = RegExp(r'''^["'‘“](.+)["'’”]$''').firstMatch(text);
      if (q != null) text = q.group(1)!.trim();
      if (text.isEmpty || text.length > 200 || RegExp(r'\b(?:that|this|it|the (?:summary|result|answer|output))$').hasMatch(text.toLowerCase())) {
        return null; // refers to something: let the model write it
      }
      if (!text.contains('\n') && !RegExp(r'^[-*#]|^\d+[.)]').hasMatch(text)) text = '- $text';
      return [('note_control', {'action': 'append', 'text': text})];
    }
    return null;
  }

  /// `send_keys` calls for a plain key request ("press ctrl c", "copy that",
  /// "paste", "select all and copy in the xterm", "press escape"), or null.
  /// Undo/redo are not here: "undo that" undoes Woi's own last edit.
  static List<Map<String, Object?>>? keysFastPath(String request) {
    var t = request.trim().replaceAll(RegExp(r'[\s.!?]+$'), '').replaceFirst(_politePrefix, '');
    t = t.replaceAll(RegExp(r'\s+(?:please|for me|now)$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s+(?:to|into)\s+(?:the\s+)?clipboard$', caseSensitive: false), '');
    String? window;
    final w = _windowSuffix.firstMatch(t);
    if (w != null) {
      window = w[1]!.trim();
      t = t.substring(0, w.start).trim();
    }
    if (t.isEmpty) return null;
    Map<String, Object?> call(Map<String, Object?> a) => {...a, 'window': ?window};
    final press = _pressRequest.firstMatch(t);
    if (press != null) {
      final keys = press[1]!.trim();
      try {
        parseKeySequence(keys);
      } on FormatException {
        return null;
      }
      return [call({'keys': keys})];
    }
    final out = <Map<String, Object?>>[];
    for (final part in t.toLowerCase().split(RegExp(r'\s*(?:,|\band then\b|\bthen\b|\band\b)\s*'))) {
      if (part.isEmpty) continue;
      final hit = _keyActions.where((a) => a.$1.hasMatch(part)).firstOrNull;
      if (hit == null) return null;
      out.addAll([for (final a in hit.$2) call({'action': a.wire})]);
    }
    return out.isEmpty ? null : out;
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
    // Fast path: "open camera" / "close camera".
    final cam = cameraCommand(request);
    if (cam != null && tools.any((t) => t.name == 'camera')) {
      await _exec(report, sw, 'camera', jsonEncode({'action': cam ? 'open' : 'close'}), 'fast_${report.id}');
      final run = report.tools.last;
      report
        ..model = 'fast-path'
        ..steps = 0
        ..firstToolCall = run.startedAt
        ..toolsDone = run.doneAt
        ..resultText = _summarize(report, const []);
      return;
    }
    // "what's in this image / what is this song": look at the open media
    // first (the image lands in [contextImages], audio comes back as text),
    // then let the model answer with it.
    String? mediaResult;
    if (isMediaQuestion(request) && tools.any((t) => t.name == 'inspect_media')) {
      await _exec(report, sw, 'inspect_media', jsonEncode({'question': request}), 'media_${report.id}');
      mediaResult = report.tools.last.resultJson;
    }
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
    // Fast path: "type 'hello world'" goes straight to the focused window
    // (the model sometimes clicked somewhere first and never typed).
    final typed = typeFastPath(request);
    if (typed != null && tools.any((t) => t.name == 'type_text')) {
      await _exec(report, sw, 'type_text', jsonEncode({'text': typed}), 'fast_${report.id}');
      final run = report.tools.last;
      report
        ..model = 'fast-path'
        ..steps = 0
        ..firstToolCall = run.startedAt
        ..toolsDone = run.doneAt
        ..resultText = _summarize(report, const []);
      return;
    }
    // Fast path: "undo that", "switch to terminal", "dark mode", "add X to my note".
    final appCalls = appFastPath(request);
    if (appCalls != null && appCalls.every((c) => tools.any((t) => t.name == c.$1))) {
      final n = report.tools.length;
      for (final (i, (name, a)) in appCalls.indexed) {
        await _exec(report, sw, name, jsonEncode(a), 'app${i}_${report.id}');
        if (!report.tools.last.ok) break;
      }
      report
        ..model = 'fast-path'
        ..steps = 0
        ..firstToolCall = report.tools[n].startedAt
        ..toolsDone = report.tools.last.doneAt
        ..resultText = _summarize(report, const []);
      return;
    }
    // Fast path: "copy that", "press ctrl c", "select all and copy".
    final keyCalls = keysFastPath(request);
    if (keyCalls != null && tools.any((t) => t.name == 'send_keys')) {
      final n = report.tools.length;
      for (final (i, a) in keyCalls.indexed) {
        await _exec(report, sw, 'send_keys', jsonEncode(a), 'fast${i}_${report.id}');
        if (!report.tools.last.ok) break;
      }
      report
        ..model = 'fast-path'
        ..steps = 0
        ..firstToolCall = report.tools[n].startedAt
        ..toolsDone = report.tools.last.doneAt
        ..resultText = _summarize(report, const []);
      return;
    }
    final extras = _freshContextImages();
    // A question about the open media or the camera is answered from their
    // images; the screen is only waited for when the request names it.
    final aboutContext =
        (mediaResult != null || (extras.isNotEmpty && !looksLikeAction(request))) &&
        !RegExp(r'\bscreen|\bwindow|\bdesktop|\bclick').hasMatch(request);
    final visual = needsScreen(request) && !aboutContext;
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
        if (!(shot != null && t.name == 'take_screenshot') && !(mediaResult != null && t.name == 'inspect_media'))
          t.toJson(),
    ];

    final input = <Map<String, Object?>>[
      _userMessage(
        mediaResult == null ? request : '$request\n(inspect_media result: $mediaResult)',
        shot,
        extras: extras,
      ),
    ];
    if (extras.isNotEmpty) report.usedScreenshot = true;
    report.usedScreenshot = report.usedScreenshot || shot != null;
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
      if (names.contains('inspect_media')) {
        final media = _freshContextImages().where((i) => !extras.contains(i)).toList();
        if (media.isNotEmpty) input.add(_userMessage('The media image.', null, extras: media));
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

  List<DelegationImage> _freshContextImages() {
    final now = _now();
    return [
      for (final i in contextImages?.call() ?? const <DelegationImage>[])
        if (now.difference(i.capturedAt) <= contextImageMaxAge) i,
    ];
  }

  static String _dataUrl(Uint8List b) =>
      'data:${b.length > 2 && b[0] == 0xFF && b[1] == 0xD8 ? 'image/jpeg' : 'image/png'};base64,${base64Encode(b)}';

  Map<String, Object?> _userMessage(String text, DelegationImage? shot, {List<DelegationImage> extras = const []}) {
    final note = contextNote?.call()?.trim();
    final pinned = pinnedNote?.call();
    return {
      'type': 'message',
      'role': 'user',
      'content': [
        if (pinned != null) {'type': 'input_text', 'text': pinnedNoteBlock(pinned)},
        if (note != null && note.isNotEmpty)
          {'type': 'input_text', 'text': 'Conversation memory (background only):\n$note'},
        for (final x in extras) ...[
          {'type': 'input_image', 'image_url': _dataUrl(x.png)},
          if (x.note != null) {'type': 'input_text', 'text': '(${x.note})'},
        ],
        if (shot != null) {'type': 'input_image', 'image_url': _dataUrl(shot.png)},
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

final _actionRequest = RegExp(
  r"^(?:(?:ok(?:ay)?|hey|woi|please|now|so|and|then)[\s,]+)*"
  r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:want|need)\s+you\s+to\s+|"
  r"(?:i'?d\s+like\s+you\s+to|go\s+ahead\s+and|try\s+to)\s+|let'?s\s+)?"
  r"(?:open|show|display|play|pause|click|double[- ]click|right[- ]click|type|enter|run|execute|edit|write|"
  r"create|make|delete|remove|rename|move|copy|list|read|find|search|look\s+up|press|hit|scroll|close|"
  r"save|take|capture|launch|start|stop\s+the|install|download|go\s+to|navigate|select|drag|paste|"
  r"append|add|insert|replace|change|set|turn|switch|maximi[sz]e|minimi[sz]e|focus|check|count|send|"
  r"fill|submit|upload|zip|unzip|extract|print|cd|ls|cat|grep|mkdir|touch|undo|redo|apply|reject|cut|"
  r"highlight|resume|seek|skip|rewind|use|new|tap|push)\b",
  caseSensitive: false,
);

/// Whether typed text asks the assistant to *do* something on the computer
/// (gpt-live never delegates typed text itself, so the app runs it).
bool looksLikeAction(String text) => _actionRequest.hasMatch(text.trim());
