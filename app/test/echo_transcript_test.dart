import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/pipeline/echo_transcript.dart';

void main() {
  group('echo of Woi heard back', () {
    final cases = <String, String>{
      'Boiner moot.': 'Pointer moved.',
      'Point her move.': 'Pointer moved.',
      'Tell me.': 'Done. Tell me what you would like next.',
      'Jasne.': 'Jasne, już otwieram przeglądarkę.',
      'Ja': 'Jasne, już otwieram.',
      'Juz otwieram': 'Jasne, już otwieram przeglądarkę.',
      'I opened the settings for you': 'Okay. I opened the settings for you, the display tab is on the left.',
      'the display tap is on the lift': 'Okay. I opened the settings for you, the display tab is on the left.',
      'Das Fenster ist offen.': 'Gut, das Fenster ist jetzt offen.',
    };
    cases.forEach((heard, said) {
      test('"$heard" for "$said"', () {
        expect(echoScore(heard, [said]), greaterThanOrEqualTo(echoThreshold));
        expect(isEchoOf(heard, ['Earlier reply about something else.', said]), isTrue);
      });
    });
  });

  group('the user, not echo', () {
    final cases = <String, String>{
      'Yes.': 'Is that right?',
      'No.': 'I know a few ways to do that.',
      'Yes, please.': 'Should I open it? It is the one on the left.',
      'What is it about?': 'It is a long article. The author writes that it is about the city and what it was like before.',
      'Open the browser please.': 'The weather today is sunny with a light breeze in the afternoon.',
      'Stop.': 'Sure, I will start the timer for ten minutes.',
      'Tak, otwórz to.': 'Mam otworzyć ten plik czy folder?',
      'Wait, that is the wrong window.': 'I moved the pointer to the window title and clicked it.',
      'Make it bigger.': 'Done. Tell me what you would like next.',
    };
    cases.forEach((heard, said) {
      test('"$heard" after "$said"', () {
        expect(isEchoOf(heard, [said]), isFalse, reason: 'score ${echoScore(heard, [said])}');
      });
    });
  });

  test('empty input', () {
    expect(echoScore('', ['Hello']), 0);
    expect(echoScore('Hello', []), 0);
    expect(echoScore('...', ['Hello']), 0);
  });
}
