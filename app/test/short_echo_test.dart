import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/echo_transcript.dart';

void main() {
  const woi = ['Pointer moved to the top left corner. The file has three sections and a summary at the end.'];
  const userEn = ['What is in this file?', 'Open the notes folder.'];
  const userZh = ['帮我打开这个文件', '这里写了什么？'];

  String? r(String t, {List<String> said = woi, List<String> user = userEn}) =>
      shortEchoReason(t, said: said, userRecent: user);

  group('echo: short foreign or filler transcripts', () {
    test('the real Korean echo turns from the E2E', () {
      expect(r('아'), isNotNull);
      expect(r('하고'), isNotNull);
      expect(r('아.'), 'filler');
      expect(r('하고'), 'script hangul');
    });
    test('fillers in any language', () {
      for (final t in ['uh', 'Um.', 'hmm', '嗯', '啊', 'あ', 'uh uh']) {
        expect(r(t), 'filler', reason: t);
      }
      expect(r('嗯', user: userZh), 'filler');
    });
    test('other scripts than Woi and the user', () {
      expect(r('谢谢'), 'script han');
      expect(r('Спасибо'), 'script cyrillic');
      expect(r('はい'), 'script kana');
      expect(r('ありがとう'), isNull); // 5 kana: not short
    });
  });

  group('not echo', () {
    test('real short interrupts pass', () {
      for (final t in ['Stop.', 'stop', 'Wait!', 'Hold on.', 'Never mind', 'Cancel', 'quiet']) {
        expect(r(t), isNull, reason: t);
      }
      for (final t in ['停', '停下', '等一下', '别说了', '그만', '잠깐만', '멈춰', '待って', 'стоп', 'Stopp']) {
        expect(r(t), isNull, reason: t);
        expect(r(t, user: userZh), isNull, reason: t);
      }
    });
    test('the user\'s own language and Woi\'s language pass', () {
      expect(r('Yes.'), isNull);
      expect(r('No thanks'), isNull);
      expect(r('好的', user: userZh), isNull);
      expect(r('为什么', user: userZh), isNull);
      // Woi answers in Chinese, the user switched: Woi's script passes.
      expect(r('明白', said: ['好的，我来打开这个文件'], user: userEn), isNull);
    });
    test('longer transcripts are left to the other rules', () {
      expect(r('하고 있어요 지금 뭐'), isNull);
      expect(r('谢谢你的帮助'), isNull); // 6 Han characters
    });
    test('nothing to compare with: only fillers', () {
      expect(r('하고', said: [], user: []), isNull);
      expect(r('아', said: [], user: []), 'filler');
    });
  });

  test('dominantScript', () {
    expect(dominantScript('Hello'), TranscriptScript.latin);
    expect(dominantScript('하고'), TranscriptScript.hangul);
    expect(dominantScript('今日はいい天気'), TranscriptScript.kana);
    expect(dominantScript('你好'), TranscriptScript.han);
    expect(dominantScript('...'), isNull);
  });
}
