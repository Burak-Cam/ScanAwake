import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/alarm_entity.dart';
import 'package:no_snooze/services/streak_service.dart';

// DECISION (review 2026-10-10): emergency stop policy + the pillow removal.
void main() {
  group('emergencyBreaksStreak', () {
    test('skipping the barcode on a real wake breaks the streak', () {
      expect(emergencyBreaksStreak(AlarmKind.real, barcodeScanned: false),
          isTrue);
    });

    test('a snooze re-fire is the same morning — also breaks it', () {
      expect(emergencyBreaksStreak(AlarmKind.snooze, barcodeScanned: false),
          isTrue);
    });

    test('a test ring never touches the streak', () {
      expect(emergencyBreaksStreak(AlarmKind.test, barcodeScanned: false),
          isFalse);
    });

    test('Stage-2 escape after a real scan is penalty-free', () {
      expect(emergencyBreaksStreak(AlarmKind.real, barcodeScanned: true),
          isFalse);
      expect(emergencyBreaksStreak(AlarmKind.snooze, barcodeScanned: true),
          isFalse);
    });
  });

  // Review 2026-10-10 #5: the decision is re-evaluated after the handler's
  // awaits, so a barcode scanned meanwhile no longer resets the streak.
  group('decideEmergencyStop', () {
    EmergencyStep d({
      bool exited = false,
      bool missionDone = false,
      bool scanned = false,
      bool hasMission = false,
      AlarmKind kind = AlarmKind.real,
    }) =>
        decideEmergencyStop(
            exited: exited,
            missionDone: missionDone,
            scanned: scanned,
            hasMission: hasMission,
            kind: kind);

    test('another exit or the mission-success chain wins -> abort', () {
      expect(d(exited: true), EmergencyStep.abort);
      expect(d(missionDone: true), EmergencyStep.abort);
    });

    test('scanned without a mission -> abort (success tail owns the exit)',
        () {
      expect(d(scanned: true), EmergencyStep.abort);
    });

    test('no scan: real/snooze break the streak, test does not', () {
      expect(d(kind: AlarmKind.real), EmergencyStep.stopBreakStreak);
      expect(d(kind: AlarmKind.snooze), EmergencyStep.stopBreakStreak);
      expect(d(kind: AlarmKind.test), EmergencyStep.stop);
    });

    test('Stage-2 escape after the scan is penalty-free', () {
      expect(d(hasMission: true, scanned: true), EmergencyStep.stop);
    });

    test('a scan during the awaits flips the verdict', () {
      // Mission alarm: before the awaits -> break, after -> plain stop.
      expect(d(hasMission: true), EmergencyStep.stopBreakStreak);
      expect(d(hasMission: true, scanned: true), EmergencyStep.stop);
      // No mission: the success tail now owns the exit.
      expect(d(), EmergencyStep.stopBreakStreak);
      expect(d(scanned: true), EmergencyStep.abort);
    });
  });

  test('emergency pill appears after 120 s', () {
    expect(kEmergencyStopDelaySec, 120);
  });

  test('streak-lost message exists in TR and EN', () {
    for (final lang in ['tr', 'en']) {
      expect(AppStrings.get('alarm_cancelled_streak_lost', lang),
          isNot('alarm_cancelled_streak_lost'));
    }
  });

  test('pillow is not an object target (reachable from bed)', () {
    expect(kObjectTargets.containsKey('pillow'), isFalse);
    expect(kObjectTargets.values.any((s) => s.contains('pillow')), isFalse);
  });
}
