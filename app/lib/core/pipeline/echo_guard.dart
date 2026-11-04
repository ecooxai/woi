import 'dart:math';
import 'dart:typed_data';

/// Local double-talk detector and mic gate against Woi hearing itself.
///
/// On real speakers the platform echo canceller leaves residual echo (15-30
/// dB below Woi's playback; worse at the start of a reply, after a buffer
/// resize, with a loud or distorting speaker). Server VAD hears that residual
/// as the user, interrupts Woi and answers its own words. This guard knows
/// Woi's playback sample-exactly (every PCM chunk handed to the player, put
/// on the timeline where it becomes audible) and compares each 10 ms mic
/// frame, band by band, with the echo that playback can produce:
///
/// * the reference is the per-band energy of what was audible within the
///   echo delay window (output latency, room, canceller and capture latency:
///   [minDelayMs]..[maxDelayMs]); when the residual's envelope correlates with
///   the reference at one lag, the window narrows to that lag ±[lagSlackMs];
/// * per band it learns the coupling (residual ÷ reference), following peaks
///   quickly and decaying slowly, only on frames that do not look like the
///   user;
/// * a frame is near-end speech when at least [minBands] bands are
///   [marginDb] above the predicted echo and the noise floor and the excess
///   energy is above [minRms]; [onsetMs] of such frames (gaps up to
///   [maxGapMs] bridged) is an onset ([process] returns true once).
///
/// Laptop speakers reproduce almost nothing below ~300 Hz, so the user's
/// voice stands out in the low bands even when the residual is loud; the
/// band split is what makes this work where a broadband level ratio (the
/// older [BargeInDetector]) fired on residual bursts.
///
/// [echoExpected] says whether the mic may contain echo now (playback within
/// the delay window). The pipeline sends silence instead of the mic to the
/// server then, unless an onset opened the gate ([gateOpen]).
class EchoGuard {
  EchoGuard({
    int Function()? nowUs,
    this.outputLatencyMs = 60,
    this.minDelayMs = -40,
    this.maxDelayMs = 600,
    this.lagSlackMs = 60,
    this.onsetMs = 100,
    this.maxGapMs = 60,
    this.marginDb = 8,
    this.minBands = 2,
    this.minRms = 0.006,
    this.priorCouplingDb = -8,
    this.couplingAttack = 0.4,
    this.couplingDecay = 0.95,
  }) : _nowUs = nowUs ?? _stopwatchUs;

  static final _sw = Stopwatch()..start();
  static int _stopwatchUs() => _sw.elapsedMicroseconds;

  final int Function() _nowUs;

  /// Delay the player adds before written audio is heard (the pipeline's
  /// player clock uses the same figure).
  final int outputLatencyMs;

  /// Echo delay window relative to the scheduled audible time.
  final int minDelayMs;
  final int maxDelayMs;

  /// Half width of the window around an estimated echo lag.
  final int lagSlackMs;

  final int onsetMs;
  final int maxGapMs;

  /// How far above the predicted echo a band must be (energy, dB).
  final double marginDb;
  final int minBands;

  /// Lowest RMS of the near-end excess that counts as the user (settable:
  /// phones' platform AEC leaves short bursts and use a higher floor).
  double minRms;

  /// Coupling assumed before any echo was observed (residual ÷ playback).
  final double priorCouplingDb;

  /// How fast the coupling follows a louder echo (0..1 per 10 ms frame).
  /// High for a canceller's output (bursty residual), low for a raw mic (a
  /// stable acoustic path, where following peaks would mask the user).
  final double couplingAttack;

  /// How fast it relaxes towards a quieter echo (per 10 ms frame).
  final double couplingDecay;

  static const _rate = 24000; // kVoiceSampleRate (kept import-free for tool/)
  static const _hop = _rate ~/ 100; // 10 ms
  static const _win = 2 * _hop; // 20 ms analysis window
  static const _fft = 512;
  static const _ring = 8192; // 82 s of reference frames
  static const _hist = 512; // 5 s of envelope history for the lag search

  /// Band edges in Hz (8 bands, 100 Hz - Nyquist).
  static const bandEdges = [100, 300, 600, 1000, 1600, 2500, 4000, 6500, 12000];
  static final int nb = bandEdges.length - 1;
  static final List<int> _binLo = [for (var b = 0; b < bandEdges.length - 1; b++) (bandEdges[b] * _fft / _rate).ceil()];
  static final List<int> _binHi = [
    for (var b = 1; b < bandEdges.length; b++) min(_fft ~/ 2 + 1, (bandEdges[b] * _fft / _rate).ceil() + (b == bandEdges.length - 1 ? 1 : 0)),
  ];
  static final Float64List _hann = Float64List.fromList([
    for (var i = 0; i < _win; i++) 0.5 - 0.5 * cos(2 * pi * (i + 0.5) / _win),
  ]);

  // ---- reference timeline (frame index = audible time / 10 ms)
  final Float64List _ref = Float64List(_ring * (bandEdges.length - 1));
  final Int64List _refFrame = Int64List(_ring)..fillRange(0, _ring, -1);
  int _refNext = -1; // next frame index to write (contiguous playback)
  int _refEndFrame = -1; // last frame with playback
  final Float64List _refTail = Float64List(_hop); // previous hop (for the 20 ms window)
  final Float64List _refCarry = Float64List(_hop);
  int _refCarryN = 0;

  // ---- mic
  final Float64List _micPrev = Float64List(_hop);
  final Float64List _micCarry = Float64List(_hop);
  int _micCarryN = 0;
  late final Float64List _coupling = Float64List(nb)..fillRange(0, nb, pow(10, priorCouplingDb / 10).toDouble());
  final Float64List _noise = Float64List(bandEdges.length - 1)..fillRange(0, bandEdges.length - 1, 1e-9);
  // Canceller residual is worst at the start of a reply (and after a delay
  // jump): remember the coupling seen in reply starts and start every reply
  // from it.
  final Float64List _startPeak = Float64List(bandEdges.length - 1);
  int _replyFrames = 1 << 30;
  int _voicedMs = 0;
  int _gapMs = 0;
  bool _fired = false;
  int _userHangFrames = 0;
  bool _gateOpen = false;

  // ---- lag estimate (envelopes at 10 ms, history ring)
  final Float64List _micEnv = Float64List(_hist);
  final Float64List _refEnv = Float64List(_hist * 80); // ref envelope per mic frame, lag 0..79 frames
  int _histN = 0;
  int? _lagFrames;
  double _lagCorr = 0;
  int _sinceLagSearch = 0;

  int get _lagOffset => (minDelayMs ~/ 10).clamp(-10, 0);

  /// Envelope floor: band-sum energy of -60 dBFS (see the RMS formula).
  static const _envFloor = 1e-6 * _fft * _win * 0.375 / 2;

  // ---- scratch
  final Float64List _re = Float64List(_fft);
  final Float64List _im = Float64List(_fft);
  final Float64List _bands = Float64List(bandEdges.length - 1);
  final Float64List _pred = Float64List(bandEdges.length - 1);

  /// Diagnostics.
  void Function(int frame, Float64List mic, Float64List threshold, bool user)? onFrame;
  final Float64List _thr = Float64List(bandEdges.length - 1);
  int onsets = 0;
  int framesGated = 0;
  double lastExcessRms = 0;
  int? get lagMs => _lagFrames == null ? null : _lagFrames! * 10;
  double get lagCorrelation => _lagCorr;
  List<double> get couplingDb => [for (final c in _coupling) 10 * log(max(c, 1e-12)) / ln10];

  /// Whether an onset (the user talking over Woi) opened the mic gate since
  /// the current reply started.
  bool get gateOpen => _gateOpen;

  int get _nowFrame => _nowUs() ~/ 10000;

  // ------------------------------------------------------------ playback

  /// Woi audio handed to the player now; heard from max(now + output
  /// latency, end of what is queued).
  void onPlayback(Uint8List pcm16) {
    final n = pcm16.length ~/ 2;
    if (n == 0) return;
    final now = _nowFrame;
    final startEarliest = now + (outputLatencyMs + 5) ~/ 10;
    if (_refNext < startEarliest) {
      // A new stretch of playback (nothing queued): a new reply.
      if (_refNext < now) rearm();
      _refNext = startEarliest;
      _refCarryN = 0;
      _refTail.fillRange(0, _hop, 0);
    }
    final bd = ByteData.sublistView(pcm16);
    for (var i = 0; i < n; i++) {
      _refCarry[_refCarryN++] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      if (_refCarryN == _hop) {
        _analyze(_refTail, _refCarry, _bands);
        final slot = _refNext % _ring;
        _refFrame[slot] = _refNext;
        for (var b = 0; b < nb; b++) {
          _ref[slot * nb + b] = _bands[b];
        }
        _refEndFrame = _refNext;
        _refNext++;
        _refTail.setAll(0, _refCarry);
        _refCarryN = 0;
      }
    }
  }

  /// Playback was cut (barge-in): nothing after now will be heard.
  void stopPlayback() {
    final now = _nowFrame + (outputLatencyMs ~/ 10);
    for (var f = now + 1; f < _refNext; f++) {
      final slot = f % _ring;
      if (_refFrame[slot] == f) _refFrame[slot] = -1;
    }
    if (_refNext > now + 1) _refNext = now + 1;
    if (_refEndFrame > now) _refEndFrame = now;
    _refCarryN = 0;
  }

  /// A new reply: allow one more onset and close the gate.
  void rearm() {
    for (var b = 0; b < nb; b++) {
      if (_startPeak[b] > _coupling[b]) _coupling[b] = _startPeak[b];
      _startPeak[b] *= 0.5;
    }
    _replyFrames = 0;
    _fired = false;
    _gateOpen = false;
    _voicedMs = 0;
    _gapMs = 0;
  }

  /// Whether the mic may hold Woi's echo now (playback inside the window).
  bool get echoExpected {
    if (_refEndFrame < 0) return false;
    final now = _nowFrame;
    return _refEndFrame >= now - maxDelayMs ~/ 10 - 2;
  }

  /// Milliseconds of playback still to be heard (0 when nothing is queued).
  int get queuedMs => _refNext < 0 ? 0 : max(0, (_refNext - _nowFrame) * 10 + _refCarryN * 1000 ~/ _rate);

  /// Whether Woi audio is scheduled at or before now (not just queued).
  bool get playbackStarted {
    if (_refEndFrame < 0) return false;
    final now = _nowFrame;
    for (var f = now; f >= now - maxDelayMs ~/ 10; f--) {
      if (_refFrame[f % _ring] == f) return true;
    }
    return false;
  }

  // ------------------------------------------------------------------ mic

  /// Feeds mic audio that just arrived. Returns true once per reply when the
  /// user starts talking over Woi (then [gateOpen] is true). [audible]: the
  /// player reports playback; with no reference inside the delay window yet
  /// (the first output-latency ms of a reply, a coarse player clock) the
  /// upcoming reference stands in.
  bool process(Uint8List pcm16, {bool audible = false}) {
    final n = pcm16.length ~/ 2;
    if (n == 0) return false;
    final total = _micCarryN + n;
    final frames = total ~/ _hop;
    final now = _nowFrame;
    final bd = ByteData.sublistView(pcm16);
    var hit = false;
    var k = 0;
    for (var i = 0; i < n; i++) {
      _micCarry[_micCarryN++] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      if (_micCarryN == _hop) {
        // Frame time: the newest frame of this chunk is "now".
        final t = now - (frames - 1 - k);
        if (_micFrame(t, audible)) hit = true;
        _micPrev.setAll(0, _micCarry);
        _micCarryN = 0;
        k++;
      }
    }
    return hit;
  }

  bool _micFrame(int t, bool audible) {
    _analyze(_micPrev, _micCarry, _bands);
    final lag = _lagFrames;
    final lo = lag != null ? t - lag - lagSlackMs ~/ 10 : t - maxDelayMs ~/ 10;
    final hi = lag != null ? t - lag + lagSlackMs ~/ 10 : t - minDelayMs ~/ 10;
    var refAny = false;
    var predTotal = 0.0;
    for (var b = 0; b < nb; b++) {
      _pred[b] = 0;
    }
    // Max over the window per band (the echo can come from any of these).
    for (var f = lo; f <= hi; f++) {
      final slot = f % _ring;
      if (f < 0 || _refFrame[slot] != f) continue;
      refAny = true;
      for (var b = 0; b < nb; b++) {
        final v = _ref[slot * nb + b];
        if (v > _pred[b]) _pred[b] = v;
      }
    }
    if (lag != null && !refAny) {
      // Outside the narrow window, but playback may still be in the wide one.
      for (var f = t - maxDelayMs ~/ 10; f <= t - minDelayMs ~/ 10 && !refAny; f++) {
        if (f >= 0 && _refFrame[f % _ring] == f) refAny = true;
      }
    }
    if (!refAny && audible) {
      for (var f = t + 1; f <= t + 30; f++) {
        final slot = f % _ring;
        if (_refFrame[slot] != f) continue;
        refAny = true;
        for (var b = 0; b < nb; b++) {
          final v = _ref[slot * nb + b];
          if (v > _pred[b]) _pred[b] = v;
        }
      }
    }
    for (var b = 0; b < nb; b++) {
      predTotal += _pred[b];
    }
    _trackLag(t);
    final margin = pow(10, marginDb / 10).toDouble();
    var nearBands = 0;
    var excess = 0.0;
    for (var b = 0; b < nb; b++) {
      final m = _bands[b];
      // Distortion spreads energy across bands: part of the total reference
      // counts in every band.
      final ref = _pred[b] + 0.05 * predTotal / nb;
      final echo = _coupling[b] * ref;
      final thr = margin * echo + 4 * _noise[b];
      _thr[b] = thr;
      if (m > thr) {
        nearBands++;
        excess += m - thr;
      }
    }
    // Analysis energy → RMS: sum over a Hann-windowed 20 ms frame, both
    // spectrum halves (Parseval), window power 0.375.
    final excessRms = sqrt(2 * excess / (_fft * _win * 0.375));
    lastExcessRms = excessRms;
    final user = nearBands >= minBands && excessRms >= minRms;
    onFrame?.call(t, _bands, _thr, user);
    if (user) {
      _userHangFrames = 20;
    } else if (_userHangFrames > 0) {
      _userHangFrames--;
    }
    if (!refAny) {
      // No playback that can echo: track the noise floor, reset the onset.
      for (var b = 0; b < nb; b++) {
        final m = _bands[b];
        _noise[b] = m < _noise[b] ? _noise[b] * 0.8 + m * 0.2 : _noise[b] * 0.995 + m * 0.005;
      }
      _voicedMs = 0;
      _gapMs = 0;
      return false;
    }
    framesGated++;
    _replyFrames++;
    if (_userHangFrames == 0 && predTotal > 0) {
      // Echo only: learn the coupling per band.
      for (var b = 0; b < nb; b++) {
        final ref = _pred[b] + 0.05 * predTotal / nb;
        if (ref <= 1e-12) continue;
        final m = max(_bands[b] - _noise[b], 0.0);
        final r = min(m / ref, 4.0);
        final c = _coupling[b];
        _coupling[b] = r > c ? c + (r - c) * couplingAttack : c * couplingDecay + r * (1 - couplingDecay);
        if (_replyFrames < 150 && _coupling[b] > _startPeak[b]) _startPeak[b] = _coupling[b];
      }
    }
    if (_fired) return false;
    if (user) {
      _voicedMs += 10 + _gapMs;
      _gapMs = 0;
    } else if (_voicedMs > 0) {
      _gapMs += 10;
      if (_gapMs > maxGapMs) {
        _voicedMs = 0;
        _gapMs = 0;
      }
    }
    if (_voicedMs >= onsetMs) {
      _fired = true;
      _gateOpen = true;
      _voicedMs = 0;
      onsets++;
      return true;
    }
    return false;
  }

  /// Envelope lag search: every 250 ms, correlate the mic's log envelope
  /// with the reference's over the last 5 s for lags 0..790 ms.
  void _trackLag(int t) {
    final slot = _histN % _hist;
    var m = 0.0;
    for (var b = 0; b < nb; b++) {
      m += _bands[b];
    }
    _micEnv[slot] = log(max(m, _envFloor));
    final off = _lagOffset;
    var any = false;
    for (var l = 0; l < 80; l++) {
      final f = t - (l + off);
      final s = f % _ring;
      var r = 0.0;
      if (f >= 0 && _refFrame[s] == f) {
        any = true;
        for (var b = 0; b < nb; b++) {
          r += _ref[s * nb + b];
        }
      }
      // No playback at that lag is silence (not "unknown"): skipping those
      // frames would compare different stretches per lag.
      _refEnv[slot * 80 + l] = log(max(r, _envFloor));
    }
    // Frames with no playback at any lag carry no information.
    if (!any) _micEnv[slot] = double.nan;
    _histN++;
    if (++_sinceLagSearch < 25 || _histN < 150) return;
    _sinceLagSearch = 0;
    final count = min(_histN, _hist);
    var best = -1.0;
    var bestLag = -1;
    for (var l = 0; l < 80; l++) {
      var n = 0;
      var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
      for (var i = 0; i < count; i++) {
        final s = (_histN - 1 - i) % _hist;
        final y = _micEnv[s];
        if (y.isNaN) continue;
        final x = _refEnv[s * 80 + l];
        n++;
        sx += x;
        sy += y;
        sxx += x * x;
        syy += y * y;
        sxy += x * y;
      }
      if (n < 100) continue;
      final cov = sxy - sx * sy / n;
      final vx = sxx - sx * sx / n, vy = syy - sy * sy / n;
      if (vx <= 0 || vy <= 0) continue;
      final c = cov / sqrt(vx * vy);
      if (c > best) {
        best = c;
        bestLag = l;
      }
    }
    if (bestLag < 0) return;
    _lagCorr = best;
    _lagFrames = best >= 0.55 ? bestLag + off : null;
  }

  // ------------------------------------------------------------- analysis

  /// Band energies of the 20 ms window [prev, cur] (Hann, 512-point FFT).
  void _analyze(Float64List prev, Float64List cur, Float64List out) {
    for (var i = 0; i < _hop; i++) {
      _re[i] = prev[i] * _hann[i];
      _re[_hop + i] = cur[i] * _hann[_hop + i];
    }
    _re.fillRange(_win, _fft, 0);
    _im.fillRange(0, _fft, 0);
    _fftInPlace(_re, _im);
    for (var b = 0; b < nb; b++) {
      var e = 0.0;
      for (var k = _binLo[b]; k < _binHi[b]; k++) {
        e += _re[k] * _re[k] + _im[k] * _im[k];
      }
      out[b] = e;
    }
  }

  static void _fftInPlace(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2 * pi / len;
      final wr = cos(ang), wi = sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var j = 0; j < len ~/ 2; j++) {
          final a = i + j, b = a + len ~/ 2;
          final xr = re[b] * cr - im[b] * ci;
          final xi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
  }
}
