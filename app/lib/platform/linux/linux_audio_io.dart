import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/audio/playback_clock.dart';
import '../../core/audio/mic_system_mix.dart';
import '../../core/audio/wav.dart';
import '../../core/voice/voice_backend.dart';
import '../audio_io.dart';
import 'exec_util.dart';
import 'pipewire_aec.dart';

/// PipeWire (pw-record / pw-play) with PulseAudio (parecord / pacat)
/// fallback. Raw PCM is piped through child processes.
///
/// With [echoCancellation] on (default) the mic is recorded from the
/// app-owned PipeWire WebRTC echo canceller ([PipewireEchoCancel]), whose
/// reference is the default sink's monitor: everything the speakers play is
/// removed. An unavailable canceller is reported to the caller instead of
/// silently exposing uncancelled speaker audio to voice activity detection.
class LinuxAudioIO implements AudioIO, EchoCancellable, RawMicCapable, ExternalEchoCapture, HeldAudioCapture {
  LinuxAudioIO({this.captureLatencyMs = 20, this.playbackLatencyMs = 40, PipewireEchoCancel? echoCanceller})
    : _aec = echoCanceller ?? PipewireEchoCancel(log: (m) => debugPrint('woi aec: $m'));

  final int captureLatencyMs;
  final int playbackLatencyMs;
  final PipewireEchoCancel _aec;
  bool _echoCancellation = true;

  static const _rate = '$kVoiceSampleRate';

  @override
  bool get echoCancellation => _echoCancellation;

  @override
  set echoCancellation(bool on) {
    if (on == _echoCancellation) return;
    _echoCancellation = on;
    // Open mics keep their source until reopened; the host stops once the
    // last of them is released.
  }

  @override
  String get echoCancellationStatus => _echoCancellation ? _aec.status : 'off (setting)';

  @override
  Future<void> disposeEchoCancellation() => _aec.dispose();

  @override
  Future<EchoCaptureLease?> acquireEchoCapture() async {
    if (!_echoCancellation) return null;
    final name = await _aec.acquire();
    if (name == null) {
      throw StateError('System echo cancellation unavailable: ${_aec.status}');
    }
    return EchoCaptureLease(deviceName: name, deviceLabel: _aec.sourceDescription, release: () async => _aec.release());
  }

  (String, List<String>) _captureCommand({String? target}) {
    final pw = which('pw-record');
    if (pw != null) {
      return (
        pw,
        [
          '--raw',
          if (target != null) ...['--target', target],
          '--rate',
          _rate,
          '--channels',
          '1',
          '--format',
          's16',
          '--latency',
          '${captureLatencyMs}ms',
          '-',
        ],
      );
    }
    final pa = which('parecord');
    if (pa != null) {
      return (
        pa,
        [
          '--raw',
          if (target != null) '--device=$target',
          '--rate=$_rate',
          '--channels=1',
          '--format=s16le',
          '--latency-msec=$captureLatencyMs',
        ],
      );
    }
    throw MissingTool(['pw-record', 'parecord']);
  }

  // WOI_AUDIO_SINK / WOI_AUDIO_SOURCE: play to / record from given nodes
  // instead of the defaults (QA on virtual devices).
  static final _sink = PipewireEchoCancel.audioTarget('WOI_AUDIO_SINK');
  static final _source = PipewireEchoCancel.audioTarget('WOI_AUDIO_SOURCE');

  (String, List<String>) _playbackCommand() {
    final pw = which('pw-play');
    if (pw != null) {
      return (
        pw,
        [
          '--raw',
          if (_sink case final s?) ...['--target', s],
          '--rate',
          _rate,
          '--channels',
          '1',
          '--format',
          's16',
          '--latency',
          '${playbackLatencyMs}ms',
          '-',
        ],
      );
    }
    final pa = which('pacat');
    if (pa != null) {
      return (
        pa,
        [
          '--playback',
          '--raw',
          if (_sink != null) '--device=$_sink',
          '--rate=$_rate',
          '--channels=1',
          '--format=s16le',
          '--latency-msec=$playbackLatencyMs',
        ],
      );
    }
    throw MissingTool(['pw-play', 'pacat']);
  }

  @override
  String get description {
    final cap = which('pw-record') != null ? 'pw-record' : 'parecord';
    final play = which('pw-play') != null ? 'pw-play' : 'pacat';
    return '$cap / $play; echo cancellation: $echoCancellationStatus';
  }

  @override
  Future<MicStream> openMic() async {
    final lease = await acquireEchoCapture();
    try {
      final (exe, args) = _captureCommand(target: lease?.deviceName ?? _source);
      final (e, a) = withDefaultSigpipe(exe, args);
      final proc = await Process.start(e, a);
      return _LinuxMic(proc, lease == null ? null : () => unawaited(lease.release()));
    } catch (_) {
      await lease?.release();
      rethrow;
    }
  }

  @override
  bool get includesSystemAudio => true;

  @override
  Future<MicStream> openHeldAudio() async {
    final mic = await openMic();
    try {
      final pw = which('pw-record');
      final String exe;
      final List<String> args;
      if (pw != null) {
        exe = pw;
        args = [
          '--raw',
          '--rate',
          _rate,
          '--channels',
          '1',
          '--format',
          's16',
          '--latency',
          '${captureLatencyMs}ms',
          '--properties',
          '{ stream.capture.sink = true node.passive = true }',
          if (_sink != null) ...['--target', _sink!],
          '-',
        ];
      } else {
        exe = which('parecord') ?? (throw MissingTool(['pw-record', 'parecord']));
        final pactl = which('pactl') ?? (throw MissingTool(['pactl']));
        final result = await Process.run(pactl, ['get-default-sink']).timeout(const Duration(seconds: 2));
        final sink = _sink ?? '${result.stdout}'.trim();
        if (sink.isEmpty || result.exitCode != 0) {
          throw StateError('System audio output is unavailable');
        }
        args = ['--raw', '--device=$sink.monitor', '--rate=$_rate', '--channels=1', '--format=s16le'];
      }
      final (e, a) = withDefaultSigpipe(exe, args);
      final system = _LinuxMic(await Process.start(e, a));
      return MicSystemMixStream(mic, system);
    } catch (_) {
      await mic.close();
      rethrow;
    }
  }

  @override
  Future<MicStream?> openRawMic() async {
    if (!_echoCancellation) return null;
    final (exe, args) = _captureCommand(target: _source);
    final (e, a) = withDefaultSigpipe(exe, args);
    return _LinuxMic(await Process.start(e, a));
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
  _LinuxMic(this._proc, [this._onClose]) {
    _sub = _proc.stdout.listen(_onData, onDone: _onDone);
    _proc.stderr.drain<void>();
  }

  final Process _proc;
  void Function()? _onClose;
  final _controller = StreamController<Uint8List>.broadcast();
  final _level = ValueNotifier<double>(0);
  late final StreamSubscription<List<int>> _sub;
  int? _carry;
  bool _closed = false;

  void _onDone() {
    _onClose?.call();
    _onClose = null;
    _level.value = 0;
    if (!_controller.isClosed) unawaited(_controller.close());
  }

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
    if (_closed) return;
    _closed = true;
    _proc.kill(ProcessSignal.sigterm);
    _onClose?.call();
    _onClose = null;
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
