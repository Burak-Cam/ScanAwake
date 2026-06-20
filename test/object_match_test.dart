import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/enums.dart';

// MIS-03 characterization: the pure, ML-Kit-FREE object-match helpers backing the
// Nesne Tanıma (object find) mission. hasMatch gates on case-insensitive label
// membership in the accepted set AND a confidence floor; accumulateObjectHold is
// SUSTAINED, not cumulative — a single non-matching throttled tick resets progress
// to 0. Also pins the [ASSUMED] calibration constants (one-line change under SC-4),
// proves the defensive MissionType decode for the new `nesne` value (dismiss must
// never crash — Pitfall 5), and asserts TR/EN parity for every new object/mission
// string.
void main() {
  group('constant values pinned (calibration regression guard)', () {
    test('kObjectConfidence is 0.70 (min match confidence, SC-4 calibrated)', () {
      expect(kObjectConfidence, 0.70);
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
    final cup = kObjectTargets['cup']!;

    test('label in accepted set with confidence >= floor matches', () {
      expect(hasMatch([('Cup', 0.9)], cup, kObjectConfidence), isTrue);
    });
    test('confidence below floor is rejected', () {
      expect(hasMatch([('Cup', 0.5)], cup, kObjectConfidence), isFalse);
    });
    test('label not in accepted set is rejected', () {
      expect(hasMatch([('Dog', 0.99)], cup, kObjectConfidence), isFalse);
    });
    test('membership is case-insensitive (cup vs Cup)', () {
      expect(hasMatch([('cup', 0.9)], cup, kObjectConfidence), isTrue);
    });
    test('confidence exactly at the floor matches (>= boundary)', () {
      expect(hasMatch([('Cup', kObjectConfidence)], cup, kObjectConfidence), isTrue);
    });
    test('empty label list does not match', () {
      expect(hasMatch([], cup, kObjectConfidence), isFalse);
    });
  });

  group('accumulateObjectHold (D-02 analog: sustained, not cumulative)', () {
    test('matched tick adds dtMs', () {
      expect(accumulateObjectHold(800, true, 200), 1000);
    });
    test('non-matching tick RESETS to 0 (not cumulative)', () {
      expect(accumulateObjectHold(800, false, 200), 0);
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
      'object_cup',
      'object_glasses',
      'object_phone',
      'object_shoe',
      'object_plant',
      'object_bag',
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
