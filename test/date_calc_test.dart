import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/alarm_service.dart';

// FIX-01 CHARACTERIZATION: pins the CURRENT behavior of calculateAlarmDateTime
// (next-occurrence math). It does NOT assert "correct" behavior — Plan 03's
// reschedule-on-all-paths work depends on these invariants staying green.
//
// The function reads DateTime.now(), so assertions are expressed as invariants
// relative to "now" rather than fixed timestamps.
void main() {
  group('calculateAlarmDateTime — one-time (repeatDays empty)', () {
    test('result matches requested hour/minute', () {
      final result = calculateAlarmDateTime(const TimeOfDay(hour: 9, minute: 15), const []);
      expect(result.hour, 9);
      expect(result.minute, 15);
      expect(result.second, 0);
    });

    test('result is now-or-future and within the next 24 hours', () {
      final now = DateTime.now();
      final result = calculateAlarmDateTime(
        TimeOfDay(hour: now.hour, minute: now.minute),
        const [],
      );
      // Same hh:mm as "now": since target == now is NOT isBefore(now), the
      // current behavior keeps it today (returns target, not +1 day).
      expect(result.isBefore(now.subtract(const Duration(seconds: 1))), isFalse);
      expect(result.difference(now).inHours.abs() <= 24, isTrue);
    });

    test('a time already passed today rolls to tomorrow', () {
      final now = DateTime.now();
      final past = now.subtract(const Duration(hours: 1));
      final result = calculateAlarmDateTime(
        TimeOfDay(hour: past.hour, minute: past.minute),
        const [],
      );
      expect(result.isAfter(now), isTrue);
      expect(result.day, now.add(const Duration(days: 1)).day);
    });
  });

  group('calculateAlarmDateTime — repeating', () {
    test('returns a day whose weekday is in repeatDays', () {
      const repeat = [1, 2, 3, 4, 5]; // weekdays Mon-Fri (DateTime.weekday)
      final result = calculateAlarmDateTime(const TimeOfDay(hour: 6, minute: 0), repeat);
      expect(repeat.contains(result.weekday), isTrue);
      expect(result.hour, 6);
      expect(result.minute, 0);
    });

    test('result is in the future and within the next 7 days', () {
      final now = DateTime.now();
      // Every weekday selected => always finds a valid future occurrence soon.
      const allDays = [1, 2, 3, 4, 5, 6, 7];
      final result = calculateAlarmDateTime(
        TimeOfDay(hour: now.hour, minute: now.minute),
        allDays,
      );
      expect(result.isBefore(now.subtract(const Duration(seconds: 1))), isFalse);
      expect(result.difference(now).inDays <= 7, isTrue);
    });
  });
}
