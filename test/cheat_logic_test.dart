import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/streak_service.dart';

// FIX-02 / D-01 characterization: anti-cheat verdict.
// escape => reset, no-escape => preserve (assume OEM-kill), not-ringing => none.
void main() {
  group('decideCheat', () {
    test('not ringing => none (regardless of escape flag)', () {
      expect(
        decideCheat(wasRinging: false, escapeDetected: false),
        CheatVerdict.none,
      );
      expect(
        decideCheat(wasRinging: false, escapeDetected: true),
        CheatVerdict.none,
      );
    });

    test('ringing + escape detected => reset', () {
      expect(
        decideCheat(wasRinging: true, escapeDetected: true),
        CheatVerdict.reset,
      );
    });

    test('ringing + no escape => preserve (OEM-kill/crash/reboot, D-01)', () {
      expect(
        decideCheat(wasRinging: true, escapeDetected: false),
        CheatVerdict.preserve,
      );
    });
  });
}
