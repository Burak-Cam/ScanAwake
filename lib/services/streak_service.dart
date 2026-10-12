import '../models/alarm_entity.dart';

/// Anti-cheat / streak pure logic (TST-01). Relocated verbatim from `main.dart`
/// so it has a real service-layer destination before 02-04 rewrites the test
/// imports. Kept PURE — no SharedPreferences, no BuildContext — so
/// cheat_logic_test / streak_logic_test stay valid unit oracles.

/// Anti-cheat decision outcome on cold start (D-01/FIX-02).
enum CheatVerdict { reset, preserve, none }

/// FIX-02 / D-01: decide whether a leftover ringing flag means the user
/// genuinely escaped (reset streak) or the app was OEM-killed/crashed/rebooted
/// (preserve streak). If the app was not ringing, there is nothing to judge.
///
/// - !wasRinging                  => [CheatVerdict.none]
/// - wasRinging && escapeDetected => [CheatVerdict.reset]
/// - wasRinging && !escapeDetected => [CheatVerdict.preserve]
CheatVerdict decideCheat(
    {required bool wasRinging, required bool escapeDetected}) {
  if (!wasRinging) return CheatVerdict.none;
  return escapeDetected ? CheatVerdict.reset : CheatVerdict.preserve;
}

/// FIX-04 / D-02/D-03/D-04: a day counts toward the streak only when a REAL
/// wake alarm is dismissed and the day has not already been counted. Test and
/// snooze alarms never count; a second scan the same day is neutral.
bool streakEligible(AlarmKind kind, String? lastScanDate, String today) =>
    kind == AlarmKind.real && lastScanDate != today;

/// STREAK-GRACE: real-streak with a 1-day cushion. Given the [current] streak,
/// the [lastScanDate] a streak day was last counted, and [today] (both
/// 'yyyy-mm-dd'), return the streak AFTER a genuine wake today. The 1-day grace
/// forgives a SINGLE skipped day but breaks on two:
///
/// - never counted / unparseable        => 1   (today starts a fresh streak)
/// - same day (gap <= 0)                => unchanged (caller also gates this via
///                                         [streakEligible]; defensive here)
/// - gap of 1 or 2 days (<=1 missed day) => current + 1 (continues — the grace
///                                         day covers a single miss)
/// - gap of 3+ days (>=2 missed days)    => 1   (broken; today restarts it)
///
/// Worked example (user spec): wake Mon then Wed (gap 2, Tue missed) => continues;
/// wake Sun then Wed (gap 3, Mon+Tue missed) => resets to 1.
/// Parse a 'yyyy-mm-dd' date-only string to a UTC-midnight [DateTime] so day-gap
/// math is DST-immune. A local-midnight diff across a DST boundary measures 23h
/// or 25h and `.inDays` then truncates → off-by-one streak bugs (HEALTH M-4):
/// a real consecutive-day wake could measure gap 0 (streak fails to advance) or
/// a real 3-day break could measure inDays 2 (broken streak silently continues).
DateTime? _utcDay(String? s) {
  if (s == null) return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

int nextStreak(int current, String? lastScanDate, String today) {
  final last = _utcDay(lastScanDate);
  final now = _utcDay(today);
  if (last == null || now == null) return 1;
  final gap = now.difference(last).inDays;
  if (gap <= 0) return current;
  if (gap <= 2) return current + 1;
  return 1;
}

/// STREAK-GRACE display side of [nextStreak]: true if a streak last advanced on
/// [lastScanDate] is still alive as of [today] — i.e. a wake today could still
/// extend it. Dead once 2+ days are missed (gap >= 3), so the home screen shows
/// 0 even before the next wake (a real streak decays on inactivity). Mirrors
/// [nextStreak]'s gap thresholds. Note: this only resets the STREAK; snooze
/// tokens are kept on a natural lapse — only a genuine cheat ([decideCheat]
/// reset) wipes tokens (max deterrence).
bool streakAlive(String? lastScanDate, String today) {
  final last = _utcDay(lastScanDate);
  final now = _utcDay(today);
  if (last == null || now == null) return false;
  return now.difference(last).inDays <= 2;
}

/// STREAK-SAVE: snooze-token cost to rescue a broken streak (spend tokens
/// instead of letting it reset to 0). Only offered on an inactivity break, never
/// after a cheat reset (a cheat already wipes tokens to 0).
const int kStreakSaveCost = 2;

/// True if the user has enough snooze tokens to rescue a broken streak.
bool canSaveStreak(int tokens) => tokens >= kStreakSaveCost;

/// DECISION (review 2026-10-10): does an EMERGENCY STOP break the streak?
///
/// The emergency stop was the cheapest way to skip the whole point of the app:
/// wait it out, tap, alarm gone — no barcode, no penalty. Worse, with the 1-day
/// grace in [nextStreak] an emergency every other morning kept a streak alive
/// FOREVER. So an emergency that skips the barcode on a real wake (or its
/// snooze re-fire) now resets the streak.
///
/// Deliberately NOT penalised:
/// - [AlarmKind.test]: a test ring is never a wake-up.
/// - [barcodeScanned]: the user already got up and scanned — the core value is
///   met. Emergency in Stage 2 is the escape hatch for a mission that cannot be
///   completed (dead camera/mic, a hard water mission), so it stays penalty-free
///   (it still awards no streak day).
///
/// Snooze tokens are untouched — only a genuine cheat ([decideCheat]) wipes them.
bool emergencyBreaksStreak(AlarmKind kind, {required bool barcodeScanned}) =>
    kind != AlarmKind.test && !barcodeScanned;

/// What an emergency-stop press should do (see [decideEmergencyStop]).
enum EmergencyStep { abort, stop, stopBreakStreak }

/// Review 2026-10-10 #5: the emergency-stop decision, pure so it can be
/// re-evaluated. RingScreen calls it BEFORE its awaits and AGAIN after them
/// with the current state — a barcode scanned while the handler was suspended
/// must neither reset the streak nor steal the exit.
///
/// [EmergencyStep.abort] (checkup-260711 WR-01):
/// - [exited]: another exit already popped — nothing left to stop (a second
///   pop would remove HomeScreen underneath).
/// - [missionDone]: the mission-success chain is running; the alarm is
///   already stopped and racing it would demote a success into an emergency.
/// - [scanned] without a mission: the barcode scan succeeded and the success
///   tail is in its 2 s delay — that success owns the exit. On the mission
///   path [scanned] stays true for the whole Stage 2, so emergency remains
///   reachable during a mission (D-13).
///
/// Otherwise stop, breaking the streak per [emergencyBreaksStreak].
/// [hasMission] is a bool (not MissionType) to keep this file free of extra
/// imports.
EmergencyStep decideEmergencyStop({
  required bool exited,
  required bool missionDone,
  required bool scanned,
  required bool hasMission,
  required AlarmKind kind,
}) {
  if (exited || missionDone) return EmergencyStep.abort;
  if (scanned && !hasMission) return EmergencyStep.abort;
  return emergencyBreaksStreak(kind, barcodeScanned: scanned)
      ? EmergencyStep.stopBreakStreak
      : EmergencyStep.stop;
}
