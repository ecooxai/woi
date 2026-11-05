import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

/// A stop word heard on the mic that Woi itself did not say (no reference
/// hit around it, see [kwsReferenceVetoes]).
class KwsHit {
  const KwsHit({required this.keyword, required this.micTime, required this.threshold});
  final String keyword;

  /// Arrival time of the mic chunk on which the spotter fired (~0.4 s after
  /// the end of the word).
  final DateTime micTime;

  /// The mic spotter's threshold (sherpa-onnx reports no per-hit score).
  final double threshold;

  @override
  String toString() => 'KwsHit($keyword @ ${micTime.millisecondsSinceEpoch})';
}

/// Spots stop words in the mic (after the AEC) and, to drop Woi's own
/// "stopped" etc., in what Woi plays. The pipeline feeds it only while Woi is
/// audible or paused.
abstract class StopWordSpotter {
  /// Hits that survived the reference veto.
  Stream<KwsHit> get hits;

  /// Loads the model (once) and arms [keywords]. Safe to call again with a
  /// new list.
  Future<void> start(List<String> keywords);

  /// Mic audio, 24 kHz mono s16, arrived at [at].
  void addMic(Uint8List pcm16, DateTime at);

  /// Reference audio, 24 kHz mono s16, that the speaker starts playing at
  /// [playAt] (write time + queued ms: the player can be seconds ahead).
  void addReference(Uint8List pcm16, DateTime playAt);

  /// Frees the spotters and the isolate.
  Future<void> dispose();
}

/// The reference veto: a mic hit at [micMs] is Woi's own voice when the
/// reference spotter fired within [[micMs] - [before], [micMs] + [after]]
/// (play times, ms since epoch).
bool kwsReferenceVetoes(
  int micMs,
  Iterable<int> refHitMs, {
  int before = 2000,
  int after = 300,
}) {
  for (final r in refHitMs) {
    if (r >= micMs - before && r <= micMs + after) return true;
  }
  return false;
}

/// Maps a keyword ("stop", "hold on") to the model's BPE tokens by longest
/// match against tokens.txt (each word starts with `▁`, upper case), e.g.
/// `▁ST O P @STOP`. Null when a part matches no token.
String? kwsKeywordLine(String keyword, Set<String> tokens) {
  final words = keyword.trim().toUpperCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return null;
  final out = <String>[];
  for (final w in words) {
    final s = '▁$w';
    var i = 0;
    while (i < s.length) {
      var j = s.length;
      while (j > i && !tokens.contains(s.substring(i, j))) {
        j--;
      }
      if (j == i) return null;
      out.add(s.substring(i, j));
      i = j;
    }
  }
  return '${out.join(' ')} @${words.join('_')}';
}

/// Token set of a sherpa-onnx tokens.txt (`<token> <id>` per line).
Set<String> kwsParseTokens(String tokensTxt) => {
  for (final l in tokensTxt.split('\n'))
    if (l.trim().isNotEmpty) l.trim().split(RegExp(r'\s+')).first,
};

/// 24 kHz s16 -> 16 kHz float (linear interpolation, as in tool/kws_proto.dart).
Float32List kwsResample24to16(Uint8List pcm16) {
  final n = pcm16.length ~/ 2;
  final bd = ByteData.sublistView(pcm16);
  final m = n * 2 ~/ 3;
  final y = Float32List(m);
  for (var i = 0; i < m; i++) {
    final pos = i * 1.5;
    final k = pos.floor();
    final f = pos - k;
    final a = bd.getInt16(k * 2, Endian.little) / 32768.0;
    final b = k + 1 < n ? bd.getInt16((k + 1) * 2, Endian.little) / 32768.0 : a;
    y[i] = a * (1 - f) + b * f;
  }
  return y;
}

/// sherpa-onnx (kws-zipformer-gigaspeech-3.3M int8, Apache-2.0) in a
/// background isolate: one spotter on the mic ([micThreshold]), one on the
/// reference ([refThreshold], low: it only has to catch Woi's own words).
class SherpaStopWordSpotter implements StopWordSpotter {
  SherpaStopWordSpotter({required this.dataDir, this.micThreshold = defaultMicThreshold, this.refThreshold = 0.1});

  static const defaultMicThreshold = 0.4;

  /// The app data dir; the model is copied to `<dataDir>/kws/` on first use
  /// (Android assets are not plain files).
  final String dataDir;
  final double micThreshold;
  final double refThreshold;

  static const _assets = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'];

  final _hits = StreamController<KwsHit>.broadcast();
  Isolate? _iso;
  SendPort? _tx;
  ReceivePort? _rx;
  Future<void>? _starting;
  bool _disposed = false;

  @override
  Stream<KwsHit> get hits => _hits.stream;

  /// Copies the bundled model to [dataDir]/kws unless it is already there
  /// with the same sizes. Returns the dir.
  static Future<String> installModel(String dataDir) async {
    final dir = Directory(p.join(dataDir, 'kws'));
    await dir.create(recursive: true);
    for (final a in _assets) {
      final data = await rootBundle.load('assets/kws/$a');
      final f = File(p.join(dir.path, a));
      if (await f.exists() && await f.length() == data.lengthInBytes) continue;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await tmp.rename(f.path);
    }
    return dir.path;
  }

  @override
  Future<void> start(List<String> keywords) {
    if (_disposed) return Future.value();
    return _starting = (_starting ?? Future.value()).then((_) => _start(keywords));
  }

  Future<void> _start(List<String> keywords) async {
    if (_disposed) return;
    final dir = await installModel(dataDir);
    final tokens = kwsParseTokens(await File(p.join(dir, 'tokens.txt')).readAsString());
    final lines = <String>[];
    for (final k in keywords) {
      final l = kwsKeywordLine(k, tokens);
      if (l == null) {
        debugPrint('kws: "$k" does not map to model tokens, skipped');
      } else {
        lines.add(l);
      }
    }
    if (lines.isEmpty) {
      debugPrint('kws: no usable stop words');
      return;
    }
    final kwFile = File(p.join(dir, 'keywords.txt'));
    await kwFile.writeAsString('${lines.join('\n')}\n');
    if (_iso != null) {
      _tx?.send(['reload']);
      return;
    }
    final rx = ReceivePort();
    _rx = rx;
    final ready = Completer<SendPort>();
    rx.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m == null) {
        // onExit (no message): the worker quit or died.
        _iso = null;
        _tx = null;
        if (!ready.isCompleted) ready.completeError(StateError('kws isolate exited'));
      } else if (m is List && m.length == 2 && m[0] is String && m[0] != 'log' && m[0] != 'hit') {
        debugPrint('kws: isolate error: ${m[0]}');
      } else if (m is List && m.isNotEmpty && m[0] == 'hit') {
        if (!_hits.isClosed) {
          _hits.add(
            KwsHit(
              keyword: m[1] as String,
              micTime: DateTime.fromMillisecondsSinceEpoch(m[2] as int),
              threshold: micThreshold,
            ),
          );
        }
      } else if (m is List && m.isNotEmpty && m[0] == 'log') {
        debugPrint('kws: ${m[1]}');
      }
    });
    _iso = await Isolate.spawn(
      _worker,
      [rx.sendPort, dir, kwFile.path, micThreshold, refThreshold],
      debugName: 'kws',
      onExit: rx.sendPort,
      onError: rx.sendPort,
      errorsAreFatal: true,
    );
    _tx = await ready.future;
    debugPrint('kws: armed ${lines.join(', ')} (mic ${micThreshold.toStringAsFixed(2)}, ref ${refThreshold.toStringAsFixed(2)})');
  }

  @override
  void addMic(Uint8List pcm16, DateTime at) =>
      _tx?.send(['mic', TransferableTypedData.fromList([pcm16]), at.millisecondsSinceEpoch]);

  @override
  void addReference(Uint8List pcm16, DateTime playAt) =>
      _tx?.send(['ref', TransferableTypedData.fromList([pcm16]), playAt.millisecondsSinceEpoch]);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _starting;
    } catch (_) {}
    _tx?.send(['quit']);
    _tx = null;
    // The worker frees its spotters on 'quit'; kill it if it hangs.
    final iso = _iso;
    _iso = null;
    Timer(const Duration(seconds: 2), () {
      iso?.kill(priority: Isolate.immediate);
      _rx?.close();
    });
    await _hits.close();
  }
}

/// One keyword spotter stream, fed chunks stamped with times.
class _Spot {
  _Spot(String dir, String kwFile, double threshold) {
    kws = so.KeywordSpotter(
      so.KeywordSpotterConfig(
        model: so.OnlineModelConfig(
          transducer: so.OnlineTransducerModelConfig(
            encoder: p.join(dir, 'encoder.int8.onnx'),
            decoder: p.join(dir, 'decoder.int8.onnx'),
            joiner: p.join(dir, 'joiner.int8.onnx'),
          ),
          tokens: p.join(dir, 'tokens.txt'),
          numThreads: 1,
          debug: false,
        ),
        keywordsFile: kwFile,
        keywordsThreshold: threshold,
        keywordsScore: 1.0,
      ),
    );
    stream = kws.createStream();
  }

  late final so.KeywordSpotter kws;
  late so.OnlineStream stream;
  int fedUntil = 0; // end time (ms) of the last chunk fed
  int lastAt = 0;

  /// Feeds [x] (16 kHz) ending at [endMs]; returns keywords spotted.
  List<String> feed(Float32List x, int endMs) {
    // A gap (Woi was silent, the reference jumped): start a fresh stream so
    // old context does not smear across it.
    if (lastAt != 0 && (endMs - lastAt).abs() > 3000) {
      kws.reset(stream);
    }
    lastAt = endMs;
    fedUntil = endMs;
    stream.acceptWaveform(samples: x, sampleRate: 16000);
    final out = <String>[];
    while (kws.isReady(stream)) {
      kws.decode(stream);
      final r = kws.getResult(stream);
      if (r.keyword.isNotEmpty) {
        out.add(r.keyword);
        kws.reset(stream);
      }
    }
    return out;
  }

  void free() {
    stream.free();
    kws.free();
  }
}

void _worker(List<Object?> args) {
  final tx = args[0] as SendPort;
  final dir = args[1] as String;
  final kwFile = args[2] as String;
  final micThr = args[3] as double;
  final refThr = args[4] as double;
  so.initBindings();
  var mic = _Spot(dir, kwFile, micThr);
  var ref = _Spot(dir, kwFile, refThr);
  final refHits = <int>[];
  // Mic hits waiting for the reference to cover micTime + 0.3 s.
  final pending = <(String, int)>[];
  const after = 300;
  void decide({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    pending.removeWhere((h) {
      final (kw, t) = h;
      final covered = ref.fedUntil >= t + after || now >= t + after + 200 || force;
      if (!covered) return false;
      if (kwsReferenceVetoes(t, refHits, after: after)) {
        tx.send(['log', 'mic "$kw" at $t vetoed by the reference']);
      } else {
        tx.send(['hit', kw, t]);
      }
      return true;
    });
  }

  final rx = ReceivePort();
  Timer? tick;
  rx.listen((m) {
    final msg = m as List;
    switch (msg[0]) {
      case 'mic':
        final pcm = (msg[1] as TransferableTypedData).materialize().asUint8List();
        final at = msg[2] as int;
        // Woi's audio ended (the reference is behind the mic clock): feed the
        // reference silence up to now, else the streaming model keeps its
        // last frames undecoded and misses a final word ("I've stopped.").
        final gap = at - ref.fedUntil;
        if (ref.fedUntil > 0 && gap > 100 && gap < 3000) {
          for (final _ in ref.feed(Float32List(gap * 16), at)) {
            refHits.add(at);
          }
        }
        for (final kw in mic.feed(kwsResample24to16(pcm), at)) {
          pending.add((kw, at));
        }
        decide();
        if (pending.isNotEmpty) {
          tick ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
            decide();
            if (pending.isEmpty) {
              tick?.cancel();
              tick = null;
            }
          });
        }
      case 'ref':
        final pcm = (msg[1] as TransferableTypedData).materialize().asUint8List();
        final start = msg[2] as int;
        final end = start + pcm.length ~/ 48;
        for (final _ in ref.feed(kwsResample24to16(pcm), end)) {
          refHits.add(end);
        }
        refHits.removeWhere((t) => t < end - 10000);
        decide();
      case 'reload':
        mic.free();
        ref.free();
        mic = _Spot(dir, kwFile, micThr);
        ref = _Spot(dir, kwFile, refThr);
      case 'quit':
        tick?.cancel();
        decide(force: true);
        mic.free();
        ref.free();
        rx.close();
        Isolate.exit();
    }
  });
  tx.send(rx.sendPort);
}
