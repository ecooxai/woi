import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'live_rtc_transport.dart';

/// [LiveRtcTransport] on flutter_webrtc (native libwebrtc on Linux desktop).
///
/// libwebrtc's audio device module captures the microphone and plays the
/// remote track itself (PulseAudio API, served by pipewire-pulse), with
/// WebRTC AEC/NS/AGC applied. The app therefore must not run its own
/// pw-record / pw-play for this backend.
class FlutterLiveRtcTransport implements LiveRtcTransport {
  FlutterLiveRtcTransport({this.options = const LiveRtcOptions()});

  final LiveRtcOptions options;

  RTCPeerConnection? _pc;
  MediaStream? _mic;
  RTCRtpSender? _micSender;
  MediaStreamTrack? _micTrack;
  // The track is detached from its sender while the mic stays off: with no
  // sending audio stream libwebrtc stops the audio device module's
  // recording (a disabled track still records and encodes silence: ~7% CPU
  // on a phone). Re-attached on unmute.
  bool _micAttached = true;
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
      if (d.kind == kind && d.label.toLowerCase().contains(m)) return d.deviceId;
    }
    throw StateError(
      'no $kind device matching "$match" (have: '
      '${devices.where((d) => d.kind == kind).map((d) => d.label).join(', ')})',
    );
  }

  @override
  Future<String> createOffer() async {
    final inputId = await _findDevice('audioinput', options.inputDeviceMatch);
    final outputId = await _findDevice('audiooutput', options.outputDeviceMatch);
    debugPrint('webrtc devices: in=$inputId out=$outputId');
    _outputId = outputId;
    if (outputId != null) await Helper.selectAudioOutput(outputId);

    // No STUN/TURN: the server is a public ICE endpoint and host candidates
    // suffice; any ICE server adds ~6 s of gathering (§3.1, §6.4).
    final pc = await createPeerConnection({'iceServers': <Object>[], 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    pc.onConnectionState = (s) {
      final out = _outputId;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && out != null) {
        // libwebrtc's pulse ADM ignores the playout device until playout is
        // initialized (first remote audio); select it again now.
        unawaited(Helper.selectAudioOutput(out).catchError((Object e) => debugPrint('webrtc output: $e')));
      }
      if (!_states.isClosed) _states.add(s.name.replaceFirst('RTCPeerConnectionState', '').toLowerCase());
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
              Helper.selectAudioOutput(out).catchError((Object e) => debugPrint('webrtc output: $e'));
            });
          }
        }
      }
    };

    final mic = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': options.echoCancellation,
        'noiseSuppression': options.noiseSuppression,
        'autoGainControl': options.autoGainControl,
        if (inputId != null)
          'optional': [
            {'sourceId': inputId},
          ],
      },
      'video': false,
    });
    _mic = mic;
    for (final t in mic.getAudioTracks()) {
      // setMicEnabled() may have run before the track existed (a call that is
      // prepared muted, or Muted mode): the track must never start enabled.
      t.enabled = _micEnabled;
      _micSender = await pc.addTrack(t, mic);
      _micTrack = t;
      _micAttached = true;
    }
    if (!_micEnabled) _scheduleDetach();
    _description =
        'flutter_webrtc (in: ${options.inputDeviceMatch ?? 'default'}, '
        'out: ${options.outputDeviceMatch ?? 'default'}, aec: ${options.echoCancellation})';

    // Carries the same JSON events as the sideband minus audio; we use the
    // sideband, but the server expects the channel to exist.
    _dc = await pc.createDataChannel('oai-events', RTCDataChannelInit());

    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) gathered.complete();
    };
    final offer = await pc.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    });
    await pc.setLocalDescription(offer);
    if (pc.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    final local = await pc.getLocalDescription();
    final sdp = local?.sdp ?? offer.sdp;
    if (sdp == null || sdp.isEmpty) throw StateError('WebRTC produced an empty offer');
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
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
    if (enabled) {
      _detachTimer?.cancel();
      _detachTimer = null;
      if (!_micAttached) _setAttached(true);
    } else {
      _scheduleDetach();
    }
  }

  void _scheduleDetach() {
    _detachTimer?.cancel();
    _detachTimer = Timer(detachAfter, () {
      _detachTimer = null;
      if (!_micEnabled && _micAttached) _setAttached(false);
    });
  }

  void _setAttached(bool attached) {
    _micAttached = attached;
    // Serialized: a quick off/on must not apply out of order.
    _micOp = _micOp.then((_) async {
      final sender = _micSender;
      final track = _micTrack;
      if (sender == null || track == null || _pc == null) return;
      try {
        await sender.replaceTrack(attached ? track : null);
        debugPrint('webrtc mic ${attached ? 'attached' : 'detached (recording stopped)'}');
      } catch (e) {
        debugPrint('webrtc mic ${attached ? 'attach' : 'detach'}: $e');
      }
    });
  }

  @override
  void setSpeakerEnabled(bool enabled) {
    _speakerEnabled = enabled;
    for (final t in _remoteAudio) {
      t.enabled = enabled;
    }
  }

  @override
  Future<void> close() async {
    _detachTimer?.cancel();
    _detachTimer = null;
    final pc = _pc;
    _pc = null;
    _micSender = null;
    _micTrack = null;
    try {
      await _dc?.close();
    } catch (_) {}
    for (final t in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await _mic?.dispose();
    } catch (_) {}
    _mic = null;
    if (pc != null) {
      try {
        await pc.close();
        await pc.dispose();
      } catch (e) {
        debugPrint('webrtc close: $e');
      }
    }
    _remoteAudio.clear();
    if (!_states.isClosed) await _states.close();
  }
}
