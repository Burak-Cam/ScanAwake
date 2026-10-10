import 'dart:convert';
import 'dart:io' show Platform;

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_strings.dart';
import '../models/alarm_entity.dart';
import '../models/enums.dart';
import 'prefs_service.dart';

/// The app's existing native channel (MainActivity). The name is shared with
/// the lock-screen / volume / keep-screen-on helpers ON PURPOSE — do not
/// rename it and do not open a second channel; add methods instead.
const MethodChannel _nativeChannel = MethodChannel('com.burakcam.uyan/keyguard');

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

  /// Review 2026-10-10 #3: every alarm in the plugin's own Dart store. An OS
  /// exact-alarm revoke cancels the AlarmManager entries but does NOT delete
  /// these records, so they are the source of truth for what is pending.
  Future<List<AlarmSettings>> storedAlarms() => Alarm.getAlarms();

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
    // HEALTH M-7: `SCHEDULE_EXACT_ALARM` is an Android-only permission. On iOS
    // `Permission.scheduleExactAlarm.status` never reports `granted`, so the
    // fail-safe below would block EVERY schedule on iOS. Short-circuit off
    // Android so scheduling works if an iOS build is ever shipped (Android-first
    // today, but this is a real platform trap).
    if (!Platform.isAndroid) return true;
    try {
      return (await Permission.scheduleExactAlarm.status).isGranted;
    } catch (_) {
      // WR-03: a platform-channel failure must not reject the schedule Future
      // (callers don't catch it). Fail SAFE — treat as not-granted so the UI
      // shows the redirect dialog instead of an optimistic silent set.
      return false;
    }
  }

  /// F-2 (CR-03 follow-up): the RAW exact-alarm app-op state on Android 12
  /// (API 31-32). A battery-exempt app keeps [canScheduleExact] == true even
  /// with the permission switched off; this reports that "explicitly denied"
  /// state so the UI can warn before the exemption disappears and the alarm
  /// drops silently. Best-effort: off Android, outside API 31-32 or on any
  /// error it returns false ("not denied") = exactly today's behavior.
  /// [scheduleAlarmFn] never calls this, so the funnel gate is unchanged.
  Future<bool> exactAlarmOpDenied() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _nativeChannel.invokeMethod<bool>('exactAlarmOpDenied') ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// F-1 (CR-03 follow-up): open this app's "Alarms & reminders" settings page
/// directly (ACTION_REQUEST_SCHEDULE_EXACT_ALARM + package: URI, native).
/// Returns false when it could not (non-Android, pre-Android 12, error) so the
/// caller can fall back to `openAppSettings()`. permission_handler's
/// `Permission.scheduleExactAlarm.request()` is deliberately not used: it
/// skips the request when the status already reads granted — which is the F-2
/// battery-exemption case — and would open nothing.
Future<bool> openExactAlarmSettings() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _nativeChannel.invokeMethod<bool>('openExactAlarmSettings') ??
        false;
  } catch (_) {
    return false;
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

/// F-3 (CR-03 follow-up): set the text of the plugin's "app was killed"
/// warning notification to the app language. The NotificationOnKillService is
/// now declared in the manifest, so the warning actually fires — without this
/// a TR user would get the plugin's English default (TR/EN parity).
/// Best-effort: the kill warning is a hint, not on the alarm-setting path, so
/// any error is swallowed. Plugin limitation: if the service is already
/// running, the new text takes effect on the next `Alarm.set`. NOT called from
/// [scheduleAlarmFn] (funnel and its gateway mocks stay untouched).
Future<void> applyKillWarningText(String lang) async {
  try {
    await Alarm.setWarningNotificationOnKill(
      AppStrings.get('kill_warning_title', lang),
      AppStrings.get('kill_warning_body', lang),
    );
  } catch (_) {
    // Best-effort — never let the kill-warning text break startup.
  }
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
      // HEALTH M-3: rebuild from calendar components instead of adding a fixed
      // 24h Duration. `DateTime.add(Duration(days:1))` adds 24 ABSOLUTE hours,
      // so crossing a DST boundary shifts the wall-clock hour by ±1 (a 07:00
      // alarm fires at 06:00/08:00). Component rebuild preserves the intended
      // hour:minute and normalizes month/day overflow. TR is DST-free; this
      // protects DST-observing (EN) locales.
      return DateTime(target.year, target.month, target.day + 1, time.hour, time.minute);
    }
    return target;
  }

  while (true) {
    if (target.isBefore(now) || !repeatDays.contains(target.weekday)) {
      // HEALTH M-3: component rebuild (see above) so a repeating alarm keeps its
      // exact wall-clock time across DST transitions and never drifts weekdays.
      target = DateTime(target.year, target.month, target.day + 1, time.hour, time.minute);
    } else {
      return target;
    }
  }
}

/// CR-03 follow-up (2026-10-10, Android 12 emulator): what to do about the
/// exact-alarm permission when the app comes to the foreground.
enum ExactAlarmAction { none, warn, warnExempt, rearm }

/// Revoking "Alarms & reminders" makes Android CANCEL every exact alarm this
/// app set (measured: dumpsys alarm went 1 -> 0, reason
/// exact_alarm_permission_revoked) while the app's list still showed the alarm
/// as ACTIVE — a silent no-ring, the worst core-value failure. Re-granting did
/// not restore it until a cold restart. Pure decision so it is unit-pinned:
/// - permission missing + an active alarm -> [ExactAlarmAction.warn]
///   (the user must know their alarm will not ring);
/// - permission back after we saw it missing + an active alarm + nothing
///   ringing -> [ExactAlarmAction.rearm] (re-schedule; never while ringing,
///   because Alarm.set on a ringing id would stop that alarm);
/// - raw permission switched off but still effective + an active alarm +
///   nothing ringing -> [ExactAlarmAction.warnExempt] (see F-2 below);
/// - otherwise nothing.
///
/// F-2 (2026-10-10, Redmi Note 9S / Android 12): an app on the battery
/// optimization allowlist (deviceidle) is EXEMPT from SCHEDULE_EXACT_ALARM.
/// Switching the permission off then cancels nothing and
/// canScheduleExactAlarms() keeps returning true (dumpsys alarm:
/// exactAllowReason=allow-listed). If the exemption is later removed (by the
/// user or the OS), the pending alarm cannot start its foreground service and
/// drops SILENTLY (device evidence: ForegroundServiceStartNotAllowedException).
/// [rawDenied] = the raw app-op is explicitly denied. Re-arming wins over the
/// exempt warning (the warning surfaces on the next foreground check).
/// [rawDenied] defaults to false, which is exactly the pre-F-2 behavior.
///
/// Review 2026-10-10 #2: [ringing] means "a ring flow is active" — the plugin
/// is ringing OR RingScreen is up (Stage 1 or the Stage-2 mission, where
/// `Alarm.isRinging()` is already false) OR the dismiss tail is still running.
/// NOTHING is done then, not even the warning: (a) a dialog on top of
/// RingScreen swallows RingScreen's own `Navigator.pop`, (b) "Open Settings"
/// backgrounds the app while the escape watch is live (a false cheat verdict),
/// (c) `Alarm.set` on the ringing id would stop that alarm. The caller re-runs
/// the check once the flow ends.
ExactAlarmAction decideExactAlarmAction({
  required bool granted,
  required bool wasDenied,
  required bool hasActive,
  required bool ringing,
  bool rawDenied = false,
}) {
  if (!hasActive) return ExactAlarmAction.none;
  if (ringing) return ExactAlarmAction.none;
  if (!granted) return ExactAlarmAction.warn;
  if (wasDenied) return ExactAlarmAction.rearm;
  if (rawDenied) return ExactAlarmAction.warnExempt;
  return ExactAlarmAction.none;
}

/// Review 2026-10-10 #3: the transient alarms (snooze / restart re-fires —
/// ids that are not entity ids) a permission revoke cancelled and a re-grant
/// must restore. Entities are excluded: they are re-scheduled through the
/// funnel with a freshly computed date. Past alarms are excluded too — that
/// includes the one ringing right now (its dateTime is in the past), and
/// `Alarm.set` on it would stop it. [minLead] keeps the restart re-fire
/// (now+100 ms) out: the plugin arms such short delays with a Handler, not
/// AlarmManager, so the revoke never cancelled it and re-setting it would
/// ring twice.
List<AlarmSettings> transientAlarmsToRestore(
  Iterable<AlarmSettings> stored, {
  required Set<int> entityIds,
  required DateTime now,
  Duration minLead = const Duration(seconds: 2),
}) {
  final earliest = now.add(minLead);
  return stored
      .where((a) => !entityIds.contains(a.id) && a.dateTime.isAfter(earliest))
      .toList();
}

/// Review 2026-10-10 #3: re-set the pending transient alarms verbatim (same
/// id + payload, so the snooze kind and the mission survive). Not routed
/// through [scheduleAlarmFn] because the settings already exist; the gateway
/// is still the only thing touching `Alarm.set`, and the same exact-alarm
/// gate applies first. Returns false (nothing read, nothing set) when the
/// permission is still missing.
Future<bool> restoreTransientAlarms({
  required Set<int> entityIds,
  AlarmGateway gateway = defaultAlarmGateway,
  DateTime? now,
}) async {
  if (!await gateway.canScheduleExact()) return false;
  final pending = transientAlarmsToRestore(
    await gateway.storedAlarms(),
    entityIds: entityIds,
    now: now ?? DateTime.now(),
  );
  for (final s in pending) {
    await gateway.set(s);
  }
  return true;
}
