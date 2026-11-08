import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:woi/core/voice/live_rtc_flutter.dart';
import 'package:woi/core/voice/live_rtc_transport.dart';

class _NativeAudio {
  static const rtc = MethodChannel('FlutterWebRTC.Method');
  static const android = MethodChannel('woi/android');
  static const events = MethodChannel('FlutterWebRTC.Event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  final seenCalls = StreamController<String>.broadcast(sync: true);
  Completer<void>? initializeGate;
  Completer<void>? helperGate;
  Completer<void>? routeGate;
  String? activeRoute;

  void record(String value) {
    calls.add(value);
    seenCalls.add(value);
  }

  Future<void> seen(String value) async {
    if (calls.contains(value)) return;
    await seenCalls.stream
        .firstWhere((call) => call == value)
        .timeout(const Duration(seconds: 2));
  }

  void install() {
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(rtc, (call) async {
      switch (call.method) {
        case 'initialize':
          record('initialize');
          await initializeGate?.future;
          return null;
        case 'setAndroidAudioConfiguration':
          final config = (call.arguments as Map)['configuration'] as Map;
          final route = config['androidAudioMode'] == 'normal'
              ? 'media'
              : 'phone';
          record('helper:$route');
          await helperGate?.future;
          activeRoute = route;
          return null;
        case 'createPeerConnection':
          // Stop at the first peer call. These checks never create native media,
          // capture a microphone, or make a network/provider connection.
          record('peer');
          throw PlatformException(
            code: 'stopped_after_route',
            message: 'Expected test boundary',
          );
        default:
          throw StateError('Unexpected WebRTC native call: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(android, (call) async {
      if (call.method != 'liveAudioConfigure') {
        throw StateError('Unexpected Android call: ${call.method}');
      }
      final route = (call.arguments as Map)['route'] as String;
      record('route:$route');
      await routeGate?.future;
      activeRoute = route;
      return {'route': route};
    });
  }

  Future<void> close() async {
    for (final gate in [initializeGate, helperGate, routeGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(rtc, null);
    messenger.setMockMethodCallHandler(android, null);
    messenger.setMockMethodCallHandler(events, null);
    await seenCalls.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeAudio native;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    WebRTC.initialized = false;
    native = _NativeAudio()..install();
  });
  tearDown(() async {
    await native.close();
    debugDefaultTargetPlatformOverride = null;
    WebRTC.initialized = false;
  });

  FlutterLiveRtcTransport transport(String route) {
    final result = FlutterLiveRtcTransport(
      options: LiveRtcOptions(androidAudioRoute: route),
    );
    addTearDown(result.close);
    return result;
  }

  final stoppedAfterRoute = throwsA(
    predicate<Object>(
      (error) => error.toString().contains('stopped_after_route'),
    ),
  );

  test(
    'close during initialization prevents both later global mutations',
    () async {
      native.initializeGate = Completer<void>();
      final old = transport('phone');
      final offering = expectLater(old.createOffer(), throwsStateError);
      await native.seen('initialize');
      await old.close();
      native.initializeGate!.complete();
      await offering;
      expect(native.calls, ['initialize']);
    },
  );

  test(
    'close while AudioSwitch awaits prevents stale ADM route mutation',
    () async {
      native.helperGate = Completer<void>();
      final old = transport('phone');
      final offering = expectLater(old.createOffer(), throwsStateError);
      await native.seen('helper:phone');
      await old.close();
      native.helperGate!.complete();
      await offering;
      expect(native.calls, ['initialize', 'helper:phone']);
    },
  );

  test('new media route waits for cancelled phone setup and wins', () async {
    native.helperGate = Completer<void>();
    final old = transport('phone');
    final oldOffering = expectLater(old.createOffer(), throwsStateError);
    await native.seen('helper:phone');
    await old.close();
    final next = transport('media');
    final nextOffering = expectLater(next.createOffer(), stoppedAfterRoute);
    await Future<void>.delayed(Duration.zero);
    expect(native.calls, ['initialize', 'helper:phone']);
    native.helperGate!.complete();
    await oldOffering;
    await nextOffering;
    expect(native.calls, [
      'initialize',
      'helper:phone',
      'helper:media',
      'route:media',
      'peer',
    ]);
    expect(native.activeRoute, 'media');
    await next.close();
  });

  test('in-flight ADM mutation completes before next route applies', () async {
    native.routeGate = Completer<void>();
    final old = transport('phone');
    final oldOffering = expectLater(old.createOffer(), throwsStateError);
    await native.seen('route:phone');
    await old.close();
    final next = transport('media');
    final nextOffering = expectLater(next.createOffer(), stoppedAfterRoute);
    await Future<void>.delayed(Duration.zero);
    expect(native.calls, ['initialize', 'helper:phone', 'route:phone']);
    native.routeGate!.complete();
    await oldOffering;
    await nextOffering;
    expect(native.calls.last, 'peer');
    expect(native.activeRoute, 'media');
    expect(native.calls.where((call) => call == 'peer'), hasLength(1));
    await next.close();
  });
}
