import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:woi/platform/linux/exec_util.dart';
import 'package:woi/platform/linux/pipewire_aec.dart';

Future<void> end(Process process) async {
  process.kill(ProcessSignal.sigint);
  await process.exitCode.timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -9;
    },
  );
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError(
      'Expected virtual speaker, mic, room, and output directory',
    );
  }
  final speaker = args[0], mic = args[1], room = args[2], out = args[3];
  final aec = PipewireEchoCancel(
    instanceId: 'reconnect_qa_$pid',
    micTarget: mic,
    speakerTarget: speaker,
    linger: const Duration(milliseconds: 180),
    readyTimeout: const Duration(seconds: 5),
  );
  final results = <Map<String, Object?>>[];
  Future<void> capture(String name, String target, String source) async {
    final files = <Future<void>>[];
    final recorders = <Process>[];
    Process? playback;
    try {
      for (final pair in [('raw', mic), ('aec', source)]) {
        final (exe, command) = withDefaultSigpipe('pw-record', [
          '--raw',
          '--rate',
          '24000',
          '--channels',
          '1',
          '--format',
          's16',
          '--latency',
          '20ms',
          '--target',
          pair.$2,
          '-',
        ]);
        final recorder = await Process.start(exe, command);
        recorders.add(recorder);
        unawaited(recorder.stderr.drain<void>());
        files.add(
          recorder.stdout.pipe(File('$out/$name-${pair.$1}.raw').openWrite()),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      playback = await Process.start('pw-play', [
        '--target',
        target,
        '$out/signal.wav',
      ]);
      unawaited(playback.stdout.drain<void>());
      unawaited(playback.stderr.drain<void>());
      final code = await playback.exitCode.timeout(const Duration(seconds: 9));
      if (code != 0) throw StateError('Probe playback failed: $code');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      if (playback != null) await end(playback);
      for (final recorder in recorders) {
        await end(recorder);
      }
      await Future.wait(files);
    }
    results.add({'name': name, 'source': source, 'status': aec.status});
  }

  try {
    final first = await aec.acquire();
    if (first == null) throw StateError(aec.status);
    await capture('initial', speaker, first);
    aec.release();
    final warm = await aec.acquire();
    if (warm != first) {
      throw StateError('Warm reconnect unexpectedly discarded AEC');
    }
    await capture('warm_reconnect', speaker, warm!);
    aec.release();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final cold = await aec.acquire();
    if (cold == null || cold == first) {
      throw StateError('Cold reconnect reused a stale source');
    }
    await capture('cold_reconnect', speaker, cold);
    aec.release();
    final stopping = aec.stop();
    final racing = aec.acquire();
    await stopping;
    final raced = await racing;
    if (raced == null || raced == cold) {
      throw StateError('Racing reconnect reused a stale source');
    }
    await capture('shutdown_race', speaker, raced);
    await capture('near_voice', room, raced);
    aec.release();
    stdout.writeln(jsonEncode(results));
  } finally {
    await aec.dispose();
  }
}
