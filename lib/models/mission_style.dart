import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'enums.dart';

/// UI-only presentation mapping for [MissionType] — the single source of truth
/// for the per-mission accent color, icon, and localized short name shown by the
/// alarm-list row indicator and the add/edit modal's mission selector. Keeping it
/// here (not scattered across widgets) means a new mission needs exactly one entry
/// to light up everywhere. Pure presentation: no behavior, no persistence, no
/// effect on the dismiss funnel.
extension MissionStyle on MissionType {
  /// Per-mission accent color used for the list row icon/label and the active
  /// alarm card border. [none] returns grey as a fallback only — the list keeps
  /// the v1 red active-border for no-mission alarms (no regression), so this is
  /// never used as a border color in practice.
  Color get accentColor => switch (this) {
        MissionType.lumen => Colors.amber,
        MissionType.renk => Colors.purple,
        MissionType.nesne => Colors.teal,
        MissionType.su => Colors.blue,
        MissionType.none => Colors.grey,
      };

  /// Per-mission icon (mirrors the icons already used in the modal selector rows).
  IconData get icon => switch (this) {
        MissionType.lumen => Icons.wb_sunny,
        MissionType.renk => Icons.palette,
        MissionType.nesne => Icons.category,
        MissionType.su => Icons.water_drop,
        MissionType.none => Icons.block,
      };

  /// Localized short name — the same AppStrings keys the modal already uses, so
  /// the list row and the selector never diverge.
  String displayName(String lang) => switch (this) {
        MissionType.lumen => AppStrings.get('mission_lumen_name', lang),
        MissionType.renk => AppStrings.get('mission_color_name', lang),
        MissionType.nesne => AppStrings.get('mission_object_name', lang),
        MissionType.su => AppStrings.get('mission_water_name', lang),
        MissionType.none => AppStrings.get('mission_none', lang),
      };
}
