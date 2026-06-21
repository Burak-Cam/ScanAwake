import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/enums.dart';

// MIS-03 / D-09 characterization: the pure, ML-Kit-FREE object-match helpers
// backing the Nesne Tanıma (object find) mission. hasMatch gates on
// case-insensitive label membership in the accepted set AND a confidence floor;
// accumulateObjectHold is SUSTAINED + LEAKY — a matched tick adds dtMs, a
// non-matching throttled tick DECAYS by half a tick (clamped at 0), NOT a hard
// reset (the SC-4 water finding generalized to all progress missions). Also pins
// the [ASSUMED] calibration constants (one-line change under SC-4), proves the
// defensive MissionType decode for the new `nesne` value (dismiss must never
// crash — Pitfall 5), and asserts TR/EN parity for every new object/mission
// string.
void main() {
  group('constant values pinned (calibration regression guard)', () {
    test('kObjectConfidence is 0.40 (min match confidence, SC-4 calibrated)', () {
      expect(kObjectConfidence, 0.40);
    });
    test('kObjectHoldMs is 1000 (~1s sustained)', () {
      expect(kObjectHoldMs, 1000);
    });
    test('kObjectThrottleMs is 400 (inference throttle, SC-4 calibrated)', () {
      expect(kObjectThrottleMs, 400);
    });
    test('kObjectHoldMs >= 2 * kObjectThrottleMs (>=2 detections required)', () {
      expect(kObjectHoldMs >= 2 * kObjectThrottleMs, isTrue);
    });
  });

  group('hasMatch (case-insensitive membership AND confidence floor)', () {
    final mug = kObjectTargets['mug']!; // {'coffee mug', 'cup'}

    test('label in accepted set with confidence >= floor matches', () {
      expect(hasMatch([('Cup', 0.9)], mug, kObjectConfidence), isTrue);
    });
    test('confidence below floor is rejected', () {
      expect(hasMatch([('Cup', 0.3)], mug, kObjectConfidence), isFalse);
    });
    test('label not in accepted set is rejected', () {
      expect(hasMatch([('Dog', 0.99)], mug, kObjectConfidence), isFalse);
    });
    test('membership is case-insensitive (cup vs Cup)', () {
      expect(hasMatch([('cup', 0.9)], mug, kObjectConfidence), isTrue);
    });
    test('confidence exactly at the floor matches (>= boundary)', () {
      expect(hasMatch([('Cup', kObjectConfidence)], mug, kObjectConfidence), isTrue);
    });
    test('empty label list does not match', () {
      expect(hasMatch([], mug, kObjectConfidence), isFalse);
    });
    test('concept aggregation: two sub-floor in-set labels SUM to a match', () {
      // cup 0.30 + coffee mug 0.30 = 0.60 >= 0.40 — neither alone clears the
      // floor, but they are the SAME concept (drinkware) so summing matches.
      expect(
        hasMatch([('cup', 0.30), ('coffee mug', 0.30)], mug, kObjectConfidence),
        isTrue,
      );
    });
    test('aggregation ignores out-of-set labels (only in-set confidences sum)', () {
      // dog 0.99 is not drinkware → ignored; cup 0.30 alone < 0.40 → no match.
      expect(
        hasMatch([('dog', 0.99), ('cup', 0.30)], mug, kObjectConfidence),
        isFalse,
      );
    });
  });

  group('accumulateObjectHold (D-02/D-09 analog: sustained with leaky decay)', () {
    test('matched tick adds dtMs', () {
      expect(accumulateObjectHold(800, true, 200), 1000);
    });
    test('non-matching tick DECAYS by half a tick (NOT a hard reset)', () {
      // D-09: a transient misclassification must not wipe near-complete progress.
      expect(accumulateObjectHold(800, false, 200), 700); // 800 - 100
    });
    test('decay is slower than fill (a miss removes less than a match adds)', () {
      const held = 600, dt = 400;
      final lostOnMiss = held - accumulateObjectHold(held, false, dt);
      final gainedOnMatch = accumulateObjectHold(held, true, dt) - held;
      expect(lostOnMiss < gainedOnMatch, isTrue);
    });
    test('a miss clamps at 0 (never negative)', () {
      expect(accumulateObjectHold(50, false, 200), 0); // 50 - 100 -> clamp 0
    });
  });

  group('objectComplete', () {
    test('true exactly at/after kObjectHoldMs', () {
      expect(objectComplete(kObjectHoldMs), isTrue);
      expect(objectComplete(kObjectHoldMs + 1), isTrue);
    });
    test('false below kObjectHoldMs', () {
      expect(objectComplete(kObjectHoldMs - 1), isFalse);
      expect(objectComplete(0), isFalse);
    });
  });

  group('MissionType decode safety (Pitfall 5 — dismiss must never crash)', () {
    test("'nesne' resolves to MissionType.nesne", () {
      expect(MissionType.values.asNameMap()['nesne'], MissionType.nesne);
    });
    test('unknown value resolves to null (caller maps to none)', () {
      expect(MissionType.values.asNameMap()['water'], isNull);
    });
  });

  group('TR/EN parity for new object/mission strings', () {
    const keys = [
      'mission_object_title',
      'mission_object_guide',
      'mission_object_hold',
      'mission_object_name',
      'mission_object_reroll',
      'mission_object_detected',
      // Per-target object_<key> names are checked exhaustively by the
      // 'every object_<key> exists for each kObjectTargets key' test below.
    ];

    test('every new key returns non-empty for BOTH tr and en', () {
      for (final key in keys) {
        final tr = AppStrings.get(key, 'tr');
        final en = AppStrings.get(key, 'en');
        // get() returns the key itself as fallback when missing — so a present
        // key must differ from the bare key (or at minimum be non-empty).
        expect(tr.isNotEmpty, isTrue, reason: 'TR missing for $key');
        expect(en.isNotEmpty, isTrue, reason: 'EN missing for $key');
        expect(tr, isNot(key), reason: 'TR not defined for $key');
        expect(en, isNot(key), reason: 'EN not defined for $key');
      }
    });

    test('every object_<key> exists for each kObjectTargets key', () {
      for (final key in kObjectTargets.keys) {
        final strKey = 'object_$key';
        expect(AppStrings.get(strKey, 'tr'), isNot(strKey), reason: 'TR missing for $strKey');
        expect(AppStrings.get(strKey, 'en'), isNot(strKey), reason: 'EN missing for $strKey');
      }
    });
  });
}
