import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/enums.dart';

// MIS-04 characterization: the pure, TFLite-FREE water-match helpers backing the
// Su Sesi (water-sound) mission. waterGroupedScore SUMS only the YAMNet scores at
// the accepted class indices (out-of-set / out-of-range ignored); hasWaterMatch
// gates that grouped sum on a confidence floor; accumulateWaterHold is SUSTAINED,
// not cumulative — a single non-matching throttled tick resets progress to 0.
// Also pins the [ASSUMED] calibration constants (one-line change under SC-4) and
// the kWaterHoldMs >= 2*kWaterThrottleMs invariant (a single false-positive tick
// can never complete), proves MissionType.su resolves through the defensive decode
// (dismiss must never crash — D-11), and asserts TR/EN parity for every new
// mission_water_* / water_permission_* string. No tflite_flutter / record import —
// this is the device-free seam.
void main() {
  group('constant values pinned (calibration regression guard)', () {
    test('kWaterConfidence is 0.50 (grouped floor, SC-4 calibrated)', () {
      expect(kWaterConfidence, 0.50);
    });
    test('kWaterHoldMs is 2500 (~2.5s sustained)', () {
      expect(kWaterHoldMs, 2500);
    });
    test('kWaterThrottleMs is 750 (~1Hz YAMNet cadence, SC-4 calibrated)', () {
      expect(kWaterThrottleMs, 750);
    });
    test('kWaterDuckVolume is 0.18 (D-01 soft-loop duck)', () {
      expect(kWaterDuckVolume, 0.18);
    });
    test('kWaterHoldMs >= 2 * kWaterThrottleMs (>=2 detections required)', () {
      // A single false-positive throttled tick can never complete the mission.
      expect(kWaterHoldMs >= 2 * kWaterThrottleMs, isTrue);
    });
  });

  group('waterGroupedScore / hasWaterMatch (grouped-sum AND floor)', () {
    // Explicit index sets — kWaterClassIndices is a Plan-02 PLACEHOLDER (empty).
    final waterIdx = {1, 3, 5};

    test('sums ONLY the scores at indices in the set', () {
      // idx {1,3,5}: 0.2 + 0.3 + 0.1 = 0.6; index 0/2/4 ignored.
      final scores = [0.9, 0.2, 0.9, 0.3, 0.9, 0.1];
      expect(waterGroupedScore(scores, waterIdx), closeTo(0.6, 1e-9));
    });
    test('empty index set scores 0', () {
      expect(waterGroupedScore([0.9, 0.9], <int>{}), 0);
    });
    test('out-of-range indices are ignored (bounds guard)', () {
      // index 5 is out of range for a length-2 list → ignored.
      expect(waterGroupedScore([0.4, 0.4], {0, 5}), closeTo(0.4, 1e-9));
    });
    test('grouped sum >= floor matches', () {
      final scores = [0.0, 0.3, 0.0, 0.3, 0.0, 0.0];
      // 0.3 + 0.3 = 0.6 >= 0.50
      expect(hasWaterMatch(scores, waterIdx, kWaterConfidence), isTrue);
    });
    test('grouped sum below floor does NOT match', () {
      final scores = [0.0, 0.2, 0.0, 0.2, 0.0, 0.0];
      // 0.2 + 0.2 = 0.4 < 0.50
      expect(hasWaterMatch(scores, waterIdx, kWaterConfidence), isFalse);
    });
    test('grouped sum exactly at the floor matches (>= boundary)', () {
      final scores = [0.0, 0.25, 0.0, 0.25, 0.0, 0.0];
      // 0.25 + 0.25 = 0.50 == floor
      expect(hasWaterMatch(scores, waterIdx, kWaterConfidence), isTrue);
    });
    test('out-of-set high scores are ignored (only in-set sum counts)', () {
      // index 0 (0.99) is not in the water set → ignored; in-set 0.2+0.2 < floor.
      final scores = [0.99, 0.2, 0.0, 0.2, 0.0, 0.0];
      expect(hasWaterMatch(scores, waterIdx, kWaterConfidence), isFalse);
    });
  });

  group('accumulateWaterHold (D-09: sustained, not cumulative)', () {
    test('matched tick adds dtMs', () {
      expect(accumulateWaterHold(2000, true, 500), 2500);
    });
    test('non-matching tick RESETS to 0 (not cumulative)', () {
      expect(accumulateWaterHold(2000, false, 500), 0);
    });
  });

  group('waterComplete', () {
    test('true exactly at/after kWaterHoldMs', () {
      expect(waterComplete(kWaterHoldMs), isTrue);
      expect(waterComplete(kWaterHoldMs + 1), isTrue);
    });
    test('false below kWaterHoldMs', () {
      expect(waterComplete(kWaterHoldMs - 1), isFalse);
      expect(waterComplete(0), isFalse);
    });
  });

  group('MissionType.su decode safety (D-11 — dismiss must never crash)', () {
    test("'su' resolves to MissionType.su", () {
      expect(MissionType.values.asNameMap()['su'], MissionType.su);
    });
    test('unknown value still resolves to null (caller maps to none)', () {
      expect(MissionType.values.asNameMap()['water'], isNull);
    });
  });

  group('TR/EN parity for new water/permission strings (D-08/D-10)', () {
    const keys = [
      'mission_water_title',
      'mission_water_guide',
      'mission_water_hold',
      'mission_water_name',
      'mission_water_detected',
      'mission_water_listening',
      'water_permission_title',
      'water_permission_grant',
      'water_permission_settings',
    ];

    test('every new key returns non-empty for BOTH tr and en', () {
      for (final key in keys) {
        final tr = AppStrings.get(key, 'tr');
        final en = AppStrings.get(key, 'en');
        // get() returns the key itself as fallback when missing — so a present
        // key must differ from the bare key (and be non-empty).
        expect(tr.isNotEmpty, isTrue, reason: 'TR missing for $key');
        expect(en.isNotEmpty, isTrue, reason: 'EN missing for $key');
        expect(tr, isNot(key), reason: 'TR not defined for $key');
        expect(en, isNot(key), reason: 'EN not defined for $key');
      }
    });
  });
}
