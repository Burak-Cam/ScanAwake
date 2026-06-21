import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/models/enums.dart';
import 'package:no_snooze/models/mission_style.dart';

// UI-presentation characterization for the MissionStyle extension — the single
// source of truth for the per-mission accent color / icon / localized name used
// by the alarm-list row indicator and the modal selector. Pure getters, no
// widget pumping needed.
void main() {
  group('MissionStyle.icon (matches the modal selector icons)', () {
    test('each mission maps to its expected icon', () {
      expect(MissionType.none.icon, Icons.block);
      expect(MissionType.lumen.icon, Icons.wb_sunny);
      expect(MissionType.renk.icon, Icons.palette);
      expect(MissionType.nesne.icon, Icons.category);
      expect(MissionType.su.icon, Icons.water_drop);
    });
  });

  group('MissionStyle.accentColor', () {
    test('each real mission has a distinct accent color', () {
      final colors = {
        MissionType.lumen.accentColor,
        MissionType.renk.accentColor,
        MissionType.nesne.accentColor,
        MissionType.su.accentColor,
      };
      // four missions → four unique colors (no accidental collisions).
      expect(colors.length, 4);
    });

    test('every MissionType returns a non-null color (no unhandled case)', () {
      for (final m in MissionType.values) {
        expect(m.accentColor, isA<Color>());
      }
    });
  });

  group('MissionStyle.displayName (reuses AppStrings keys)', () {
    test('every mission returns a non-empty, defined name for BOTH tr and en', () {
      for (final m in MissionType.values) {
        for (final lang in ['tr', 'en']) {
          final name = m.displayName(lang);
          expect(name.isNotEmpty, isTrue, reason: '$m empty for $lang');
          // AppStrings.get falls back to the bare key when missing — a defined
          // string must differ from any bare key.
          expect(name.startsWith('mission_'), isFalse,
              reason: '$m resolved to a bare key for $lang ($name)');
        }
      }
    });
  });
}
