import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';
import 'package:no_snooze/l10n/app_strings.dart';

// MIS-01 / D-02 / D-09 characterization: the pure sustained-hold helpers backing
// the Lümen mission. Hold is SUSTAINED + LEAKY — a matched tick adds dtMs, a
// below-threshold frame DECAYS by half a tick (clamped at 0), NOT a hard reset
// (the SC-4 water finding generalized to all progress missions). Also pins the
// calibratable constants and asserts TR/EN parity for every new mission string.
void main() {
  group('accumulateHold (D-02/D-09 sustained with leaky decay)', () {
    test('adds dtMs when avgY >= kLumenThreshold', () {
      expect(accumulateHold(0, kLumenThreshold, 100), 100);
      expect(accumulateHold(500, kLumenThreshold + 50, 100), 600);
    });

    test('avgY exactly at threshold counts (>=)', () {
      expect(accumulateHold(200, kLumenThreshold, 50), 250);
    });

    test('a below-threshold tick DECAYS by half a tick (NOT a hard reset)', () {
      // D-09: a transient dark frame must not wipe near-complete progress.
      expect(accumulateHold(2000, kLumenThreshold - 1, 500), 1750); // 2000 - 250
    });

    test('decay is slower than fill (a miss removes less than a match adds)', () {
      const held = 1000, dt = 600;
      final lostOnMiss = held - accumulateHold(held, kLumenThreshold - 1, dt);
      final gainedOnMatch = accumulateHold(held, kLumenThreshold + 10, dt) - held;
      expect(lostOnMiss < gainedOnMatch, isTrue);
    });

    test('a miss clamps at 0 (never negative)', () {
      expect(accumulateHold(100, kLumenThreshold - 1, 500), 0); // 100 - 250 -> 0
      expect(accumulateHold(0, 0, 100), 0);
    });
  });

  group('lumenComplete', () {
    test('true exactly at/after kLumenHoldMs', () {
      expect(lumenComplete(kLumenHoldMs), isTrue);
      expect(lumenComplete(kLumenHoldMs + 1), isTrue);
    });

    test('false below kLumenHoldMs', () {
      expect(lumenComplete(kLumenHoldMs - 1), isFalse);
      expect(lumenComplete(0), isFalse);
    });
  });

  group('simulated tick sequence', () {
    test('above-threshold ticks reach completion at/after kLumenHoldMs', () {
      const dt = 100;
      int held = 0;
      while (!lumenComplete(held)) {
        held = accumulateHold(held, kLumenThreshold + 10, dt);
      }
      expect(held >= kLumenHoldMs, isTrue);
    });

    test('a below-threshold tick mid-sequence decays (not hard reset)', () {
      // dt values stay within kLumenMaxTickMs so this exercises decay, not the
      // tick bound (a 1000 ms tick would now be clamped to 500 — see the
      // 'tick bound' group below).
      int held = 0;
      held = accumulateHold(held, kLumenThreshold + 10, 500); // 500
      held = accumulateHold(held, kLumenThreshold + 10, 500); // 1000
      expect(held, 1000);
      held = accumulateHold(held, kLumenThreshold - 50, 500); // drop => 1000-250
      expect(held, 750);
      expect(lumenComplete(held), isFalse);
    });
  });

  // REGRESSION (2026-09-24): dtMs is real elapsed wall-clock time between ticks,
  // so ANY gap in the frame stream (60 s MIUI camera stall; background ->
  // foreground where Android 14+ revokes a backgrounded app's camera) used to be
  // credited in full on the next matching frame — one frame could complete a
  // "sustained" mission. color_mission only ever defended the slot-spin case;
  // Lümen had no defence at all.
  group('tick bound (kLumenMaxTickMs) — huge-gap bypass', () {
    test('a single huge-gap tick CANNOT complete the mission from zero', () {
      // Pre-fix: accumulateHold(0, bright, 30000) == 30000 => complete.
      expect(lumenComplete(accumulateHold(0, kLumenThreshold + 10, 30000)),
          isFalse);
    });

    test('a huge dt credits at most kLumenMaxTickMs', () {
      expect(accumulateHold(0, kLumenThreshold + 10, 30000), kLumenMaxTickMs);
      expect(accumulateHold(0, kLumenThreshold + 10, 999999), kLumenMaxTickMs);
    });

    test('completion still needs several bounded ticks', () {
      // ceil(2500 / 500) = 5 ticks minimum — genuinely sustained.
      int held = 0, ticks = 0;
      while (!lumenComplete(held)) {
        held = accumulateHold(held, kLumenThreshold + 10, 30000);
        ticks++;
      }
      expect(ticks, (kLumenHoldMs / kLumenMaxTickMs).ceil());
      expect(ticks > 1, isTrue);
    });

    test('a NEGATIVE dt (backwards clock step) never adds progress', () {
      expect(accumulateHold(0, kLumenThreshold + 10, -5000), 0);
      expect(accumulateHold(800, kLumenThreshold + 10, -5000), 800);
      expect(accumulateHold(800, kLumenThreshold - 10, -5000), 800);
    });

    test('the bound does NOT bind at the real frame cadence (15-30 fps)', () {
      // ~33-66 ms per frame — far below the bound, so normal play is unchanged.
      expect(accumulateHold(0, kLumenThreshold + 10, 33), 33);
      expect(accumulateHold(0, kLumenThreshold + 10, 66), 66);
    });

    test('decay is bounded too (a gap cannot wipe the bar in one tick)', () {
      expect(accumulateHold(2000, kLumenThreshold - 10, 30000),
          2000 - kLumenMaxTickMs ~/ 2);
    });
  });

  group('constant values pinned (calibration regression guard)', () {
    test('kLumenThreshold is 140 (avg-Y 0..255, exposure-locked calibration)', () {
      expect(kLumenThreshold, 140);
    });
    test('kLumenHoldMs is 2500 (~2.5s sustained)', () {
      expect(kLumenHoldMs, 2500);
    });
    test('kLumenMaxTickMs is 500 (~10x the 15-30 fps frame cadence)', () {
      expect(kLumenMaxTickMs, 500);
    });
    test('kLumenMaxTickMs < kLumenHoldMs (one tick can never complete it)', () {
      expect(kLumenMaxTickMs < kLumenHoldMs, isTrue);
    });
  });

  group('TR/EN parity for new mission strings', () {
    const keys = [
      'mission_lumen_title',
      'mission_lumen_guide',
      'mission_lumen_brighter',
      'mission_lumen_hold',
      'mission_sound_lowered',
      'mission_menu_title',
      'mission_none',
      'mission_lumen_name',
      'mission_select_title',
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
