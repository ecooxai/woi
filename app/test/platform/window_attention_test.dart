import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/earcon.dart';
import 'package:woi/platform/window_attention.dart';

import '../fakes/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('woi/window');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('presents the window and plays the attention cue', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return 0; // no X window id: no xdotool fallback
    });
    final audio = FakeAudioIO();
    final a = WindowAttention(audio: audio, xdotool: '/nonexistent/xdotool');
    await a.request();
    await a.request();
    expect(calls, ['present', 'present']);
    expect(audio.player.written.length, attentionEarconPcm().length * 2, reason: 'one player, reused');
    expect(audio.extraPlayers, isEmpty);
  });

  test('survives a missing native handler', () async {
    final audio = FakeAudioIO();
    await WindowAttention(audio: audio, xdotool: '/nonexistent/xdotool').request();
    expect(audio.player.written.length, attentionEarconPcm().length);
  });

  test('attention cue is short and not clipped', () {
    final pcm = attentionEarconPcm();
    final ms = pcm.length / 2 / 24;
    expect(ms, inInclusiveRange(250, 400));
    var peak = 0;
    final d = ByteData.sublistView(pcm);
    for (var i = 0; i < pcm.length; i += 2) {
      final v = d.getInt16(i, Endian.little).abs();
      if (v > peak) peak = v;
    }
    expect(peak, lessThan(32767 * 0.2));
  });
}
