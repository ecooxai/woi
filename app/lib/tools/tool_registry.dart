import 'dart:async';
import 'dart:convert';

import '../core/models/message.dart';
import '../core/voice/voice_backend.dart';

/// Thrown by a handler when the user rejected the action.
class ToolDenied implements Exception {
  ToolDenied([this.reason = 'rejected by user']);
  final String reason;
  @override
  String toString() => reason;
}

/// Thrown by a handler for bad input or failed actions; message goes to the model.
class ToolFailure implements Exception {
  ToolFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Per-call information passed to handlers.
class ToolInvocation {
  ToolInvocation({required this.callId, required this.name, this.onStatus, this.automaticallyAuthorized = false});
  final String callId;
  final String name;

  /// Set only by the trusted, asynchronous agent execution scope. It cannot
  /// be supplied in model arguments or affect a concurrent parent call.
  final bool automaticallyAuthorized;

  /// Lets a handler surface intermediate states (e.g. awaiting approval).
  final void Function(ToolStatus status)? onStatus;
}

typedef ToolHandler = Future<Map<String, Object?>> Function(Map<String, Object?> args, ToolInvocation call);

/// Per-agent execution context. Nested tools stay in the same worker instead
/// of recursively starting workers; other concurrent callers keep their own
/// normal routing and authorization.
class AutomaticToolScope {
  AutomaticToolScope({required this.cancelled, this.onStarted, this.onFinished});

  static final Object _key = Object();
  static AutomaticToolScope? get current {
    final scope = Zone.current[_key] as AutomaticToolScope?;
    return scope?._active == true ? scope : null;
  }

  bool _active = true;
  bool get active => _active;
  void close() => _active = false;

  static Future<T> outside<T>(Future<T> Function() action) => runZoned(action, zoneValues: {_key: null});
  final bool Function() cancelled;
  final void Function(ToolInvocation call, Map<String, Object?> arguments)? onStarted;
  final void Function(ToolInvocation call, ToolOutcome result)? onFinished;

  Future<T> run<T>(Future<T> Function() action) => runZoned(action, zoneValues: {_key: this});
}

typedef ToolLocalExecutor = Future<ToolOutcome> Function({AutomaticToolScope? scope});

typedef ToolDispatchInterceptor = Future<ToolOutcome> Function(
  ToolDefinition definition,
  Map<String, Object?> arguments,
  ToolInvocation call,
  ToolLocalExecutor executeLocally,
);

class ToolDefinition {
  const ToolDefinition({required this.spec, required this.handler, this.isEnabled});
  final ToolSpec spec;
  final ToolHandler handler;
  final bool Function()? isEnabled;
  bool get enabled => isEnabled?.call() ?? true;
  String get name => spec.name;
}

class ToolOutcome {
  const ToolOutcome(this.status, this.json);
  final ToolStatus status;

  /// Compact JSON sent back to the model.
  final String json;

  bool get ok => status == ToolStatus.success;
}

/// Holds function definitions (JSON schema) and dispatches calls.
/// [dispatch] never throws: every failure becomes a JSON error result.
class ToolRegistry {
  ToolRegistry({this.maxResultChars = 16000, this.timeout = const Duration(minutes: 6), this.interceptor});

  final ToolDispatchInterceptor? interceptor;

  final int maxResultChars;
  final Duration timeout;
  final Map<String, ToolDefinition> _tools = {};

  void register(ToolDefinition def) {
    if (_tools.containsKey(def.name)) {
      throw ArgumentError('Tool ${def.name} already registered');
    }
    _tools[def.name] = def;
  }

  void registerAll(Iterable<ToolDefinition> defs) => defs.forEach(register);

  bool has(String name) => _tools[name]?.enabled ?? false;
  Iterable<String> get names => _tools.values.where((t) => t.enabled).map((t) => t.name);
  List<ToolSpec> get specs => [
    for (final t in _tools.values)
      if (t.enabled) t.spec,
  ];

  Future<ToolOutcome> dispatch(
    String name,
    String argsJson, {
    String callId = '',
    void Function(ToolStatus status)? onStatus,
  }) => _dispatch(name, argsJson, callId: callId, onStatus: onStatus);

  /// Only a worker holding this explicit capability can run its nested
  /// tools locally. An inherited asynchronous Zone is never enough to skip
  /// automatic routing for an ordinary parent dispatch.
  Future<ToolOutcome> dispatchFromAgent(
    String name,
    String argsJson, {
    required AutomaticToolScope scope,
    String callId = '',
    void Function(ToolStatus status)? onStatus,
  }) => _dispatch(name, argsJson, callId: callId, onStatus: onStatus, agentScope: scope);

  Future<ToolOutcome> _dispatch(
    String name,
    String argsJson, {
    String callId = '',
    void Function(ToolStatus status)? onStatus,
    AutomaticToolScope? agentScope,
  }) async {
    final def = _tools[name];
    if (def == null || !def.enabled) {
      return _err(ToolStatus.error, 'unknown tool "$name"');
    }
    Map<String, Object?> args;
    try {
      final decoded = argsJson.trim().isEmpty ? <String, Object?>{} : jsonDecode(argsJson);
      if (decoded is! Map) return _err(ToolStatus.error, 'arguments must be a JSON object');
      args = decoded.cast<String, Object?>();
    } on FormatException catch (e) {
      return _err(ToolStatus.error, 'invalid JSON arguments: ${e.message}');
    }
    final problem = validateArgs(def.spec.parameters, args);
    if (problem != null) return _err(ToolStatus.error, problem);
    final call = ToolInvocation(callId: callId, name: name, onStatus: onStatus);
    try {
      if (agentScope != null) {
        if (!agentScope.active || agentScope.cancelled()) {
          return _err(ToolStatus.error, 'Agent execution capability expired; no additional action was run.');
        }
        return await _execute(def, args, call, scope: agentScope);
      }
      final route = interceptor;
      if (route != null) {
        return await route(def, args, call, ({AutomaticToolScope? scope}) => _execute(def, args, call, scope: scope));
      }
      return await _execute(def, args, call);
    } catch (error) {
      return _err(ToolStatus.error, error.toString());
    }
  }

  Future<ToolOutcome> _execute(
    ToolDefinition def,
    Map<String, Object?> args,
    ToolInvocation original, {
    AutomaticToolScope? scope,
  }) async {
    if (scope != null && (!scope.active || scope.cancelled())) {
      return _err(ToolStatus.error, 'Agent cancelled; no additional tool was started.');
    }
    final call = ToolInvocation(
      callId: original.callId,
      name: original.name,
      onStatus: original.onStatus,
      automaticallyAuthorized: scope != null,
    );
    ToolOutcome outcome;
    scope?.onStarted?.call(call, args);
    try {
      call.onStatus?.call(ToolStatus.running);
      Future<Map<String, Object?>> invoke() => def.handler(args, call);
      final operation = scope == null ? AutomaticToolScope.outside(invoke) : scope.run(invoke);
      final result = await operation.timeout(timeout);
      // Child tool receipts already carry each tool's existing output bounds.
      // Keep their aggregate intact so the parent receives structured results.
      final encoded = def.name == 'delegate_task' && result['tool_results'] is List
          ? jsonEncode(result)
          : _encode(result);
      outcome = ToolOutcome(result['ok'] == false ? ToolStatus.error : ToolStatus.success, encoded);
    } on ToolDenied catch (error) {
      outcome = ToolOutcome(ToolStatus.denied, _encode({'ok': false, 'denied': true, 'reason': error.reason}));
    } on ToolFailure catch (error) {
      outcome = _err(ToolStatus.error, error.message);
    } on TimeoutException {
      outcome = _err(ToolStatus.error, 'Tool timed out. An already-started action may still finish; do not repeat it.');
    } catch (error) {
      outcome = _err(ToolStatus.error, error.toString());
    }
    scope?.onFinished?.call(call, outcome);
    return outcome;
  }

  ToolOutcome _err(ToolStatus s, String msg) => ToolOutcome(s, _encode({'ok': false, 'error': msg}));

  String _encode(Map<String, Object?> m) {
    final s = jsonEncode(m);
    if (s.length <= maxResultChars) return s;
    return jsonEncode({'ok': m['ok'] ?? true, 'truncated': true, 'partial': s.substring(0, maxResultChars - 200)});
  }

  /// Minimal JSON-schema check: required keys, primitive types, enums.
  static String? validateArgs(Map<String, Object?> schema, Map<String, Object?> args) {
    final props = (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    final required = (schema['required'] as List?)?.cast<String>() ?? const [];
    for (final r in required) {
      if (!args.containsKey(r) || args[r] == null) return 'missing required argument "$r"';
    }
    for (final e in args.entries) {
      final p = (props[e.key] as Map?)?.cast<String, Object?>();
      if (p == null || e.value == null) continue;
      final type = p['type'];
      final v = e.value;
      final ok = switch (type) {
        'string' => v is String,
        'integer' => v is int || (v is double && v == v.roundToDouble()),
        'number' => v is num,
        'boolean' => v is bool,
        'array' => v is List,
        'object' => v is Map,
        _ => true,
      };
      if (!ok) return 'argument "${e.key}" must be of type $type';
      final en = p['enum'];
      if (en is List && !en.contains(v)) {
        return 'argument "${e.key}" must be one of ${en.join(', ')}';
      }
    }
    return null;
  }
}

extension ArgReaders on Map<String, Object?> {
  String str(String k, [String def = '']) => (this[k] as String?) ?? def;
  String? strOrNull(String k) {
    final v = this[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  int integer(String k, int def) => (this[k] as num?)?.round() ?? def;
  int? intOrNull(String k) => (this[k] as num?)?.round();
  bool boolean(String k, [bool def = false]) => (this[k] as bool?) ?? def;
}
