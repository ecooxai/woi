import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/voice/delegation_executor.dart';

import 'fakes/explicit_shell_fixture.dart';

void main() {
  group('explicit shell invocations', () {
    for (final request in [
      explicitShellFixtureRequest,
      'Please call run_bash once with command pwd.',
      'Could you please invoke run_bash with command pwd?',
      'Call `run_bash` with command pwd.',
      '  INVOKE RUN_BASH with command pwd.  ',
      'In the terminal, call run_bash with command pwd.',
      'In the editor, on the page, within the form, at the field, call run_bash with command pwd.',
    ]) {
      test(request, () => expect(looksLikeAction(request), isTrue));
    }

    for (final request in [
      'Do not call run_bash.',
      'Please do not invoke run_bash.',
      'Could you explain how to call run_bash?',
      '"Call run_bash with command pwd."',
      'The prior answer said to call run_bash. What does that mean?',
      'In the guide, "Call run_bash" is a quoted instruction.',
      'In the guide, do not call run_bash.',
      'In the saved analysis, what did run_bash return?',
      'Call me run_bash.',
      'Call run_bashful with command pwd.',
      'Invoke run_bash_extra with command pwd.',
      'Call run_bash-helper with command pwd.',
      'In the editor, on the page, within the form, at the field, inside the modal, call run_bash.',
    ]) {
      test(request, () => expect(looksLikeAction(request), isFalse));
    }
  });
  group('fronted location action requests', () {
    for (final request in [
      "In the 'WOI QA Synthetic Controls' window, focus its text field, select all its text, and type exactly KEYBOARD-714. Do not click its verification button.",
      'On the current page, scroll down two screens.',
      'Within Settings, switch to the Audio tab.',
      'Inside the terminal, please run pwd.',
      'At the command prompt, enter the command pwd.',
      'Please, in the editor, select the current line.',
      'Could you please in the editor, replace the selected text with ALDER-472?',
      'In the editor, on the current line, replace the word alpha with beta.',
      'In the "Draft, revision 2" window, type the new title.',
      "In the writer's window, focus the title field.",
      'In the “Draft, revision 2” window, focus the title field.',
      'In the `Draft, revision 2` window, select all text.',
      'In README.md, replace alpha with beta.',
      'In the "Draft. Revision 2" window, focus its title field.',
      "In the 'Writer's guide, revision 2' window, type the title.",
      "In the writers' terminal, enter pwd.",
      'In the editor, on the page, within the form, at the title field, type ALDER-472.',
    ]) {
      test(request, () => expect(looksLikeAction(request), isTrue));
    }
  });

  group('descriptions and questions stay read-only', () {
    for (final request in [
      'In the saved analysis, what label appeared beside the button?',
      'On the screenshot, what does the button say?',
      'Inside the guide, the text says to click Save.',
      'In the guide, explain how clicking Save works.',
      'In the editor, do not click anything.',
      'On the current page, can a user click that button?',
      'In the guide, "click Save" is a quoted instruction.',
      'In the guide, “click Save” is a quoted instruction.',
      'In the example "page, click Save", what happens?',
      'In the example `page, click Save`, what happens?',
      'In the example "page, click Save',
      '"In the editor, click Save."',
      '“In the editor, click Save.”',
      'The note says "In the editor, click Save." What does it mean?',
      'In the first example. Click is only a label.',
      'In the first example; click is only a label.',
      'In the first example\nclick is only a label.',
      'For example, click the red button is the sample instruction.',
      "In the 'Writer's guide, click Save' section, what does the example mean?",
      'In the ‘Writer’s guide, click Save’ section, what does the example mean?',
      'In the editor, on the page, within the form, at the title field, inside the modal, type ALDER-472.',
      'In the "quoted\npage, click Save" section, what does it mean?',
    ]) {
      test(request, () => expect(looksLikeAction(request), isFalse));
    }
  });

  test('existing direct commands and shortcuts keep their routing', () {
    for (final request in [
      'Run echo hi.',
      'Search the web for Rosetta launch.',
      'Take a screenshot.',
      'Generate a new image of a blue square.',
      'Can you click the OK button?',
      'Ctrl+A',
      'Copy the selected text',
    ]) {
      expect(looksLikeAction(request), isTrue, reason: request);
    }
  });
}
