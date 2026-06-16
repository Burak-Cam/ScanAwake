import 'dart:convert';
import 'package:flutter/material.dart' show TimeOfDay;

import 'enums.dart';

/// Type of alarm that fired. Carried via [AlarmSettings.payload] (D-03/FIX-04).
/// Legacy alarms with no payload default to [AlarmKind.real] (Pitfall 2).
enum AlarmKind { real, test, snooze }

/// FIX-03 / D-05: per-entry resilient parse of the persisted `alarms_data`
/// JSON. A single corrupt record skips ONLY itself; valid records are kept.
/// Returns the recovered alarms plus the number of skipped (corrupt) records.
///
/// Never throws for malformed top-level input: null, empty, non-JSON, or a
/// JSON value that is not a list all yield `([], 0)`.
(List<AlarmEntity>, int) parseAlarmsResilient(String? alarmsJson) {
  if (alarmsJson == null || alarmsJson.trim().isEmpty) return (<AlarmEntity>[], 0);

  dynamic decoded;
  try {
    decoded = jsonDecode(alarmsJson);
  } catch (_) {
    // Whole string is not valid JSON — recover nothing, but do not crash.
    return (<AlarmEntity>[], 0);
  }

  if (decoded is! List) return (<AlarmEntity>[], 0);

  final List<AlarmEntity> parsed = [];
  int skipped = 0;
  for (final e in decoded) {
    try {
      parsed.add(AlarmEntity.fromJson(e as Map<String, dynamic>));
    } catch (_) {
      skipped++; // skip only this corrupt entry (D-05 per-entry)
    }
  }
  return (parsed, skipped);
}

class AlarmEntity {
  final int id;
  TimeOfDay time;
  bool isActive;
  List<int> repeatDays;
  String label;

  /// ENG-03 / MIS-01: the dismissal mission for this alarm. Defaults to
  /// [MissionType.none] (legacy alarms predate the field — D-11). Persisted to
  /// `alarms_data` and carried into [AlarmSettings.payload] by [scheduleAlarmFn].
  MissionType missionType;

  AlarmEntity({
    required this.id,
    required this.time,
    this.isActive = true,
    this.repeatDays = const [],
    this.label = '',
    this.missionType = MissionType.none,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': time.hour,
    'minute': time.minute,
    'isActive': isActive,
    'repeatDays': repeatDays,
    'label': label,
    'missionType': missionType.name,
  };

  factory AlarmEntity.fromJson(Map<String, dynamic> json) {
    // FIX-03 / D-05: validate field types instead of blind casts so corrupt
    // records throw a clean [FormatException] (caught per-entry upstream)
    // rather than a NoSuchMethodError / opaque type error.
    final id = json['id'];
    final hour = json['hour'];
    final minute = json['minute'];
    final isActive = json['isActive'];

    if (id is! int) {
      throw FormatException("AlarmEntity.fromJson: 'id' must be int, got ${id.runtimeType}");
    }
    if (hour is! int || hour < 0 || hour > 23) {
      throw FormatException("AlarmEntity.fromJson: invalid 'hour': $hour");
    }
    if (minute is! int || minute < 0 || minute > 59) {
      throw FormatException("AlarmEntity.fromJson: invalid 'minute': $minute");
    }
    if (isActive is! bool) {
      throw FormatException("AlarmEntity.fromJson: 'isActive' must be bool, got ${isActive.runtimeType}");
    }

    final rawDays = json['repeatDays'];
    List<int> repeatDays;
    if (rawDays == null) {
      repeatDays = const [];
    } else if (rawDays is List && rawDays.every((d) => d is int)) {
      repeatDays = rawDays.cast<int>();
    } else {
      throw FormatException("AlarmEntity.fromJson: 'repeatDays' must be List<int>, got ${rawDays.runtimeType}");
    }

    final rawLabel = json['label'];
    final label = rawLabel == null ? '' : rawLabel.toString();

    // D-11 / Pitfall 5: missing field OR unknown/future value => safe `none`,
    // NEVER throw (dismiss must never crash). `asNameMap()[x] ?? none`, not
    // `byName` (byName throws on unknown). An unknown missionType is NOT
    // corruption — the record stays valid (parseAlarmsResilient keeps it).
    final rawMission = json['missionType'];
    final missionType = (rawMission is String)
        ? (MissionType.values.asNameMap()[rawMission] ?? MissionType.none)
        : MissionType.none;

    return AlarmEntity(
      id: id,
      time: TimeOfDay(hour: hour, minute: minute),
      isActive: isActive,
      repeatDays: repeatDays,
      label: label,
      missionType: missionType,
    );
  }
}
