import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../platform/audio_io.dart';

/// A deliberate held recording. No captured bytes leave the device before
/// release. Pending permission/device opens, cancellation and errors all use
/// the same cleanup path, including restoring normal voice input.
class HeldAudioRecorder extends ChangeNotifier {
  HeldAudioRecorder({
    required this.open,
    required this.suspendListening,
    required this.resumeListening,
    required this.submit,
    required this.report,
    this.maxDuration = const Duration(minutes: 2),
  });

  final Future<MicStream> Function() open;
  final Future<void> Function() suspendListening;
  final Future<void> Function() resumeListening;
  final Future<void> Function(Uint8List pcm, bool Function() isCurrent) submit;
  final void Function(String message) report;
  final Duration maxDuration;
  _HeldSession? _session;
  bool _disposed = false;

  bool get recording => _session != null && !_session!.ending;
  bool get processing => _session?.ending ?? false;
  bool get busy => _session != null;
  bool get limitReached => _session?.limitReached ?? false;
  double get level => _session?.mic?.level.value ?? 0;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_disposed || busy) return;
    final session = _session = _HeldSession();
    session.opening = _open(session);
    _changed();
  }

  Future<void> _open(_HeldSession session) async {
    try {
      await suspendListening();
      if (session.ending) return;
      final mic = await open();
      session.mic = mic;
      if (session.ending) {
        session.openedAfterRelease = true;
        return;
      }
      session.sub = mic.chunks.listen(
        (chunk) {
          // close() can flush the mixer's final partial frame after release.
          // Keep that tail until close completes; cancelled sessions discard it.
          if (session.cancelled || _disposed || session.limitReached) return;
          final remaining = maxDuration.inMilliseconds * 48 - session.bytes.length;
          final count = (chunk.length < remaining ? chunk.length : remaining) & ~1;
          if (count > 0) session.bytes.add(Uint8List.fromList(chunk.sublist(0, count)));
          if (session.bytes.length >= maxDuration.inMilliseconds * 48) {
            session.limitReached = true;
            if (!session.ending) {
              report('Recording limit reached. Release to send, or cancel to discard.');
              _changed();
            }
          }
        },
        onError: (Object error) {
          session.error = error;
          unawaited(_finish(session, cancelled: true));
        },
        onDone: () {
          if (session.ending) return;
          session.error = StateError('Audio capture ended before release');
          unawaited(_finish(session, cancelled: true));
        },
      );
    } catch (error) {
      session.error = error;
      unawaited(_finish(session, cancelled: true));
    }
  }

  Future<void> release() async {
    final session = _session;
    if (session != null) await _finish(session, cancelled: false);
  }

  Future<void> cancel() async {
    final session = _session;
    if (session != null) {
      session.cancelled = true;
      await _finish(session, cancelled: true);
    }
  }

  Future<void> _finish(_HeldSession session, {required bool cancelled}) {
    if (cancelled) session.cancelled = true;
    if (session.finished != null) return session.finished!;
    session.ending = true;
    final done = Completer<void>();
    session.finished = done.future;
    _changed();
    unawaited(() async {
      var captureReleased = true;
      try {
        await session.opening;
        try {
          // Keep the listener attached while the native mixer flushes its tail.
          await session.mic?.close();
        } catch (error) {
          captureReleased = false;
          session.error = error;
          rethrow;
        } finally {
          await session.sub?.cancel();
        }
      } catch (error) {
        session.error ??= error;
      }
      // Opening can fail after capture starts if native cleanup was not
      // acknowledged. Do not reacquire the ordinary mic until a later hold
      // successfully opens and releases the native capture.
      captureReleased = captureReleased && session.error is! AudioCaptureReleaseFailure;
      try {
        if (!captureReleased) {
          if (!_disposed) {
            report('Audio release failed. Listening is paused. Hold the microphone again to retry. ${session.error}');
          }
        } else if (session.error != null) {
          if (!_disposed) report('Recording failed: ${session.error}');
        } else if (session.openedAfterRelease && !_disposed) {
          report('Audio capture setup finished. Hold the microphone again, then release to send.');
        } else if (!session.cancelled && !_disposed) {
          final pcm = session.bytes.takeBytes();
          if (pcm.length >= 4800) {
            await submit(pcm, () => !_disposed && !session.cancelled && identical(_session, session));
          } else {
            report('Recording was too short. Hold the microphone, then release to send.');
          }
        }
      } catch (error) {
        if (!_disposed && !session.cancelled) report('Audio could not be sent: $error');
      } finally {
        try {
          if (captureReleased) await resumeListening();
        } catch (error) {
          if (!_disposed) report('Listening could not resume: $error');
        }
        if (identical(_session, session)) _session = null;
        _changed();
        done.complete();
      }
    }());
    return done.future;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
    super.dispose();
  }
}

class _HeldSession {
  Future<void>? opening;
  Future<void>? finished;
  MicStream? mic;
  StreamSubscription<Uint8List>? sub;
  final bytes = BytesBuilder(copy: false);
  Object? error;
  bool openedAfterRelease = false;
  bool limitReached = false;
  bool ending = false;
  bool cancelled = false;
}
