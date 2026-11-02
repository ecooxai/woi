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
  ToolInvocation({required this.callId, required this.name, this.onStatus});
  final String callId;
  final String name;

  /// Lets a handler surface intermediate states (e.g. awaiting approval).
  final void Function(ToolStatus status)? onStatus;
}

typedef ToolHandler = Future<Map<String, Object?>> Function(Map<String, Object?> args, ToolInvocation call);

class ToolDefinition {
  const ToolDefinition({required this.spec, required this.handler});
  final ToolSpec spec;
  final ToolHandler handler;
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
  ToolRegistry({this.maxResultChars = 16000, this.timeout = const Duration(minutes: 6)});

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

  bool has(String name) => _tools.containsKey(name);
  Iterable<String> get names => _tools.keys;
  List<ToolSpec> get specs => [for (final t in _tools.values) t.spec];

  Future<ToolOutcome> dispatch(
    String name,
    String argsJson, {
    String callId = '',
    void Function(ToolStatus status)? onStatus,
  }) async {
    final def = _tools[name];
    if (def == null) {
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
    try {
      onStatus?.call(ToolStatus.running);
      final result = await def
          .handler(args, ToolInvocation(callId: callId, name: name, onStatus: onStatus))
          .timeout(timeout);
      return ToolOutcome(ToolStatus.success, _encode(result));
    } on ToolDenied catch (e) {
      return ToolOutcome(ToolStatus.denied, _encode({'ok': false, 'denied': true, 'reason': e.reason}));
    } on ToolFailure catch (e) {
      return _err(ToolStatus.error, e.message);
    } on TimeoutException {
      return _err(ToolStatus.error, 'tool timed out');
    } catch (e) {
      return _err(ToolStatus.error, e.toString());
    }
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
