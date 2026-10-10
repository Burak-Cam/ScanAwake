import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/enums.dart';

// MIS-04 characterization: the pure, TFLite-FREE water-match helpers backing the
// Su Sesi (water-sound) mission. waterGroupedScore SUMS only the YAMNet scores at
// the accepted class indices (out-of-set / out-of-range ignored); hasWaterMatch
// gates that grouped sum on a confidence floor; accumulateWaterHold is SUSTAINED
// (not cumulative) and LEAKY — a matched tick adds dtMs, a miss DECAYS by half a
// tick (clamped at 0), NOT a hard reset (SC-4 device finding: YAMNet briefly
// misreads real water as Toothbrush/Insect, and a hard reset wiped near-complete
// progress). Also pins the SC-4 device-calibrated constants + the
// kWaterHoldMs >= 2*kWaterThrottleMs invariant, proves MissionType.su resolves
// through the defensive decode (dismiss must never crash — D-11), and asserts
// TR/EN parity for every new string. No tflite_flutter / record import — the
// device-free seam.
void main() {
  group('constant values pinned (calibration regression guard)', () {
    test('kWaterConfidence is 0.70 (grouped floor, SC-4 device-calibrated)', () {
      expect(kWaterConfidence, 0.70);
    });
    test('kWaterHoldMs is 2500 (~2.5s sustained)', () {
      expect(kWaterHoldMs, 2500);
    });
    test('kWaterThrottleMs is 750 (~1Hz YAMNet cadence)', () {
      expect(kWaterThrottleMs, 750);
    });
    test('kWaterClassIndices is the water set (SC-4 core + 2026-10-10 liquid set)', () {
      // SC-4 core: Water, Water tap/faucet, Sink, Bathtub. 2026-10-10: Toilet
      // flush, Liquid, Splash, Drip, Pour, Trickle, Gush, Fill (AudioSet/YAMNet).
      expect(kWaterClassIndices,
          {282, 364, 365, 366, 368, 438, 439, 442, 443, 444, 445, 446});
    });

    test('noise-prone water-ish classes stay EXCLUDED (fan bypass guard)', () {
      // Offline YAMNet: loud pink noise (fan proxy) scores Waterfall 0.71 and
      // Stream 0.14; Hiss/Steam also fire on non-water. Never add these.
      for (final i in const [79, 286, 287, 290, 283, 288, 289]) {
        expect(kWaterClassIndices.contains(i), isFalse, reason: 'index $i');
      }
    });
    test('kWaterHoldMs >= 2 * kWaterThrottleMs (>=2 detections required)', () {
      // A single false-positive throttled tick can never complete the mission.
      expect(kWaterHoldMs >= 2 * kWaterThrottleMs, isTrue);
    });
  });

  group('waterGroupedScore / hasWaterMatch (grouped-sum AND floor)', () {
    // Explicit index set + explicit floor — these pin the helper LOGIC, decoupled
    // from the calibrated kWaterConfidence (pinned separately above).
    final waterIdx = {1, 3, 5};
    const floor = 0.5;

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
      // 0.3 + 0.3 = 0.6 >= 0.5
      expect(hasWaterMatch(scores, waterIdx, floor), isTrue);
    });
    test('grouped sum below floor does NOT match', () {
      final scores = [0.0, 0.2, 0.0, 0.2, 0.0, 0.0];
      // 0.2 + 0.2 = 0.4 < 0.5
      expect(hasWaterMatch(scores, waterIdx, floor), isFalse);
    });
    test('grouped sum exactly at the floor matches (>= boundary)', () {
      final scores = [0.0, 0.25, 0.0, 0.25, 0.0, 0.0];
      // 0.25 + 0.25 = 0.50 == floor
      expect(hasWaterMatch(scores, waterIdx, floor), isTrue);
    });
    test('out-of-set high scores are ignored (only in-set sum counts)', () {
      // index 0 (0.99) is not in the water set → ignored; in-set 0.2+0.2 < floor.
      final scores = [0.99, 0.2, 0.0, 0.2, 0.0, 0.0];
      expect(hasWaterMatch(scores, waterIdx, floor), isFalse);
    });
  });

  group('accumulateWaterHold (D-09: sustained with leaky decay, not hard reset)', () {
    test('matched tick adds dtMs', () {
      expect(accumulateWaterHold(2000, true, 500), 2500);
    });
    test('a miss DECAYS by half a tick (NOT a hard reset)', () {
      // SC-4: a single misclassification must not wipe near-complete progress.
      expect(accumulateWaterHold(2000, false, 500), 1750); // 2000 - (500 ~/ 2)
    });
    test('decay is slower than fill (a miss removes less than a match adds)', () {
      const held = 1000, dt = 600;
      final lostOnMiss = held - accumulateWaterHold(held, false, dt);
      final gainedOnMatch = accumulateWaterHold(held, true, dt) - held;
      expect(lostOnMiss < gainedOnMatch, isTrue);
    });
    test('a miss clamps at 0 (never negative)', () {
      expect(accumulateWaterHold(100, false, 500), 0); // 100 - 250 -> clamp 0
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

  // REGRESSION (2026-09-24): see kLumenMaxTickMs. The water mission is the most
  // exposed: Android 14+ revokes a backgrounded app's MICROPHONE (while-in-use,
  // measured on API 36 in 10-EMULATOR-SESSION-260924.md), so the record stream
  // stops and resumes — and a ~3 s gap alone used to fill the whole 2500 ms bar.
  group('tick bound (kWaterMaxTickMs) — huge-gap bypass', () {
    test('a single huge-gap tick CANNOT complete the mission from zero', () {
      final held = accumulateWaterHold(0, true, 30000);
      expect(waterComplete(held), isFalse);
      expect(held, kWaterMaxTickMs);
    });

    test('a single false-positive tick can NEVER complete it (doc invariant)', () {
      expect(waterComplete(accumulateWaterHold(0, true, 999999)), isFalse);
    });

    test('two independent detections DO complete it', () {
      int held = accumulateWaterHold(0, true, kWaterMaxTickMs);
      held = accumulateWaterHold(held, true, kWaterMaxTickMs);
      expect(waterComplete(held), isTrue);
    });

    test('a NEGATIVE dt (backwards clock step) never adds progress', () {
      expect(accumulateWaterHold(0, true, -5000), 0);
      expect(accumulateWaterHold(900, true, -5000), 900);
    });

    test('the bound does NOT bind at the throttled cadence', () {
      expect(accumulateWaterHold(0, true, kWaterThrottleMs), kWaterThrottleMs);
    });

    test('kWaterMaxTickMs is 1500 and stays below kWaterHoldMs', () {
      expect(kWaterMaxTickMs, 1500);
      expect(kWaterMaxTickMs < kWaterHoldMs, isTrue);
    });
  });
}
