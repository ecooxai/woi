import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../audio/wav.dart';
import '../pipeline/vad.dart';
import 'voice_backend.dart';

/// Offline stand-in for the realtime API.
///
/// * Runs an energy VAD over [sendAudio] and emits speech events
///   (like server-side turn detection), then replies.
/// * Replies stream as transcript deltas plus synthesized "speech" audio.
/// * Simple commands trigger tool calls so the full loop can be exercised:
///   `take a screenshot`, `run CMD`, `list DIR`, `read FILE`, `show FILE`,
///   `type TEXT`, `press KEYS`, `click X Y`, `write PATH: CONTENT`,
///   `delegate TASK`.
class MockVoiceBackend implements VoiceBackend {
  MockVoiceBackend({
    this.serverVad = true,
    this.wordDelay = const Duration(milliseconds: 90),
    this.synthesizeAudio = true,
    this.vadThreshold = 0.025,
    this.minSpeechMs = 160,
    this.silenceToStopMs = 700,
  });

  final bool serverVad;
  final Duration wordDelay;
  final bool synthesizeAudio;
  final double vadThreshold;
  final int minSpeechMs;
  final int silenceToStopMs;

  final _events = StreamController<BackendEvent>.broadcast();
  SessionConfig? _config;
  bool _connected = false;

  // VAD state (adaptive noise floor, like a server-side detector)
  late final EnergyVad _vad = EnergyVad(minThreshold: vadThreshold, startMs: minSpeechMs, stopMs: silenceToStopMs);
  int _utteranceMs = 0;

  // Conversation state
  int _contextTokens = 0;
  int _responseToken = 0;
  bool _responding = false;
  (int, int)? _pendingImage;
  final Map<String, String> _pendingTools = {};
  final List<String> received = [];

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  bool get hasServerVad => serverVad;

  bool get isConnected => _connected;
  SessionConfig? get config => _config;
  int imagesReceived = 0;
  int cancelCount = 0;

  void _emit(BackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Future<void> connect(SessionConfig config) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _config = config;
    _connected = true;
    _contextTokens =
        (config.instructions.length / 4).ceil() +
        config.tools.fold<int>(0, (a, t) => a + (jsonEncode(t.toJson()).length / 4).ceil()) +
        ((config.priorContext?.length ?? 0) / 4).ceil();
  }

  @override
  void sendAudio(Uint8List pcm16) {
    if (!_connected || !serverVad) return;
    final ms = pcmDurationMs(pcm16.length);
    // Crude echo guard: our own synthesized reply comes back through the mic.
    _vad.sensitivityScale = _responding ? 2.5 : 1.0;
    final ev = _vad.process(pcm16);
    if (_vad.speaking || ev == VadEvent.speechStopped) _utteranceMs += ms;
    switch (ev) {
      case VadEvent.speechStarted:
        _utteranceMs = minSpeechMs;
        _emit(const SpeechStarted());
      case VadEvent.speechStopped:
        final spoken = max(0, _utteranceMs - silenceToStopMs) / 1000;
        _emit(const SpeechStopped());
        _contextTokens += (spoken * 10).round();
        final t = '[${spoken.toStringAsFixed(1)} s of speech]';
        _emit(UserTranscriptDelta(t));
        _emit(UserTranscriptDone(t));
        unawaited(_respond(null, spokenSeconds: spoken));
      case null:
    }
  }

  @override
  void sendText(String text) {
    if (!_connected) return;
    received.add(text);
    _contextTokens += (text.length / 4).ceil() + 4;
    unawaited(_respond(text));
  }

  @override
  void sendImage(Uint8List png, {String? note}) {
    if (!_connected) return;
    imagesReceived++;
    _contextTokens += 765;
    final bd = ByteData.sublistView(png);
    _pendingImage = png.length >= 24 ? (bd.getUint32(16), bd.getUint32(20)) : (0, 0);
  }

  @override
  void sendToolResult(String callId, String jsonOutput) {
    final name = _pendingTools.remove(callId);
    if (name == null) return;
    _contextTokens += (jsonOutput.length / 4).ceil();
    unawaited(_speak(_describeToolResult(name, jsonOutput)));
  }

  @override
  void cancelResponse() {
    if (_responding) {
      cancelCount++;
      _responseToken++;
    }
  }

  @override
  Future<void> close() async {
    _connected = false;
    _responseToken++;
    await _events.close();
  }

  bool _has(String tool) => _config?.tools.any((t) => t.name == tool) ?? false;

  (String, Map<String, Object?>)? _plan(String text) {
    final t = text.trim();
    final l = t.toLowerCase();
    RegExpMatch? m;
    if (RegExp(r'screenshot|on (my|the) screen|look at (my|the) screen').hasMatch(l)) {
      return ('take_screenshot', {});
    }
    if ((m = RegExp(r'^(?:run|execute|bash)\s+(.+)$', dotAll: true).firstMatch(t)) != null) {
      return ('run_bash', {'command': m![1]!.trim()});
    }
    if ((m = RegExp(r'^(?:list|ls)\s+(.+)$', caseSensitive: false).firstMatch(t)) != null) {
      return ('list_dir', {'path': m![1]!.trim()});
    }
    if ((m = RegExp(r'^read\s+(.+)$', caseSensitive: false).firstMatch(t)) != null) {
      return ('read_file', {'path': m![1]!.trim()});
    }
    if ((m = RegExp(r'^(?:show|open)\s+(.+)$', caseSensitive: false).firstMatch(t)) != null) {
      return ('show_file', {'path': m![1]!.trim()});
    }
    if ((m = RegExp(r'^type\s+(.+)$', caseSensitive: false, dotAll: true).firstMatch(t)) != null) {
      return ('type_text', {'text': m![1]!});
    }
    if ((m = RegExp(r'^press\s+(.+)$', caseSensitive: false).firstMatch(t)) != null) {
      return ('key_combo', {'keys': m![1]!.trim()});
    }
    if ((m = RegExp(r'^click\s+(\d+)[\s,]+(\d+)', caseSensitive: false).firstMatch(t)) != null) {
      return ('click_screen', {'x': int.parse(m![1]!), 'y': int.parse(m[2]!)});
    }
    if ((m = RegExp(r'^write\s+(\S+)\s*:\s?(.*)$', caseSensitive: false, dotAll: true).firstMatch(t)) != null) {
      return ('write_file', {'path': m![1]!, 'content': m[2]!});
    }
    if ((m = RegExp(r'^delegate\s+(.+)$', caseSensitive: false, dotAll: true).firstMatch(t)) != null) {
      return ('delegate_task', {'task': m![1]!.trim()});
    }
    return null;
  }

  Future<void> _respond(String? text, {double spokenSeconds = 0}) async {
    final img = _pendingImage;
    _pendingImage = null;
    if (text != null) {
      final plan = _plan(text);
      if (plan != null && _has(plan.$1)) {
        final callId = 'call_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
        final ok = await _speak(_preamble(plan.$1), done: false);
        if (!ok) return;
        _pendingTools[callId] = plan.$1;
        _emit(ToolCall(callId, plan.$1, jsonEncode(plan.$2)));
        _emit(const ResponseDone());
        _responding = false;
        return;
      }
    }
    final String reply;
    if (text == null) {
      reply =
          'I heard about ${spokenSeconds.toStringAsFixed(1)} seconds of speech'
          '${img != null ? ' and got a ${img.$1} by ${img.$2} screenshot of your screen' : ''}. '
          'This is the offline mock backend, so I cannot transcribe yet, '
          'but the voice loop is working end to end.';
    } else if (RegExp(r'^(hi|hello|hey)\b', caseSensitive: false).hasMatch(text.trim())) {
      reply =
          'Hey! I am Woi, running on the mock backend. Try "take a screenshot", '
          '"run uname -a" or "list ~".';
    } else {
      final echo = text.length > 120 ? '${text.substring(0, 117)}…' : text;
      reply =
          'You said: "$echo". I am the mock backend, so I can only echo, '
          'but commands like "run uptime", "read ~/.bashrc" or "show <file>" '
          'trigger real tools.';
    }
    await _speak(reply);
  }

  String _preamble(String tool) => switch (tool) {
    'take_screenshot' => 'Taking a look at your screen.',
    'run_bash' => 'Running that command.',
    'list_dir' => 'Listing that folder.',
    'read_file' => 'Reading the file.',
    'show_file' => 'Opening it for you.',
    'write_file' => 'I will write that file once you approve.',
    'delegate_task' => 'Handing that to the bigger model.',
    _ => 'On it.',
  };

  String _describeToolResult(String name, String json) {
    Map<String, Object?> r;
    try {
      r = (jsonDecode(json) as Map).cast<String, Object?>();
    } catch (_) {
      return 'The tool returned something I could not read.';
    }
    if (r['denied'] == true) return 'Okay, I will not do that.';
    if (r['ok'] == false && r['error'] != null) return 'That did not work: ${r['error']}.';
    String clip(Object? s, [int n = 160]) {
      final t = '${s ?? ''}'.trim();
      return t.length > n ? '${t.substring(0, n)}…' : t;
    }

    return switch (name) {
      'run_bash' =>
        'Exit code ${r['exit_code']}. '
            '${clip(r['stdout']).isEmpty ? 'No output.' : 'Output: ${clip(r['stdout'])}'}',
      'take_screenshot' => 'Got a ${r['image']} screenshot of your ${r['screen']} screen.',
      'list_dir' => 'That folder has ${(r['entries'] as List?)?.length ?? 0} entries.',
      'read_file' => 'The file starts with: ${clip(r['content'], 120)}',
      'show_file' => 'It is open in the ${r['shown_in']} viewer.',
      'write_file' || 'edit_file' => 'Saved ${r['path']}.',
      'delegate_task' => clip(r['output'], 240),
      _ => 'Done.',
    };
  }

  /// Streams [text] as transcript + audio. Returns false when cancelled.
  Future<bool> _speak(String text, {bool done = true}) async {
    final token = ++_responseToken;
    _responding = true;
    final words = text.split(' ');
    final sb = StringBuffer();
    var cancelled = false;
    for (var i = 0; i < words.length; i++) {
      if (token != _responseToken || !_connected) {
        cancelled = true;
        break;
      }
      final w = i == 0 ? words[i] : ' ${words[i]}';
      sb.write(w);
      _emit(AssistantTranscriptDelta(w));
      if (synthesizeAudio) _emit(AssistantAudioDelta(_synth(words[i], i)));
      if (wordDelay > Duration.zero) await Future<void>.delayed(wordDelay);
    }
    final out = sb.toString();
    _contextTokens += (out.length / 4).ceil();
    if (cancelled) {
      if (_connected) _emit(ResponseDone(cancelled: true));
      _responding = false;
      return false;
    }
    _emit(AssistantTranscriptDone(out));
    _emit(Usage(_contextTokens - (out.length / 4).ceil(), (out.length / 4).ceil(), _contextTokens));
    if (done) {
      _emit(const ResponseDone());
      _responding = false;
    }
    return true;
  }

  /// A soft vowel-like tone per word, so playback and level meters have
  /// something realistic to work with.
  Uint8List _synth(String word, int index) {
    const rate = kVoiceSampleRate;
    final durMs = (word.length * 55).clamp(120, 420) + 50;
    final n = rate * durMs ~/ 1000;
    final voiced = rate * (durMs - 50) ~/ 1000;
    final out = ByteData(n * 2);
    final f0 = 150.0 + 25 * sin(index * 0.9) + (word.hashCode % 20);
    for (var i = 0; i < voiced; i++) {
      final t = i / rate;
      final env = sin(pi * i / voiced);
      final vib = 1 + 0.01 * sin(2 * pi * 5 * t);
      final s =
          0.55 * sin(2 * pi * f0 * vib * t) + 0.25 * sin(2 * pi * 2 * f0 * vib * t) + 0.12 * sin(2 * pi * 3.1 * f0 * t);
      out.setInt16(i * 2, (s * env * 0.16 * 32767).round(), Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
