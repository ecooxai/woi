import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/audio/playback_clock.dart';
import '../../core/audio/wav.dart';
import '../../core/voice/voice_backend.dart';
import '../audio_io.dart';
import 'exec_util.dart';

/// PipeWire (pw-record / pw-play) with PulseAudio (parecord / pacat)
/// fallback. Raw PCM is piped through child processes.
class LinuxAudioIO implements AudioIO {
  LinuxAudioIO({this.captureLatencyMs = 20, this.playbackLatencyMs = 40});

  final int captureLatencyMs;
  final int playbackLatencyMs;

  static const _rate = '$kVoiceSampleRate';

  (String, List<String>) _captureCommand() {
    final pw = which('pw-record');
    if (pw != null) {
      return (
        pw,
        ['--raw', '--rate', _rate, '--channels', '1', '--format', 's16', '--latency', '${captureLatencyMs}ms', '-'],
      );
    }
    final pa = which('parecord');
    if (pa != null) {
      return (pa, ['--raw', '--rate=$_rate', '--channels=1', '--format=s16le', '--latency-msec=$captureLatencyMs']);
    }
    throw MissingTool(['pw-record', 'parecord']);
  }

  (String, List<String>) _playbackCommand() {
    final pw = which('pw-play');
    if (pw != null) {
      return (
        pw,
        ['--raw', '--rate', _rate, '--channels', '1', '--format', 's16', '--latency', '${playbackLatencyMs}ms', '-'],
      );
    }
    final pa = which('pacat');
    if (pa != null) {
      return (
        pa,
        ['--playback', '--raw', '--rate=$_rate', '--channels=1', '--format=s16le', '--latency-msec=$playbackLatencyMs'],
      );
    }
    throw MissingTool(['pw-play', 'pacat']);
  }

  @override
  String get description {
    final cap = which('pw-record') != null ? 'pw-record' : 'parecord';
    final play = which('pw-play') != null ? 'pw-play' : 'pacat';
    return '$cap / $play';
  }

  @override
  Future<MicStream> openMic() async {
    final (exe, args) = _captureCommand();
    final proc = await Process.start(exe, args);
    return _LinuxMic(proc);
  }

  @override
  Future<PcmPlayer> openPlayer() async {
    final player = _LinuxPcmPlayer(_playbackCommand, playbackLatencyMs);
    await player.warmUp();
    return player;
  }

  @override
  Future<ClipPlayback> playFile(String path) async {
    final pw = which('pw-play');
    final exe = pw ?? which('paplay') ?? (throw MissingTool(['pw-play', 'paplay']));
    final proc = await Process.start(exe, [path]);
    return _ProcessClip(proc);
  }
}

class _LinuxMic implements MicStream {
  _LinuxMic(this._proc) {
    _sub = _proc.stdout.listen(_onData, onDone: _controller.close);
    _proc.stderr.drain<void>();
  }

  final Process _proc;
  final _controller = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  late final StreamSubscription<List<int>> _sub;
  int? _carry;

  void _onData(List<int> data) {
    var bytes = data is Uint8List ? data : Uint8List.fromList(data);
    if (_carry != null) {
      bytes = Uint8List.fromList([_carry!, ...bytes]);
      _carry = null;
    }
    if (bytes.length.isOdd) {
      _carry = bytes.last;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return;
    final m = rmsToMeter(pcm16Rms(bytes));
    final cur = _level.value;
    _level.value = m > cur ? m : cur * 0.7 + m * 0.3;
    _controller.add(bytes);
  }

  @override
  Stream<Uint8List> get chunks => _controller.stream;

  @override
  ValueListenable<double> get level => _level;

  @override
  Future<void> close() async {
    _proc.kill(ProcessSignal.sigterm);
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
    _level.value = 0;
  }
}

class _LinuxPcmPlayer implements PcmPlayer {
  _LinuxPcmPlayer(this._command, int latencyMs)
    : _clock = PlaybackClock(outputLatency: Duration(milliseconds: latencyMs + 20));

  final (String, List<String>) Function() _command;
  final PlaybackClock _clock;
  Process? _proc;
  Future<Process>? _spawning;
  final List<Uint8List> _pending = [];
  int _generation = 0;
  bool _closed = false;

  Future<void> warmUp() async {
    await _ensureProcess();
  }

  Future<Process> _ensureProcess() {
    final existing = _proc;
    if (existing != null) return Future.value(existing);
    return _spawning ??= () async {
      final gen = _generation;
      final (exe, args) = _command();
      final p = await Process.start(exe, args);
      p.stdout.drain<void>();
      p.stderr.drain<void>();
      p.stdin.done.catchError((_) {});
      unawaited(
        p.exitCode.then((_) {
          if (identical(_proc, p)) _proc = null;
        }),
      );
      _spawning = null;
      if (gen != _generation || _closed) {
        p.kill(ProcessSignal.sigkill);
        return _ensureProcess();
      }
      _proc = p;
      for (final c in _pending) {
        _safeAdd(p, c);
      }
      _pending.clear();
      return p;
    }();
  }

  void _safeAdd(Process p, Uint8List data) {
    try {
      p.stdin.add(data);
    } catch (_) {
      // Process died (e.g. killed by stop); data is intentionally dropped.
    }
  }

  @override
  void write(Uint8List pcm16) {
    if (_closed || pcm16.isEmpty) return;
    _clock.onWrite(pcm16);
    final p = _proc;
    if (p != null) {
      _safeAdd(p, pcm16);
    } else {
      _pending.add(pcm16);
      _ensureProcess();
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pending.clear();
    _clock.reset();
    final p = _proc;
    _proc = null;
    _spawning = null;
    p?.kill(ProcessSignal.sigkill);
    if (!_closed) unawaited(_ensureProcess()); // keep a warm player ready
  }

  @override
  bool get isPlaying => _clock.isPlaying;

  @override
  ValueListenable<double> get level => _clock.level;

  @override
  Future<void> close() async {
    _closed = true;
    _generation++;
    _proc?.kill(ProcessSignal.sigkill);
    _proc = null;
    _clock.dispose();
  }
}

class _ProcessClip implements ClipPlayback {
  _ProcessClip(this._proc) {
    _proc.stdout.drain<void>();
    _proc.stderr.drain<void>();
  }
  final Process _proc;

  @override
  Future<void> get done => _proc.exitCode;

  @override
  Future<void> stop() async {
    _proc.kill(ProcessSignal.sigkill);
  }
}
