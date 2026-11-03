import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/audio/earcon.dart';
import 'audio_io.dart';

/// Brings the main window to the front and plays a cue when something
/// (an approval dialog) needs the user, so Enter/Esc reach Woi and not the
/// window the user was working in.
class WindowAttention {
  WindowAttention({required this.audio, this.channel = const MethodChannel('woi/window'), this.xdotool = 'xdotool'});

  final AudioIO audio;
  final MethodChannel channel;
  final String xdotool;
  PcmPlayer? _player;

  /// Number of requests (tests/diagnostics).
  int requests = 0;

  Future<void> request() async {
    requests++;
    await Future.wait([_raise(), _chime()]);
  }

  Future<void> _raise() async {
    int? xid;
    try {
      // GTK present() with a real X server timestamp; returns the X window id.
      xid = await channel.invokeMethod<int>('present');
    } catch (e) {
      debugPrint('window present: $e');
    }
    if (!Platform.isLinux || xid == null || xid == 0) return;
    // Many X11 WMs refuse focus requests from background apps; activate the
    // window through _NET_ACTIVE_WINDOW as well.
    try {
      await Process.run(xdotool, ['windowactivate', '$xid']);
    } catch (e) {
      debugPrint('xdotool windowactivate: $e');
    }
  }

  Future<void> _chime() async {
    try {
      final p = _player ??= await audio.openPlayer();
      p.write(attentionEarconPcm());
    } catch (e) {
      debugPrint('attention cue: $e');
    }
  }
}
