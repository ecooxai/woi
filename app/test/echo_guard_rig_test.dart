// Echo-guard evaluation on the offline echo-path rig (qa/aec/render_echo.py
// + qa/aec/aec3_offline.cc); skipped unless WOI_AEC_RIG is set:
//
//   WOI_AEC_RIG=<rig dir>[,<rig dir>...] [WOI_AEC_OUT=aec.wav] \
//   [WOI_AEC_EXTRA_MS=200] flutter test test/echo_guard_rig_test.dart
//
// (WOI_AEC_OUT: the canceller output in each rig dir, 24 kHz s16 WAV;
// qa/aec/guard_eval.sh produces it).
//
// Replays the rig like the app sees it: each Woi reply is handed to the
// player in one burst (generated faster than real time), the canceller output
// arrives in 20 ms chunks WOI_AEC_EXTRA_MS after it was captured (canceller +
// capture latency). Writes <rig>/gated.wav (what the server would receive:
// silence while the guard gates, the pre-roll and the mic once an onset
// opened the gate) and prints onsets: true barge-ins (within a near-end
// item) with their latency, and false ones (echo). The old broadband
// detector (BargeInDetector) runs on the same input for comparison.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/barge_in.dart';
import 'package:woi/core/pipeline/echo_guard.dart';

const _rate = 24000;

Int16List _wav(String path) {
  final b = File(path).readAsBytesSync();
  var off = 12;
  while (off + 8 <= b.length) {
    final id = ascii.decode(b.sublist(off, off + 4));
    final len = ByteData.sublistView(b, off + 4, off + 8).getUint32(0, Endian.little);
    if (id == 'data') return Int16List.sublistView(Uint8List.fromList(b.sublist(off + 8, off + 8 + len)));
    off += 8 + len + (len & 1);
  }
  throw StateError('no data chunk in $path');
}

void _writeWav(String path, Int16List x) {
  final data = x.buffer.asUint8List(x.offsetInBytes, x.lengthInBytes);
  final h = ByteData(44);
  void s(int o, String t) => h.buffer.asUint8List().setAll(o, ascii.encode(t));
  s(0, 'RIFF');
  h.setUint32(4, 36 + data.length, Endian.little);
  s(8, 'WAVEfmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, _rate, Endian.little);
  h.setUint32(28, _rate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  s(36, 'data');
  h.setUint32(40, data.length, Endian.little);
  File(path).writeAsBytesSync([...h.buffer.asUint8List(), ...data]);
}

Uint8List _bytes(Int16List x, int a, int b) {
  final n = (b.clamp(0, x.length) - a.clamp(0, x.length)).clamp(0, 1 << 30);
  final out = Int16List(n)..setRange(0, n, x, a.clamp(0, x.length));
  return out.buffer.asUint8List();
}

void main() {
  final rig = Platform.environment['WOI_AEC_RIG'];
  test('echo guard on the offline rig', () {
    for (final dir in rig!.split(',')) {
      _run(dir, '$dir/${Platform.environment['WOI_AEC_OUT'] ?? 'aec.wav'}');
    }
  }, skip: rig == null ? 'set WOI_AEC_RIG to run' : false);
}

void _run(String dir, String outPath) {
  {
    final extraMs = int.parse(Platform.environment['WOI_AEC_EXTRA_MS'] ?? '200');
    final tl = jsonDecode(File('$dir/timeline.json').readAsStringSync()) as Map<String, Object?>;
    List<List<double>> items(String k) => [
      for (final p in tl[k]! as List) [for (final v in p as List) (v as num).toDouble()],
    ];
    final farItems = items('far_items'), nearItems = items('near_items');
    // Speech start of each near-end item (the fixtures lead with silence):
    // the first 10 ms frame within 30 dB of the item's loudest.
    final nearPcm = _wav('$dir/near.wav');
    final speechAt = <double>[];
    for (final it in nearItems) {
      final a = (it[0] * 100).floor(), b = (it[1] * 100).ceil();
      final en = [
        for (var f = a; f < b; f++)
          [for (var i = f * 240; i < min(f * 240 + 240, nearPcm.length); i++) nearPcm[i] * nearPcm[i]].fold(0.0, (x, y) => x + y),
      ];
      final top = en.reduce(max);
      speechAt.add((a + en.indexWhere((v) => v > top * 1e-3)) / 100);
    }
    final far = _wav('$dir/far.wav');
    final mic = _wav(outPath);
    // Detector input: the canceller output itself, or (WOI_AEC_DETECT=mic.wav)
    // the raw mic captured alongside, WOI_AEC_DETECT_MS after capture.
    final env = Platform.environment;
    final det = env['WOI_AEC_DETECT'] == null ? mic : _wav('$dir/${env['WOI_AEC_DETECT']}');
    final detMs = int.parse(env['WOI_AEC_DETECT_MS'] ?? '$extraMs');
    final attack = double.parse(env['WOI_AEC_ATTACK'] ?? '0.4');
    final margin = double.parse(env['WOI_AEC_MARGIN'] ?? '8');
    final n = mic.length;

    var nowUs = 0;
    final g = EchoGuard(
      nowUs: () => nowUs,
      couplingAttack: attack,
      marginDb: margin,
      couplingDecay: double.tryParse(env['WOI_AEC_DECAY'] ?? '') ?? 0.95,
      onsetMs: int.tryParse(env['WOI_AEC_ONSET_MS'] ?? '') ?? 100,
      maxGapMs: int.tryParse(env['WOI_AEC_GAP_MS'] ?? '') ?? 60,
    );
    final old = BargeInDetector();
    final gated = Int16List(n);
    final preroll = _rate * 4 ~/ 10;
    const chunk = _rate * 20 ~/ 1000;
    var nextFar = 0;
    final onsets = <Map<String, Object?>>[];
    final oldOnsets = <double>[];
    var gateWasOpen = false;
    final lagTrace = <String>[];
    int? resumeAt;
    var pausedFrom = 0;
    final dbg = env['WOI_AEC_DEBUG']?.split(',').map(double.parse).toList();
    if (dbg != null) {
      g.onFrame = (f, m, thr, user) {
        final t = f / 100 - detMs / 1000;
        if (t < dbg[0] || t > dbg[1]) return;
        String d(double v) => (10 * log(v + 1e-12) / ln10).round().toString().padLeft(4);
        // ignore: avoid_print
        print('${t.toStringAsFixed(2)} ${user ? 'U' : '.'} mic ${[for (final v in m) d(v)].join()} | thr ${[for (final v in thr) d(v)].join()}');
      };
    }
    var oldAudibleUntil = -1.0;
    // Timeline in mic time: the chunk ending at sample e is delivered at
    // e/rate + extra.
    for (var e = chunk; e <= n; e += chunk) {
      final tMic = e / _rate;
      nowUs = ((tMic + extraMs / 1000) * 1e6).round();
      // Replies are handed over 60 ms (output latency) before they are heard.
      while (nextFar < farItems.length && farItems[nextFar][0] - 0.065 <= nowUs / 1e6) {
        final it = farItems[nextFar++];
        final pcm = _bytes(far, (it[0] * _rate).round(), (it[1] * _rate).round());
        for (var o = 0; o < pcm.length; o += 4800) {
          g.onPlayback(Uint8List.sublistView(pcm, o, (o + 4800).clamp(0, pcm.length)));
          old.onPlayback(Uint8List.sublistView(pcm, o, (o + 4800).clamp(0, pcm.length)));
        }
        oldAudibleUntil = it[1];
      }
      if (e % (_rate * 2) == 0) lagTrace.add('${(tMic).round()}:${g.lagMs}');
      final c = _bytes(det, e - chunk, e);
      final audible = farItems.any((it) => nowUs / 1e6 >= it[0] && nowUs / 1e6 < it[1] + 0.06);
      nowUs = ((tMic + detMs / 1000) * 1e6).round();
      final hitNow = g.process(c, audible: audible);
      nowUs = ((tMic + extraMs / 1000) * 1e6).round();
      if (hitNow) {
        final t = tMic;
        final near = [
          for (var i = 0; i < nearItems.length; i++)
            if (t >= speechAt[i] - 0.05 && t <= nearItems[i][1] + 0.3) nearItems[i],
        ];
        onsets.add({
          't': double.parse(t.toStringAsFixed(2)),
          // From speech start to detection, in capture time (the pipeline adds
          // WOI_AEC_DETECT_MS on top).
          if (near.isNotEmpty) 'latency_ms': ((t - speechAt[nearItems.indexOf(near.first)]) * 1000).round(),
          'true': near.isNotEmpty,
          if (near.isNotEmpty) 'item': nearItems.indexOf(near.first),
          if (near.isNotEmpty) 'over_woi': farItems.any((f) => near.first[0] >= f[0] && near.first[0] < f[1]),
          'lag_ms': g.lagMs,
        });
        // A false onset pauses Woi (the pipeline's soft barge-in): its echo
        // dies out ~300 ms later; the server hears the 400 ms pre-roll and
        // that tail; unconfirmed, playback resumes after 900 ms and the
        // guard re-arms. (The rendered mic keeps Woi playing: silence it.)
        if (near.isEmpty) {
          pausedFrom = e + _rate * 3 ~/ 10;
          resumeAt = e + _rate * 9 ~/ 10;
        }
      }
      if (resumeAt != null && e >= resumeAt) {
        resumeAt = null;
        g.rearm();
      }
      if (old.process(c, audible: nowUs / 1e6 < oldAudibleUntil)) oldOnsets.add(double.parse(tMic.toStringAsFixed(2)));
      final open = !g.echoExpected || g.gateOpen;
      if (open && !(resumeAt != null && e > pausedFrom)) {
        final from = !gateWasOpen && g.gateOpen ? (e - chunk - preroll).clamp(0, n) : e - chunk;
        gated.setRange(from, e, mic, from);
      }
      gateWasOpen = open;
    }
    _writeWav('$dir/gated.wav', gated);
    final trueOnsets = onsets.where((o) => o['true'] == true).toList();
    final falseOnsets = onsets.where((o) => o['true'] != true).toList();
    bool inNear(double t) => nearItems.any((it) => t >= it[0] - 0.05 && t <= it[1] + 0.3);
    final bargeable = nearItems.where((it) => farItems.any((f) => it[0] >= f[0] && it[0] < f[1])).length;
    final res = {
      'processed': outPath,
      'extra_ms': extraMs,
      'guard_onsets_true': trueOnsets,
      'guard_onsets_false': falseOnsets.map((o) => o['t']).toList(),
      'near_items_over_woi': bargeable,
      'old_onsets_true': oldOnsets.where(inNear).toList(),
      'old_onsets_false': oldOnsets.where((t) => !inNear(t)).toList(),
      'lag_ms': g.lagMs,
      'lag_trace': lagTrace.join(' '),
      'lag_corr': double.parse(g.lagCorrelation.toStringAsFixed(2)),
      'coupling_db': [for (final c in g.couplingDb) c.round()],
    };
    File('$dir/guard.json').writeAsStringSync(jsonEncode(res));
    // ignore: avoid_print
    print('RESULT ${jsonEncode(res)}');
  }
}
