/// ARC-02 / D-02: the single source of truth for every SharedPreferences key
/// the app persists. Literals are BYTE-IDENTICAL to the originals scattered
/// across main.dart so existing users' stored data keeps reading unchanged
/// (no data migration). A missed/mistyped key is a silent data/behavior break
/// (Pitfall 6), so all 13 live here and only here.
abstract final class PrefsKeys {
  /// Saved UI language code ('tr' / 'en'). Nullable (falls back to device).
  static const String appLang = 'app_lang';

  /// Dark-mode toggle. Defaults true when unset.
  static const String isDarkMode = 'is_dark_mode';

  /// Selected ringtone asset/file path. Defaults 'assets/sounds/alarm1.mp3'.
  static const String ringtonePath = 'ringtone_path';

  /// FIX-05: monotonic alarm-id counter. Defaults 0.
  static const String alarmIdCounter = 'alarm_id_counter';

  /// FIX-02: app-level escape detected while ringing. Defaults false.
  static const String escapeDetected = 'escape_detected';

  /// Recovery / zombie-alarm guard flag. Defaults false.
  static const String isRinging = 'is_ringing';

  /// D-01b: wall-clock ms when the ringing window started. Set-only.
  static const String isRingingSetAt = 'is_ringing_set_at';

  /// Snooze-token balance. Defaults 0.
  static const String snoozeTokens = 'snooze_tokens';

  /// Fire-streak count. Defaults 0.
  static const String userStreak = 'user_streak';

  /// Whether the battery-optimization warning was shown. Defaults false.
  static const String batteryDialogSeen = 'battery_dialog_seen';

  /// Whether the first-launch onboarding showcase was shown. Defaults false.
  static const String onboardingSeen = 'onboarding_seen';

  /// JSON-encoded list of alarms. Nullable.
  static const String alarmsData = 'alarms_data';

  /// Saved dismissal barcodes (max kMaxBarcodes). Defaults [].
  static const String targetBarcodes = 'target_barcodes';

  /// Last day a streak scan counted (anti-cheat). Nullable.
  static const String lastScanDate = 'last_scan_date';
}
