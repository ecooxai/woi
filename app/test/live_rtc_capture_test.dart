import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/live_rtc_flutter.dart';
import 'package:woi/platform/audio_io.dart';

class _NativeRtc {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  static const methods = MethodChannel('FlutterWebRTC.Method');
  static const peer = 'FlutterWebRTC/peerConnectionEventtest-peer';
  static const channels = [
    'FlutterWebRTC.Event',
    peer,
    'FlutterWebRTC/dataChannelEventtest-peertest-channel',
  ];
  final calls = <MethodCall>[];
  final _called = StreamController<String>.broadcast(sync: true);
  int queries = 0, captures = 0;
  int publishAfter = 0;
  bool failCapture = false;
  Completer<Map<String, Object?>>? mediaGate;
  Completer<void>? detachGate, disposeGate;

  static Map<String, Object?> track(String id) => {
    'id': id,
    'label': 'Microphone',
    'kind': 'audio',
    'enabled': true,
  };
  static Map<String, Object?> stream(int n) => {
    'streamId': 'stream-$n',
    'audioTracks': [track('mic-$n')],
    'videoTracks': [],
  };
  static Map<String, Object?> sender([String? id]) => {
    'senderId': 'mic-sender',
    'track': id == null ? <String, Object?>{} : track(id),
    'ownsTrack': false,
    'rtpParameters': {
      'transactionId': 'params',
      'rtcp': {'cname': 'woi', 'reducedSize': true},
      'codecs': [],
      'encodings': [],
      'headerExtensions': [],
    },
  };

  Future<void> seen(String method) async {
    if (calls.any((call) => call.method == method)) return;
    await _called.stream
        .firstWhere((name) => name == method)
        .timeout(const Duration(seconds: 2));
  }

  void install() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      _called.add(call.method);
      switch (call.method) {
        case 'createPeerConnection':
          return {'peerConnectionId': 'test-peer'};
        case 'getSources':
          queries++;
          return {
            'sources': [
              {
                'kind': 'audioinput',
                'deviceId': 'raw',
                'label': 'Default mic',
                'groupId': '',
              },
              if (queries > publishAfter)
                {
                  'kind': 'audioinput',
                  'deviceId': 'pulse-fresh',
                  'label': 'Woi AEC generation 2',
                  'groupId': '',
                },
            ],
          };
        case 'getUserMedia':
          captures++;
          if (failCapture) {
            throw PlatformException(
              code: 'capture_unavailable',
              message: 'planned capture failure',
            );
          }
          return mediaGate == null ? stream(captures) : await mediaGate!.future;
        case 'addTrack':
          return sender((call.arguments as Map)['trackId'] as String);
        case 'addTransceiver':
          return {
            'transceiverId': 'audio',
            'direction': 'sendrecv',
            'mid': '0',
            'sender': sender(),
            'receiver': {
              'receiverId': 'remote',
              'track': track('remote'),
              'rtpParameters': {
                'transactionId': 'params',
                'rtcp': {'cname': 'woi', 'reducedSize': true},
                'codecs': [],
                'encodings': [],
                'headerExtensions': [],
              },
            },
          };
        case 'rtpSenderReplaceTrack':
          if ((call.arguments as Map)['trackId'] == '') {
            await detachGate?.future;
          }
          return null;
        case 'trackDispose':
          await disposeGate?.future;
          return null;
        case 'createDataChannel':
          return {'id': 1, 'flutterId': 'test-channel'};
        case 'createOffer':
        case 'getLocalDescription':
          return {
            'type': 'offer',
            'sdp': 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n',
          };
        case 'setLocalDescription':
          await messenger.handlePlatformMessage(
            peer,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'iceGatheringState',
              'state': 'complete',
            }),
            (_) {},
          );
          return null;
        default:
          return null;
      }
    });
  }

  Future<void> dataEvent(Map<String, Object?> event) async {
    await messenger.handlePlatformMessage(
      'FlutterWebRTC/dataChannelEventtest-peertest-channel',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  Future<void> close() async {
    messenger.setMockMethodCallHandler(methods, null);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    await _called.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeRtc native;
  setUp(() {
    // These cases exercise PipeWire capture leases, not Android native audio.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    native = _NativeRtc()..install();
  });
  tearDown(() async {
    await native.close();
    debugDefaultTargetPlatformOverride = null;
  });

  EchoCaptureLease lease(void Function() released) => EchoCaptureLease(
    deviceName: 'woi_aec_source_2',
    deviceLabel: 'Woi AEC generation 2',
    release: () async => released(),
  );

  test(
    'RTC waits for the fresh AEC device and never captures the raw input',
    () async {
      native.publishAfter = 1;
      native.failCapture = true;
      var releases = 0;
      final transport = FlutterLiveRtcTransport(
        captureDeviceProvider: () async => lease(() => releases++),
      );
      await expectLater(
        transport.createOffer(),
        throwsA(contains('planned capture failure')),
      );
      expect(native.queries, 2);
      final args =
          native.calls
                  .singleWhere((call) => call.method == 'getUserMedia')
                  .arguments
              as Map;
      final audio = (args['constraints'] as Map)['audio'] as Map;
      expect(audio['optional'], [
        {'sourceId': 'pulse-fresh'},
      ]);
      expect(audio['echoCancellation'], isFalse);
      expect(releases, 1);
      await transport.close();
      expect(releases, 1);
    },
  );

  test(
    'close during AEC startup waits for and releases the late lease',
    () async {
      final ready = Completer<EchoCaptureLease?>(),
          requested = Completer<void>();
      var releases = 0;
      final transport = FlutterLiveRtcTransport(
        captureDeviceProvider: () {
          requested.complete();
          return ready.future;
        },
      );
      final offering = expectLater(transport.createOffer(), throwsStateError);
      await requested.future;
      var closed = false;
      final closing = transport.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      ready.complete(lease(() => releases++));
      await closing;
      await offering;
      expect(releases, 1);
      expect(native.captures, 0);
    },
  );

  test(
    'closing while AEC publication is pending cannot fall back to raw mic',
    () async {
      native.publishAfter = 100;
      var releases = 0;
      final transport = FlutterLiveRtcTransport(
        captureDeviceProvider: () async => lease(() => releases++),
      );
      final offering = expectLater(transport.createOffer(), throwsStateError);
      await native.seen('getSources');
      await transport.close();
      await offering;
      expect(native.captures, 0);
      expect(native.calls.any((call) => call.method == 'addTrack'), isFalse);
      expect(releases, 1);
    },
  );

  test('held reconnect offer opens no microphone and resumes on the existing sender', () async {
    var leases = 0, releases = 0;
    final transport = FlutterLiveRtcTransport(
      captureDeviceProvider: () async {
        leases++;
        return lease(() => releases++);
      },
    );
    await transport.setCaptureSuspended(true);
    await transport.createOffer();
    expect(native.captures, 0);
    expect(leases, 0);
    final transceiver =
        native.calls
                .singleWhere((call) => call.method == 'addTransceiver')
                .arguments
            as Map;
    expect(transceiver['mediaType'], 'audio');
    expect((transceiver['transceiverInit'] as Map)['direction'], 'sendrecv');
    await transport.setCaptureSuspended(false);
    expect(native.captures, 1);
    expect(leases, 1);
    expect(native.calls.any((call) => call.method == 'addTrack'), isFalse);
    expect(
      native.calls.where((call) => call.method == 'createOffer'),
      hasLength(1),
    );
    expect(
      (native.calls
              .singleWhere((call) => call.method == 'rtpSenderReplaceTrack')
              .arguments
          as Map)['trackId'],
      'mic-1',
    );
    await transport.close();
    expect(releases, 1);
  });

  test(
    'exclusive suspension awaits sender detach and native track disposal',
    () async {
      var releases = 0;
      final transport = FlutterLiveRtcTransport(
        captureDeviceProvider: () async => lease(() => releases++),
      );
      await transport.createOffer();
      native.detachGate = Completer<void>();
      native.disposeGate = Completer<void>();
      var suspended = false;
      final suspending = transport
          .setCaptureSuspended(true)
          .then((_) => suspended = true);
      await native.seen('rtpSenderReplaceTrack');
      expect(suspended, isFalse);
      expect(releases, 0);
      native.detachGate!.complete();
      await native.seen('trackDispose');
      expect(suspended, isFalse);
      native.disposeGate!.complete();
      await suspending;
      expect(releases, 1);
      expect(
        native.calls.any((call) => call.method == 'streamDispose'),
        isTrue,
      );
      await transport.close();
      expect(releases, 1);
    },
  );

  test(
    'suspension joins a late native open and never attaches its track',
    () async {
      native.mediaGate = Completer<Map<String, Object?>>();
      final transport = FlutterLiveRtcTransport();
      final offer = transport.createOffer();
      await native.seen('getUserMedia');
      var suspended = false;
      final suspending = transport
          .setCaptureSuspended(true)
          .then((_) => suspended = true);
      await Future<void>.delayed(Duration.zero);
      expect(suspended, isFalse);
      native.mediaGate!.complete(_NativeRtc.stream(1));
      await suspending;
      await offer;
      expect(native.calls.any((call) => call.method == 'trackDispose'), isTrue);
      expect(
        native.calls.any((call) => call.method == 'streamDispose'),
        isTrue,
      );
      expect(native.calls.any((call) => call.method == 'addTrack'), isFalse);
      expect(
        native.calls.where((call) => call.method == 'addTransceiver'),
        hasLength(1),
      );
      await transport.close();
    },
  );

  test(
    'ordinary quick mic toggles keep their existing native stream',
    () async {
      final transport = FlutterLiveRtcTransport();
      await transport.createOffer();
      transport.setMicEnabled(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        native.calls.any((call) => call.method == 'trackDispose'),
        isFalse,
      );
      expect(
        native.calls.any((call) => call.method == 'rtpSenderReplaceTrack'),
        isFalse,
      );
      transport.setMicEnabled(true);
      await transport.setCaptureSuspended(false);
      expect(native.captures, 1);
      expect(
        native.calls.any((call) => call.method == 'trackDispose'),
        isFalse,
      );
      await transport.close();
    },
  );

  test('native control bridge waits for open and forwards exact text and UTF-8 binary events', () async {
    final rtc = FlutterLiveRtcTransport()..setMicEnabled(false);
    addTearDown(rtc.close);
    final received = <String>[];
    final sub = rtc.controlEvents.listen(received.add);
    addTearDown(sub.cancel);
    await rtc.createOffer();
    var ready = false;
    final waiting = rtc.waitForControlReady().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    await native.dataEvent({
      'event': 'dataChannelStateChanged',
      'id': 1,
      'state': 'open',
    });
    await waiting;
    const receipt = '{"type":"session.context.appended"}';
    const turn = '{"type":"turn.done","turn":{"transcript":"東京-714"}}';
    await native.dataEvent({
      'event': 'dataChannelReceiveMessage',
      'id': 1,
      'type': 'text',
      'data': receipt,
    });
    await native.dataEvent({
      'event': 'dataChannelReceiveMessage',
      'id': 1,
      'type': 'binary',
      'data': Uint8List.fromList(utf8.encode(turn)),
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, [receipt, turn]);
    expect(native.captures, 1);
  });

  test(
    'native close releases a pending control-ready wait and capture',
    () async {
      final rtc = FlutterLiveRtcTransport()..setMicEnabled(false);
      await rtc.createOffer();
      final readyFailure = expectLater(
        rtc.waitForControlReady(),
        throwsStateError,
      );
      await rtc.close();
      await readyFailure;
      expect(native.calls.any((c) => c.method == 'trackDispose'), isTrue);
      await expectLater(rtc.waitForControlReady(), throwsStateError);
    },
  );

  test('native closed event channel finishes once and suppresses late control frames', () async {
    final rtc = FlutterLiveRtcTransport()..setMicEnabled(false);
    addTearDown(rtc.close);
    final received = <String>[];
    var done = 0;
    final sub = rtc.controlEvents.listen(received.add, onDone: () => done++);
    addTearDown(sub.cancel);
    await rtc.createOffer();
    await native.dataEvent({
      'event': 'dataChannelStateChanged',
      'id': 1,
      'state': 'open',
    });
    await rtc.waitForControlReady();
    await native.dataEvent({
      'event': 'dataChannelStateChanged',
      'id': 1,
      'state': 'closed',
    });
    await Future<void>.delayed(Duration.zero);
    await native.dataEvent({
      'event': 'dataChannelReceiveMessage',
      'id': 1,
      'type': 'text',
      'data': '{"type":"session.context.appended"}',
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    expect(done, 1);
    await rtc.close();
    expect(done, 1);
  });
}
