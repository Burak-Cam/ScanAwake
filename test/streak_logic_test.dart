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

  // STREAK-GRACE: real streak with a 1-day cushion. A single missed day is
  // forgiven (gap 1 or 2 continues); two missed days break it (gap >= 3 resets
  // to 1). Today's wake always counts (a break restarts at 1, never 0).
  group('nextStreak (1-day grace)', () {
    test('no prior scan => starts at 1', () {
      expect(nextStreak(0, null, '2026-06-15'), 1);
    });

    test('unparseable lastScan => starts at 1', () {
      expect(nextStreak(5, 'not-a-date', '2026-06-15'), 1);
    });

    test('consecutive day (gap 1) => continues (+1)', () {
      expect(nextStreak(3, '2026-06-14', '2026-06-15'), 4);
    });

    test('user spec: Mon then Wed (gap 2, one missed day) => continues (+1)', () {
      expect(nextStreak(1, '2026-06-15', '2026-06-17'), 2);
    });

    test('user spec: Sun then Wed (gap 3, two missed days) => resets to 1', () {
      expect(nextStreak(9, '2026-06-14', '2026-06-17'), 1);
    });

    test('long absence (gap 30) => resets to 1', () {
      expect(nextStreak(42, '2026-05-15', '2026-06-14'), 1);
    });

    test('same day (gap 0) => unchanged (defensive; caller gates via eligible)', () {
      expect(nextStreak(7, '2026-06-15', '2026-06-15'), 7);
    });
  });

  // STREAK-GRACE display side: a streak is alive while a wake today could still
  // extend it (gap <= 2), dead once 2+ days are missed (gap >= 3).
  group('streakAlive (inactivity decay)', () {
    test('counted today (gap 0) => alive', () {
      expect(streakAlive('2026-06-15', '2026-06-15'), isTrue);
    });

    test('yesterday (gap 1) => alive', () {
      expect(streakAlive('2026-06-14', '2026-06-15'), isTrue);
    });

    test('grace day (gap 2, one missed) => still alive', () {
      expect(streakAlive('2026-06-15', '2026-06-17'), isTrue);
    });

    test('two missed days (gap 3) => dead', () {
      expect(streakAlive('2026-06-14', '2026-06-17'), isFalse);
    });

    test('null lastScan => dead', () {
      expect(streakAlive(null, '2026-06-15'), isFalse);
    });

    test('alive threshold matches nextStreak: alive iff today would not reset', () {
      // gap 2 -> alive AND nextStreak continues; gap 3 -> dead AND resets.
      expect(streakAlive('2026-06-15', '2026-06-17'), isTrue);
      expect(nextStreak(4, '2026-06-15', '2026-06-17') > 1, isTrue);
      expect(streakAlive('2026-06-14', '2026-06-17'), isFalse);
      expect(nextStreak(4, '2026-06-14', '2026-06-17'), 1);
    });
  });
}
