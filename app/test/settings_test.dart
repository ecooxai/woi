import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/settings/settings.dart';

void main() {
  test('thinking earcon is off by default and round-trips through JSON', () {
    const d = AppSettings();
    expect(d.thinkingEarcon, isFalse);
    expect(AppSettings.fromJson(const {}).thinkingEarcon, isFalse);
    final on = d.copyWith(thinkingEarcon: true);
    expect(AppSettings.fromJson(on.toJson()).thinkingEarcon, isTrue);
    expect(on.sessionDiffers(d), isFalse, reason: 'toggling it never reconnects');
  });
}
