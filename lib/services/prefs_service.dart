import 'package:shared_preferences/shared_preferences.dart';

import '../constants/prefs_keys.dart';

/// ARC-02 / D-02: typed facade over [SharedPreferences] routing ALL 13 keys.
/// Each getter reproduces the EXACT null-fallback default of its original
/// call site in main.dart so behavior is byte-for-byte preserved. Wraps an
/// injected [SharedPreferences] so it is unit-testable with
/// `SharedPreferences.setMockInitialValues`.
class PrefsService {
  PrefsService(this._prefs);

  final SharedPreferences _prefs;

  // --- app_lang (nullable; caller applies defaultLocaleLang fallback) ---
  String? get appLang => _prefs.getString(PrefsKeys.appLang);
  Future<void> setAppLang(String v) => _prefs.setString(PrefsKeys.appLang, v);

  // --- is_dark_mode (default true) ---
  bool get isDarkMode => _prefs.getBool(PrefsKeys.isDarkMode) ?? true;
  Future<void> setDarkMode(bool v) => _prefs.setBool(PrefsKeys.isDarkMode, v);

  // --- ringtone_path (default 'assets/sounds/alarm1.mp3') ---
  String get ringtonePath =>
      _prefs.getString(PrefsKeys.ringtonePath) ?? 'assets/sounds/alarm1.mp3';
  Future<void> setRingtonePath(String v) =>
      _prefs.setString(PrefsKeys.ringtonePath, v);

  // --- alarm_id_counter (default 0) ---
  int get alarmIdCounter => _prefs.getInt(PrefsKeys.alarmIdCounter) ?? 0;
  Future<void> setAlarmIdCounter(int v) =>
      _prefs.setInt(PrefsKeys.alarmIdCounter, v);

  // --- escape_detected (default false) ---
  bool get escapeDetected => _prefs.getBool(PrefsKeys.escapeDetected) ?? false;
  Future<void> setEscapeDetected(bool v) =>
      _prefs.setBool(PrefsKeys.escapeDetected, v);

  // --- is_ringing (default false) ---
  bool get isRinging => _prefs.getBool(PrefsKeys.isRinging) ?? false;
  Future<void> setRinging(bool v) => _prefs.setBool(PrefsKeys.isRinging, v);

  // --- is_ringing_set_at (set-only; nullable getter for completeness) ---
  int? get isRingingSetAt => _prefs.getInt(PrefsKeys.isRingingSetAt);
  Future<void> setRingingSetAt(int v) =>
      _prefs.setInt(PrefsKeys.isRingingSetAt, v);

  // --- snooze_tokens (default 0) ---
  int get snoozeTokens => _prefs.getInt(PrefsKeys.snoozeTokens) ?? 0;
  Future<void> setSnoozeTokens(int v) =>
      _prefs.setInt(PrefsKeys.snoozeTokens, v);

  // --- user_streak (default 0) ---
  int get userStreak => _prefs.getInt(PrefsKeys.userStreak) ?? 0;
  Future<void> setUserStreak(int v) => _prefs.setInt(PrefsKeys.userStreak, v);

  // --- battery_dialog_seen (default false) ---
  bool get batteryDialogSeen =>
      _prefs.getBool(PrefsKeys.batteryDialogSeen) ?? false;
  Future<void> setBatteryDialogSeen(bool v) =>
      _prefs.setBool(PrefsKeys.batteryDialogSeen, v);

  // --- onboarding_seen (default false) ---
  bool get onboardingSeen =>
      _prefs.getBool(PrefsKeys.onboardingSeen) ?? false;
  Future<void> setOnboardingSeen(bool v) =>
      _prefs.setBool(PrefsKeys.onboardingSeen, v);

  // --- alarms_data (nullable) ---
  String? get alarmsData => _prefs.getString(PrefsKeys.alarmsData);
  Future<void> setAlarmsData(String v) =>
      _prefs.setString(PrefsKeys.alarmsData, v);

  // --- target_barcodes (default []) ---
  List<String> get targetBarcodes =>
      _prefs.getStringList(PrefsKeys.targetBarcodes) ?? [];
  Future<void> setTargetBarcodes(List<String> v) =>
      _prefs.setStringList(PrefsKeys.targetBarcodes, v);

  // --- last_scan_date (nullable) ---
  String? get lastScanDate => _prefs.getString(PrefsKeys.lastScanDate);
  Future<void> setLastScanDate(String v) =>
      _prefs.setString(PrefsKeys.lastScanDate, v);
}
