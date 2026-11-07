import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:woi/core/audio/mic_system_mix.dart';
import 'package:woi/platform/audio_io.dart';

Uint8List pcm(List<int> values) {
  final bytes = Uint8List(values.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    data.setInt16(i * 2, values[i], Endian.little);
  }
  return bytes;
}

List<int> samples(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return List.generate(
    bytes.length ~/ 2,
    (i) => data.getInt16(i * 2, Endian.little),
  );
}

class _Mic implements MicStream {
  final input = StreamController<Uint8List>.broadcast();
  int closes = 0;
  @override
  Stream<Uint8List> get chunks => input.stream;
  @override
  final level = ValueNotifier<double>(0);
  @override
  Future<void> close() async {
    closes++;
    await input.close();
  }
}

void main() {
  test('includes both voices, preserves time order, and clips safely', () {
    final mixer = MicSystemPcmMixer();
    mixer.addMic(pcm([1000, 30000, -30000, 0]));
    mixer.addSystem(pcm([2000, 30000, -30000, 4000]));
    expect(samples(mixer.take(4)), [2100, 32767, -32768, 2800]);
  });
  test('a stalled channel is silence and old backlog stays bounded', () {
    final mixer = MicSystemPcmMixer(maxBufferedSamples: 3);
    mixer.addMic(pcm([1000, 2000, 3000, 4000, 5000]));
    expect(samples(mixer.take(4)), [2100, 2800, 3500, 0]);
    mixer.addSystem(pcm([2000]));
    expect(samples(mixer.take(2)), [1400, 0]);
  });
  test(
    'capture lease is released exactly once across failed/cancelled closes',
    () async {
      var released = 0;
      final lease = EchoCaptureLease(
        deviceName: 'source',
        deviceLabel: 'Source',
        release: () async {
          released++;
        },
      );
      await Future.wait([lease.release(), lease.release()]);
      expect(released, 1);
    },
  );
  test(
    'release flushes the final frame and closes both captures exactly once',
    () async {
      final mic = _Mic(), system = _Mic();
      final mixed = MicSystemMixStream(mic, system);
      final output = <int>[];
      final done = Completer<void>();
      mixed.chunks.listen(
        (chunk) => output.addAll(samples(chunk)),
        onDone: done.complete,
      );
      mic.input.add(pcm([1000, -1000]));
      system.input.add(pcm([2000, -2000]));
      await Future<void>.delayed(Duration.zero);
      await Future.wait([mixed.close(), mixed.close()]);
      await done.future;
      expect(output.take(2), [2100, -2100]);
      expect(mic.closes, 1);
      expect(system.closes, 1);
    },
  );
}
