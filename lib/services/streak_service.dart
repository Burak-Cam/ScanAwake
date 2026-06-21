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
int nextStreak(int current, String? lastScanDate, String today) {
  final last = lastScanDate == null ? null : DateTime.tryParse(lastScanDate);
  final now = DateTime.tryParse(today);
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
  final last = lastScanDate == null ? null : DateTime.tryParse(lastScanDate);
  final now = DateTime.tryParse(today);
  if (last == null || now == null) return false;
  return now.difference(last).inDays <= 2;
}
