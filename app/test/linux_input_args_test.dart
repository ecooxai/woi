import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/linux_input_control.dart';

void main() {
  test('typeText releases modifiers with key-ups instead of --clearmodifiers', () {
    final a = LinuxInputControl.typeArgs('Hello, world');
    expect(a, isNot(contains('--clearmodifiers')));
    expect(a.first, 'keyup');
    expect(a.sublist(a.indexOf('type')), ['type', '--delay', '12', '--', 'Hello, world']);
    expect(a, containsAll(['Shift_L', 'Control_L', 'Alt_L', 'Super_L']));
  });

  test('text starting with a dash is not parsed as an option', () {
    final a = LinuxInputControl.typeArgs('-rf');
    expect(a.sublist(a.length - 2), ['--', '-rf']);
  });
}
