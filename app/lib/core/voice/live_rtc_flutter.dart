import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../platform/audio_io.dart';
import 'live_rtc_transport.dart';

/// [LiveRtcTransport] on flutter_webrtc (native libwebrtc on Linux desktop).
///
/// libwebrtc's audio device module captures the microphone and plays the
/// remote track itself (PulseAudio API, served by pipewire-pulse), with
/// WebRTC AEC/NS/AGC applied. Linux leases a separate system-monitor AEC
/// source so all speaker audio is cancelled; native AEC is then disabled
/// to avoid cascading filters. The transport still owns capture/playback.
class FlutterLiveRtcTransport implements LiveRtcTransport {
  FlutterLiveRtcTransport({
    this.options = const LiveRtcOptions(),
    this.captureDeviceProvider,
  });

  final Future<EchoCaptureLease?> Function()? captureDeviceProvider;
  EchoCaptureLease? _captureLease;
  bool _closed = false;
  Future<void>? _closing;
  bool _captureSuspended = false;
  bool _mediaReady = false;

  final LiveRtcOptions options;

  RTCPeerConnection? _pc;
  MediaStream? _mic;
  RTCRtpSender? _micSender;
  MediaStreamTrack? _micTrack;
  // The track is detached from its sender while the mic stays off: with no
  // sending audio stream libwebrtc stops the audio device module's
  // recording (a disabled track still records and encodes silence: ~7% CPU
  // on a phone). Re-attached on unmute.
  bool _micAttached = false;
  Timer? _detachTimer;
  Future<void> _micOp = Future.value();
  RTCDataChannel? _dc;
  final List<MediaStreamTrack> _remoteAudio = [];
  bool _speakerEnabled = true;
  bool _micEnabled = true;
  final _states = StreamController<String>.broadcast();
  String _description = 'flutter_webrtc';
  String? _outputId;

  @override
  Stream<String> get connectionStates => _states.stream;

  @override
  String get description => _description;

  Future<String?> _findDevice(String kind, String? match) async {
    if (match == null || match.isEmpty) return null;
    final devices = await navigator.mediaDevices.enumerateDevices();
    final m = match.toLowerCase();
    for (final d in devices) {
      if (d.kind == kind && d.label.toLowerCase().contains(m)) {
        return d.deviceId;
      }
    }
    throw StateError(
      'no $kind device matching "$match" (have: '
      '${devices.where((d) => d.kind == kind).map((d) => d.label).join(', ')})',
    );
  }

  @override
  Future<String> createOffer() async {
    if (_closed) throw StateError('WebRTC transport is closed');
    try {
      return await _createOffer();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<String?> _leasedInput() async {
    final lease = _captureLease;
    if (lease == null) {
      return _findDevice('audioinput', options.inputDeviceMatch);
    }
    // PipeWire publishes the native node before pipewire-pulse/libwebrtc's
    // device cache sees it. Retry enumeration instead of selecting raw input.
    for (var attempt = 0; attempt < 30; attempt++) {
      if (_closed) throw StateError('WebRTC transport is closed');
      if (_captureSuspended) return null;
      final devices = await navigator.mediaDevices.enumerateDevices();
      for (final d in devices) {
        if (d.kind == 'audioinput' &&
            (d.deviceId == lease.deviceName || d.label == lease.deviceLabel)) {
          return d.deviceId;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      'Echo-cancelled microphone ${lease.deviceLabel} is not available to WebRTC',
    );
  }

  Future<String> _createOffer() async {
    final outputId = await _findDevice(
      'audiooutput',
      options.outputDeviceMatch,
    );
    debugPrint('webrtc output: $outputId');
    _outputId = outputId;
    if (outputId != null) await Helper.selectAudioOutput(outputId);

    // No STUN/TURN: the server is a public ICE endpoint and host candidates
    // suffice; any ICE server adds ~6 s of gathering (§3.1, §6.4).
    final pc = await createPeerConnection({
      'iceServers': <Object>[],
      'sdpSemantics': 'unified-plan',
    });
    if (_closed) {
      await pc.close();
      await pc.dispose();
      throw StateError('WebRTC transport closed while creating the connection');
    }
    _pc = pc;
    pc.onConnectionState = (s) {
      final out = _outputId;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          out != null) {
        // libwebrtc's pulse ADM ignores the playout device until playout is
        // initialized (first remote audio); select it again now.
        unawaited(
          Helper.selectAudioOutput(out)
              .catchError((Object e) => debugPrint('webrtc output: $e')),
        );
      }
      if (!_states.isClosed) {
        _states.add(
          s.name.replaceFirst('RTCPeerConnectionState', '').toLowerCase(),
        );
      }
    };
    pc.onTrack = (e) {
      if (e.track.kind == 'audio') {
        _remoteAudio.add(e.track);
        e.track.enabled = _speakerEnabled;
        final out = _outputId;
        if (out != null) {
          // Playout may (re)initialize once remote audio flows; selecting
          // only at `connected` occasionally left the first reply on the
          // default sink.
          for (final ms in const [300, 1500]) {
            Timer(Duration(milliseconds: ms), () {
              if (_pc == null) return;
              Helper.selectAudioOutput(out)
                  .catchError((Object e) => debugPrint('webrtc output: $e'));
            });
          }
        }
      }
    };

    await _queueMic(() async {
      if (!_captureSuspended) await _openNativeCapture();
      if (_closed) throw StateError('WebRTC transport is closed');
      if (_micSender == null) {
        // Preserve an audio m-line while held capture owns the microphone.
        // Resuming replaces this sender's null track without renegotiation.
        final transceiver = await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
        );
        _micSender = transceiver.sender;
        _micAttached = false;
      }
      _mediaReady = true;
    });
    _updateDescription();

    // Carries the same JSON events as the sideband minus audio; we use the
    // sideband, but the server expects the channel to exist.
    _dc = await pc.createDataChannel('oai-events', RTCDataChannelInit());

    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    final offer = await pc.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    });
    await pc.setLocalDescription(offer);
    if (pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    final local = await pc.getLocalDescription();
    final sdp = local?.sdp ?? offer.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('WebRTC produced an empty offer');
    }
    return sdp;
  }

  @override
  Future<void> setAnswer(String sdp) async {
    final pc = _pc ?? (throw StateError('createOffer() first'));
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  /// How long the mic must stay off before recording stops (push-to-talk
  /// presses close together keep the device open and start instantly).
  static const detachAfter = Duration(seconds: 3);

  @override
  void setMicEnabled(bool enabled) {
    _micEnabled = enabled;
    for (final track in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled && !_captureSuspended;
    }
    if (enabled) {
      _detachTimer?.cancel();
      _detachTimer = null;
      if (_mediaReady && !_captureSuspended) _requestAttached(true);
    } else {
      _scheduleDetach();
    }
  }

  @override
  Future<void> setCaptureSuspended(bool suspended) {
    _captureSuspended = suspended;
    _detachTimer?.cancel();
    _detachTimer = null;
    if (suspended) {
      for (final track
          in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
        track.enabled = false;
      }
    }
    return _queueMic(() async {
      if (suspended) {
        await _releaseNativeCapture();
      } else if (!_captureSuspended && !_closed && _mediaReady && _micEnabled) {
        await _openNativeCapture();
      }
      _updateDescription();
    });
  }

  /// All device opens, sender changes, and releases share a barrier. A hold
  /// waits for any late getUserMedia result to be stopped before it proceeds.
  Future<void> _queueMic(Future<void> Function() operation) {
    final next = _micOp.then((_) => operation());
    // Keep the queue usable after an operation fails, while its caller still
    // receives that failure (exclusive capture must never assume success).
    _micOp = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<void> _openNativeCapture() async {
    final pc = _pc;
    if (_closed || _captureSuspended || pc == null) return;
    try {
      if (_mic == null) {
        _captureLease = await captureDeviceProvider?.call();
        if (_closed || _captureSuspended) {
          await _releaseNativeCapture();
          return;
        }
        final inputId = await _leasedInput();
        if (_closed || _captureSuspended) {
          await _releaseNativeCapture();
          return;
        }
        debugPrint('webrtc input: $inputId');
        _mic = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation':
                _captureLease == null && options.echoCancellation,
            'noiseSuppression': options.noiseSuppression,
            'autoGainControl': options.autoGainControl,
            if (inputId != null)
              'optional': [
                {'sourceId': inputId},
              ],
          },
          'video': false,
        });
        if (_closed || _captureSuspended) {
          await _releaseNativeCapture();
          return;
        }
        final tracks = _mic!.getAudioTracks();
        if (tracks.length != 1) {
          throw StateError('Expected one native microphone track');
        }
        _micTrack = tracks.single;
      }
      final track = _micTrack!;
      track.enabled = _micEnabled && !_captureSuspended;
      if (_micSender == null) {
        _micSender = await pc.addTrack(track, _mic!);
        _micAttached = true;
      } else if (!_micAttached) {
        await _micSender!.replaceTrack(track);
        _micAttached = true;
      }
      if (_closed || _captureSuspended) {
        await _releaseNativeCapture();
        return;
      }
      if (!_micEnabled) _scheduleDetach();
      _updateDescription();
    } catch (_) {
      // Resume failures need the same cleanup as first-offer failures.
      try {
        await _releaseNativeCapture();
      } catch (error) {
        debugPrint('webrtc failed capture cleanup: $error');
      }
      rethrow;
    }
  }

  Future<void> _releaseNativeCapture() async {
    _detachTimer?.cancel();
    _detachTimer = null;
    final mic = _mic;
    final lease = _captureLease;
    final attached = _micAttached;
    _mic = null;
    _micTrack = null;
    _captureLease = null;
    _micAttached = false;
    Object? failure;
    StackTrace? trace;
    Future<void> attempt(Future<void> Function() release) async {
      try {
        await release();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    if (attached && _micSender != null) {
      await attempt(() => _micSender!.replaceTrack(null));
    }
    for (final track in mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      await attempt(track.stop);
    }
    if (mic != null) await attempt(mic.dispose);
    if (lease != null) await attempt(lease.release);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  void _scheduleDetach() {
    _detachTimer?.cancel();
    _detachTimer = null;
    if (_closed || _captureSuspended) return;
    _detachTimer = Timer(detachAfter, () {
      _detachTimer = null;
      if (!_micEnabled && _micAttached) _requestAttached(false);
    });
  }

  void _requestAttached(bool attached) {
    unawaited(
      _queueMic(() async {
        if (_closed || _captureSuspended || attached != _micEnabled) return;
        if (attached) {
          await _openNativeCapture();
        } else if (_micAttached && _micSender != null) {
          await _micSender!.replaceTrack(null);
          _micAttached = false;
          debugPrint('webrtc mic detached (recording stopped)');
        }
      }).catchError((Object error) {
        debugPrint('webrtc mic ${attached ? 'attach' : 'detach'}: $error');
      }),
    );
  }

  void _updateDescription() {
    _description =
        'flutter_webrtc (in: ${_captureSuspended ? 'suspended for recording' : _captureLease?.deviceLabel ?? options.inputDeviceMatch ?? 'default'}, '
        'out: ${options.outputDeviceMatch ?? 'default'}, aec: ${_captureLease != null ? 'system monitor' : options.echoCancellation})';
  }

  @override
  void setSpeakerEnabled(bool enabled) {
    _speakerEnabled = enabled;
    for (final t in _remoteAudio) {
      t.enabled = enabled;
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _detachTimer?.cancel();
    _detachTimer = null;
    try {
      await _queueMic(_releaseNativeCapture);
    } catch (error) {
      debugPrint('webrtc capture close: $error');
    }
    final pc = _pc;
    _pc = null;
    _mediaReady = false;
    _micSender = null;
    try {
      await _dc?.close();
    } catch (_) {}
    if (pc != null) {
      try {
        await pc.close();
        await pc.dispose();
      } catch (error) {
        debugPrint('webrtc close: $error');
      }
    }
    _remoteAudio.clear();
    if (!_states.isClosed) await _states.close();
  }
}
