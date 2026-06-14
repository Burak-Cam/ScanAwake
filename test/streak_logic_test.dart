import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/models/alarm_entity.dart';
import 'package:no_snooze/services/streak_service.dart';

// FIX-04 / D-02,D-03,D-04 characterization: what counts toward the streak.
// Only a REAL alarm on a not-yet-counted day is eligible.
void main() {
  group('streakEligible', () {
    test('real alarm on a different day => true', () {
      expect(streakEligible(AlarmKind.real, '2026-06-12', '2026-06-13'), isTrue);
    });

    test('real alarm same day => false (D-04 same-day neutral)', () {
      expect(streakEligible(AlarmKind.real, '2026-06-13', '2026-06-13'), isFalse);
    });

    test('real alarm with no prior scan => true', () {
      expect(streakEligible(AlarmKind.real, null, '2026-06-13'), isTrue);
    });

    test('test alarm never counts (D-03)', () {
      expect(streakEligible(AlarmKind.test, '2026-06-12', '2026-06-13'), isFalse);
      expect(streakEligible(AlarmKind.test, null, '2026-06-13'), isFalse);
    });

    test('snooze re-arm never counts (D-03)', () {
      expect(streakEligible(AlarmKind.snooze, '2026-06-12', '2026-06-13'), isFalse);
      expect(streakEligible(AlarmKind.snooze, null, '2026-06-13'), isFalse);
    });
  });
}
