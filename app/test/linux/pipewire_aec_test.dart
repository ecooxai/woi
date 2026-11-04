import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/pipewire_aec.dart';

void main() {
  test('echo-cancel config: WebRTC, default-sink monitor reference, never a default device', () {
    final aec = PipewireEchoCancel(instanceId: 't1');
    expect(aec.sourceName, 'woi_aec_source_t1');
    final conf = PipewireEchoCancel.config(
      sourceName: aec.sourceName,
      captureName: aec.captureName,
      monitorName: aec.monitorName,
    );
    expect(conf, contains('libpipewire-module-echo-cancel'));
    expect(conf, contains('library.name = aec/libspa-aec-webrtc'));
    expect(conf, contains('monitor.mode = true'));
    expect(conf, contains('node.name = "woi_aec_source_t1"'));
    // monitor.mode names the reference stream through sink.props.
    expect(RegExp(r'sink\.props = \{\s*node\.name = "woi_aec_reference_t1"').hasMatch(conf), isTrue);
    expect(conf, contains('priority.session = 0'));
    expect(conf, contains('node.passive = true'));
    expect(conf, contains('core.daemon = false'));
    expect(aec.status, 'off');
    expect(aec.running, isFalse);
  });

  test('pinned mic and speaker (QA on virtual devices)', () {
    final conf = PipewireEchoCancel.config(
      sourceName: 's',
      captureName: 'c',
      monitorName: 'm',
      micTarget: 'qa_mic',
      speakerTarget: 'qa_speaker',
    );
    expect(RegExp(r'node\.name = "c"[^}]*target\.object = "qa_mic"').hasMatch(conf), isTrue);
    expect(RegExp(r'node\.name = "m"[^}]*target\.object = "qa_speaker"').hasMatch(conf), isTrue);
    expect(PipewireEchoCancel.config(sourceName: 's', captureName: 'c', monitorName: 'm'), isNot(contains('target.object')));
  });

  test('a disposed canceller never starts', () async {
    final aec = PipewireEchoCancel(instanceId: 't2');
    await aec.dispose();
    expect(await aec.acquire(), isNull);
    expect(aec.running, isFalse);
  });
}
