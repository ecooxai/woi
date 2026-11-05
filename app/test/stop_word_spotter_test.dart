import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/audio/stop_word_spotter.dart';
import 'package:woi/core/settings/settings.dart';

void main() {
  group('reference veto', () {
    const t = 100000;
    test('no reference hit: kept', () => expect(kwsReferenceVetoes(t, const []), isFalse));
    test('reference hit up to 2 s before: vetoed', () {
      expect(kwsReferenceVetoes(t, const [t - 2000]), isTrue);
      expect(kwsReferenceVetoes(t, const [t - 500]), isTrue);
      expect(kwsReferenceVetoes(t, const [t]), isTrue);
    });
    test('reference hit up to 0.3 s after: vetoed', () {
      expect(kwsReferenceVetoes(t, const [t + 300]), isTrue);
      expect(kwsReferenceVetoes(t, const [t + 301]), isFalse);
    });
    test('reference hit long before or after: kept', () {
      expect(kwsReferenceVetoes(t, const [t - 2001, t + 5000]), isFalse);
    });
  });

  group('keyword tokens', () {
    final tokens = kwsParseTokens('<blk> 0\n▁ST 93\nO 22\nP 26\n▁HO 5\nLD 6\n▁ON 7\n▁W 8\nA 9\nI 10\nT 11\n');
    test('longest match against tokens.txt', () {
      expect(kwsKeywordLine('stop', tokens), '▁ST O P @STOP');
      expect(kwsKeywordLine(' Hold  on ', tokens), '▁HO LD ▁ON @HOLD_ON');
      expect(kwsKeywordLine('wait', tokens), '▁W A I T @WAIT');
    });
    test('unmappable keyword: null', () {
      expect(kwsKeywordLine('xyz', tokens), isNull);
      expect(kwsKeywordLine('  ', tokens), isNull);
    });
  });

  test('24 kHz s16 -> 16 kHz float', () {
    final pcm = Uint8List(480 * 2);
    final bd = ByteData.sublistView(pcm);
    for (var i = 0; i < 480; i++) {
      bd.setInt16(i * 2, 16384, Endian.little);
    }
    final y = kwsResample24to16(pcm);
    expect(y.length, 320);
    expect(y.every((v) => (v - 0.5).abs() < 1e-6), isTrue);
  });

  test('stop words setting', () {
    expect(const AppSettings().stopWordDetection, isTrue);
    expect(const AppSettings().stopWords, ['stop']);
    expect(parseStopWords('Stop, hold  on;; wait'), ['stop', 'hold on', 'wait']);
    final s = const AppSettings().copyWith(stopWordDetection: false, stopWords: ['halt']);
    final back = AppSettings.fromJson(s.toJson());
    expect(back.stopWordDetection, isFalse);
    expect(back.stopWords, ['halt']);
  });
}
