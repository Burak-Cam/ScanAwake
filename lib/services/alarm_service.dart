import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_strings.dart';
import '../models/alarm_entity.dart';
import '../models/enums.dart';
import 'prefs_service.dart';

/// TST-02 / RESEARCH A2: a thin injectable seam over the static `Alarm` API.
/// This is the ONLY place that touches `Alarm.set` / `Alarm.stop`, so the
/// reschedule/date logic in [scheduleAlarmFn] becomes unit-testable: tests pass
/// a `MockAlarmGateway` and assert `verify(() => gateway.set(...)).called(1)`.
/// The production default delegates verbatim to the static API (behavior
/// preserved).
class AlarmGateway {
  const AlarmGateway();

  Future<void> set(AlarmSettings alarmSettings) =>
      Alarm.set(alarmSettings: alarmSettings);

  Future<void> stop(int id) => Alarm.stop(id);

  /// RLS-04 / D-03: injectable exact-alarm permission seam. Returns whether the
  /// OS currently grants `SCHEDULE_EXACT_ALARM` (Android 14 default-DENIED; can
  /// be revoked any time). The funnel ([scheduleAlarmFn]) consults this BEFORE
  /// every `set`, so the gate decision is centralized and platform-channel-free
  /// in tests: `MockAlarmGateway extends Mock implements AlarmGateway` lets a
  /// test stub `when(() => gateway.canScheduleExact()).thenAnswer(...)` with no
  /// package/platform-channel mocking.
  ///
  /// Pitfall 2 (RESEARCH): on MIUI / Android 12 this status may report a
  /// FALSE-POSITIVE (granted when it is not). In the worst case the gate behaves
  /// as if no check existed (i.e. exactly the prior behavior) — NOT a
  /// regression. Real-device confirmation happens at the Task 3 checkpoint.
  Future<bool> canScheduleExact() async {
    try {
      return (await Permission.scheduleExactAlarm.status).isGranted;
    } catch (_) {
      // WR-03: a platform-channel failure must not reject the schedule Future
      // (callers don't catch it). Fail SAFE — treat as not-granted so the UI
      // shows the redirect dialog instead of an optimistic silent set.
      return false;
    }
  }
}

/// Default production gateway. Reused so every non-test call site keeps the
/// exact prior behavior without allocating a fresh instance.
const AlarmGateway defaultAlarmGateway = AlarmGateway();

/// The single funnel for ALL alarm scheduling (re-arm correctness underpins
/// FIX-01). Builds the [AlarmSettings] (payload jsonEncode {'kind': ...},
/// looping audio, fade volume, full-screen intent) and routes through the
/// injectable [gateway] so reschedule date math is unit-testable. Behavior is
/// byte-for-byte preserved from the prior in-`main.dart` implementation.
///
/// FIX-04 / D-03: the alarm TYPE is carried out-of-band via the payload so the
/// RingScreen can gate the streak (real vs test vs snooze). Legacy alarms with
/// a null payload decode to [AlarmKind.real] (Pitfall 2).
///
/// RLS-04 / D-03 (funnel-içi exact-alarm gate): BEFORE every `gateway.set`, this
/// funnel checks `gateway.canScheduleExact()`. If the exact-alarm permission is
/// NOT granted, `gateway.set` is NOT called and the function returns `false`;
/// otherwise it sets the alarm and returns `true`. Because this is the SOLE
/// funnel for `Alarm.set`, all 6 call paths (_rearmIfRepeating, restart re-fire,
/// snooze re-arm, test, add, toggle) are covered automatically — a silent
/// inexact set (missed wake-up) becomes impossible. NO BuildContext is added
/// here (Pitfall 4): the funnel only returns a bool signal; the redirect dialog
/// lives in the UI layer (home_screen).
Future<bool> scheduleAlarmFn(
  int id,
  DateTime dateTime,
  bool vibrate,
  String lang,
  String audioPath,
  String label,
  AlarmKind alarmType, {
  MissionType missionType = MissionType.none,
  AlarmGateway gateway = defaultAlarmGateway,
}) async {
  // RLS-04 / D-03: set-öncesi gate. Permission revoked => do NOT set, signal false.
  if (!await gateway.canScheduleExact()) return false;
  final alarmSettings = AlarmSettings(
    id: id,
    dateTime: dateTime,
    assetAudioPath: audioPath,
    loopAudio: true,
    vibrate: vibrate,
    // ENG-03 / MIS-01: mission rides the SAME payload map as kind, so the ring
    // listener can pick the dismissal mission at fire time (D-11 default none).
    payload: jsonEncode({'kind': alarmType.name, 'mission': missionType.name}),
    volumeSettings: VolumeSettings.fade(
      volume: 1.0,
      fadeDuration: const Duration(seconds: 3),
      volumeEnforced: true,
    ),
    notificationSettings: NotificationSettings(
      title: label.isEmpty ? 'ScanAwake' : label,
      body: AppStrings.get('notification_body', lang),
      stopButton: null,
      icon: 'notification_icon',
    ),
    warningNotificationOnKill: true,
    androidFullScreenIntent: true,
  );
  await gateway.set(alarmSettings);
  return true;
}

/// FIX (checkup-260711 WR-03): the pure, unit-testable decode of a fired
/// alarm's payload — extracted VERBATIM from home_screen's ring-listener
/// inline block so the restart re-fire can carry the decoded kind (and so the
/// semantics are pinned by fired_payload_decode_test.dart).
///
/// Back-compat / defensive semantics (the dismiss path must NEVER crash —
/// core value):
/// - null/empty payload (a legacy alarm scheduled before payloads existed)
///   => defaults ([AlarmKind.real], [MissionType.none]).
/// - kind decodes via `AlarmKind.values.byName`, which THROWS on an unknown
///   name — the catch then resets BOTH values to the defaults (Pitfall 2).
/// - mission decodes via `asNameMap()[x] ?? none` (NOT byName — Pitfall 5):
///   an unknown/typo/future mission name (e.g. from a newer build) falls to
///   none and never throws.
/// - non-string values are ignored (`is String` checks), keeping defaults.
({AlarmKind kind, MissionType mission}) decodeFiredPayload(String? rawPayload) {
  AlarmKind kind = AlarmKind.real;
  MissionType mission = MissionType.none;
  if (rawPayload != null && rawPayload.isNotEmpty) {
    try {
      final decodedPayload = jsonDecode(rawPayload);
      if (decodedPayload is Map && decodedPayload['kind'] is String) {
        kind = AlarmKind.values.byName(decodedPayload['kind'] as String);
      }
      if (decodedPayload is Map && decodedPayload['mission'] is String) {
        mission = MissionType.values
                .asNameMap()[decodedPayload['mission'] as String] ??
            MissionType.none;
      }
    } catch (_) {
      // Corrupt/unknown payload => safe defaults. Never crash on dismiss.
      kind = AlarmKind.real;
      mission = MissionType.none;
    }
  }
  return (kind: kind, mission: mission);
}

/// FIX-05: monotonic id step. Pure helper backing the SharedPreferences
/// `alarm_id_counter` so unit tests can assert it never collides.
int incrementId(int prior) => prior + 1;

/// FIX-05 (RESEARCH Q1): mint the next unique alarm id from the persisted
/// monotonic counter `alarm_id_counter`. Used for ALL ids — entity, snooze and
/// test alarms — so two alarms minted in the same millisecond never collide
/// (the old `% N` of millisecondsSinceEpoch could). Persists before returning.
Future<int> nextAlarmId(PrefsService prefs) async {
  final next = incrementId(prefs.alarmIdCounter);
  await prefs.setAlarmIdCounter(next);
  return next;
}

/// Next occurrence for an alarm. Top-level so `date_calc_test.dart` /
/// `alarm_service_test.dart` can characterize FIX-01 behavior. Behavior is
/// preserved EXACTLY from the prior implementation.
DateTime calculateAlarmDateTime(TimeOfDay time, List<int> repeatDays) {
  DateTime now = DateTime.now();
  DateTime target =
      DateTime(now.year, now.month, now.day, time.hour, time.minute);

  if (repeatDays.isEmpty) {
    if (target.isBefore(now)) {
      return target.add(const Duration(days: 1));
    }
    return target;
  }

  while (true) {
    if (target.isBefore(now) || !repeatDays.contains(target.weekday)) {
      target = target.add(const Duration(days: 1));
    } else {
      return target;
    }
  }
}
