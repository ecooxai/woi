// ignore_for_file: avoid_print
// Offline prototype: keyword spotting + Silero VAD over a mono s16 wav.
// dart run tool/kws_proto.dart <modelDir> <vad.onnx> <wav> [threshold] [score]
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

void main(List<String> a) {
  so.initBindings();
  final dir = a[0];
  final thr = a.length > 3 ? double.parse(a[3]) : 0.25;
  final score = a.length > 4 ? double.parse(a[4]) : 1.0;
  final kws = so.KeywordSpotter(so.KeywordSpotterConfig(
    model: so.OnlineModelConfig(
      transducer: so.OnlineTransducerModelConfig(
        encoder: '$dir/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
        decoder: '$dir/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
        joiner: '$dir/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
      ),
      tokens: '$dir/tokens.txt',
      numThreads: 1,
      debug: false,
    ),
    keywordsFile: Platform.environment['KW'] ?? '$dir/../kw.txt',
    keywordsThreshold: thr,
    keywordsScore: score,
  ));
  final raw = File(a[2]).readAsBytesSync();
  final isRiff = raw[0] == 0x52 && raw[1] == 0x49;
  var start = isRiff ? 44 : 0;
  for (var i = 12; isRiff && i < 8192 && i < raw.length - 4; i++) {
    if (raw[i] == 0x64 && raw[i + 1] == 0x61 && raw[i + 2] == 0x74 && raw[i + 3] == 0x61) {
      start = i + 8;
      break;
    }
  }
  final rate = isRiff
      ? ByteData.sublistView(raw, 24, 28).getUint32(0, Endian.little)
      : int.parse(Platform.environment['RATE'] ?? '24000');
  final n = (raw.length - start) ~/ 2;
  final bd = ByteData.sublistView(raw, start);
  final x = Float32List(n);
  for (var i = 0; i < n; i++) {
    x[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  // Downsample to 16 kHz (24k -> 16k by linear interpolation), as the app would.
  Float32List y;
  if (rate == 16000) {
    y = x;
  } else {
    final m = n * 16000 ~/ rate;
    y = Float32List(m);
    for (var i = 0; i < m; i++) {
      final p = i * rate / 16000;
      final k = p.floor();
      final f = p - k;
      y[i] = k + 1 < n ? x[k] * (1 - f) + x[k + 1] * f : x[k];
    }
  }
  final stream = kws.createStream();
  final sw = Stopwatch()..start();
  const chunk = 1600; // 100 ms
  for (var i = 0; i < y.length; i += chunk) {
    final e = i + chunk < y.length ? i + chunk : y.length;
    stream.acceptWaveform(samples: Float32List.sublistView(y, i, e), sampleRate: 16000);
    while (kws.isReady(stream)) {
      kws.decode(stream);
      final r = kws.getResult(stream);
      if (r.keyword.isNotEmpty) {
        print('KW ${(e / 16000).toStringAsFixed(2)} ${r.keyword}');
        kws.reset(stream);
      }
    }
  }
  final kwsMs = sw.elapsedMilliseconds;
  stream.free();
  kws.free();
  if (a[1] != '-') {
    final vad = so.VoiceActivityDetector(
        config: so.VadModelConfig(
            sileroVad: so.SileroVadModelConfig(model: a[1], minSilenceDuration: 0.25, minSpeechDuration: 0.15),
            numThreads: 1,
            debug: false),
        bufferSizeInSeconds: 60);
    sw.reset();
    for (var i = 0; i + 512 <= y.length; i += 512) {
      vad.acceptWaveform(Float32List.sublistView(y, i, i + 512));
      while (!vad.isEmpty()) {
        final s = vad.front();
        print('VAD ${(s.start / 16000).toStringAsFixed(2)} ${((s.start + s.samples.length) / 16000).toStringAsFixed(2)}');
        vad.pop();
      }
    }
    print('VADCPU ${sw.elapsedMilliseconds} ms');
    vad.free();
  }
  print('KWSCPU $kwsMs ms for ${(y.length / 16000).toStringAsFixed(1)} s audio');
}
