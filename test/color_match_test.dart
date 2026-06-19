import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/models/enums.dart';

// MIS-02 characterization: the pure color-match helpers backing the Renk Bulma
// mission. hsvMatches gates on hue distance (circular, 0/360 wraparound) AND
// sat/val floors; accumulateColorHold is SUSTAINED, not cumulative — any
// non-matching frame resets progress to 0. Also pins the [ASSUMED] calibration
// constants (one-line change under SC-4), proves the defensive MissionType
// decode for the new `renk` value, and asserts TR/EN parity for every new
// color/mission string.
void main() {
  group('constant values pinned (calibration regression guard)', () {
    test('kColorHueTolerance is 26 (±26° hue window, SC-4 calibrated)', () {
      expect(kColorHueTolerance, 26);
    });
    test('kColorMinSat is 0.46 (earth-tone/brown rejector, SC-4 calibrated)', () {
      expect(kColorMinSat, 0.46);
    });
    test('kColorMinVal is 0.15 (near-black floor only, SC-4 calibrated)', () {
      expect(kColorMinVal, 0.15);
    });
    test('kColorHoldMs is 1000 (~1s sustained)', () {
      expect(kColorHoldMs, 1000);
    });
  });

  group('hueDistance (circular, 0/360 wraparound)', () {
    test('wraps across the 0/360 seam', () {
      expect(hueDistance(350, 10), 20);
      expect(hueDistance(10, 350), 20);
    });
    test('identity is 0', () {
      expect(hueDistance(0, 0), 0);
      expect(hueDistance(120, 120), 0);
    });
    test('antipodal is 180 (the maximum)', () {
      expect(hueDistance(0, 180), 180);
    });
  });

  group('hsvMatches (hue tolerance AND sat/val floors)', () {
    test('within ±20° of red with sat & val above floors matches', () {
      expect(hsvMatches(15, 0.8, 0.8, 0), isTrue);
    });
    test('sat below kColorMinSat is rejected (achromatic)', () {
      expect(hsvMatches(15, 0.1, 0.8, 0), isFalse);
    });
    test('val below kColorMinVal is rejected (dark frame)', () {
      expect(hsvMatches(15, 0.8, 0.1, 0), isFalse);
    });
    test('hue out of tolerance is rejected (50° from red)', () {
      expect(hsvMatches(50, 0.8, 0.8, 0), isFalse);
    });
  });

  group('accumulateColorHold (D-02 analog: sustained, not cumulative)', () {
    test('matching frame adds dtMs', () {
      expect(accumulateColorHold(900, 5, 0.9, 0.9, 0, 200), 1100);
    });
    test('non-matching hue RESETS to 0 (not cumulative)', () {
      expect(accumulateColorHold(900, 200, 0.9, 0.9, 0, 200), 0);
    });
    test('low-sat frame RESETS to 0', () {
      expect(accumulateColorHold(900, 5, 0.1, 0.9, 0, 200), 0);
    });
  });

  group('colorComplete', () {
    test('true exactly at/after kColorHoldMs', () {
      expect(colorComplete(kColorHoldMs), isTrue);
      expect(colorComplete(kColorHoldMs + 1), isTrue);
    });
    test('false below kColorHoldMs', () {
      expect(colorComplete(kColorHoldMs - 1), isFalse);
      expect(colorComplete(0), isFalse);
    });
  });

  group('MissionType decode safety (Pitfall 5 — dismiss must never crash)', () {
    test("'renk' resolves to MissionType.renk", () {
      expect(MissionType.values.asNameMap()['renk'], MissionType.renk);
    });
    test('unknown value resolves to null (caller maps to none)', () {
      expect(MissionType.values.asNameMap()['water'], isNull);
    });
  });

  group('TR/EN parity for new color/mission strings', () {
    const keys = [
      'mission_color_title',
      'mission_color_guide',
      'mission_color_hold',
      'mission_color_name',
      'mission_color_reroll',
      'color_red',
      'color_orange',
      'color_yellow',
      'color_green',
      'color_blue',
      'color_purple',
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
  });
}
