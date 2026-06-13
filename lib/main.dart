import 'dart:async';
import 'dart:convert';
import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart'; 
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fgbg/flutter_fgbg.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(const NoSnoozeApp());
}

class NoSnoozeApp extends StatefulWidget {
  const NoSnoozeApp({super.key});

  @override
  State<NoSnoozeApp> createState() => _NoSnoozeAppState();
}

class _NoSnoozeAppState extends State<NoSnoozeApp> {
  // UX-02 / D-09: device-aware default (EN device => en, otherwise => tr),
  // resolved at construction and overridden by a saved app_lang in
  // _loadPreferences. No longer a hard English default.
  Locale _locale = Locale(defaultLocaleLang(
      PlatformDispatcher.instance.locale.languageCode));
  ThemeMode _themeMode = ThemeMode.dark;
  String _currentRingtone = 'assets/sounds/alarm1.mp3'; 

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      String? savedLang = prefs.getString('app_lang');
      // UX-02 / D-09: saved preference wins; otherwise fall back to the
      // device-aware default instead of a hard English default.
      _locale = Locale(savedLang ??
          defaultLocaleLang(PlatformDispatcher.instance.locale.languageCode));
      
      bool isDark = prefs.getBool('is_dark_mode') ?? true;
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;

      _currentRingtone = prefs.getString('ringtone_path') ?? 'assets/sounds/alarm1.mp3';
    });
  }

  void setLanguage(String langCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_lang', langCode);
    setState(() => _locale = Locale(langCode));
  }

  void toggleTheme(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', isDark);
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
  }

  void setRingtone(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ringtone_path', path);
    setState(() => _currentRingtone = path);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NoSnooze',
      locale: _locale, 
      supportedLocales: const [Locale('en'), Locale('tr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: _themeMode,
      theme: ThemeData.light().copyWith(
        primaryColor: Colors.red,
        scaffoldBackgroundColor: Colors.grey[100],
        colorScheme: const ColorScheme.light(
          primary: Colors.red,
          secondary: Colors.redAccent,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black, 
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData.dark().copyWith(
        primaryColor: Colors.red,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.red,
          secondary: Colors.redAccent,
          surface: Colors.black,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: HomeScreen(
        onLanguageChanged: setLanguage,
        onThemeChanged: toggleTheme,
        onRingtoneChanged: setRingtone,
        currentThemeMode: _themeMode,
        currentRingtone: _currentRingtone,
      ),
    );
  }
}

Future<void> scheduleAlarmFn(int id, DateTime dateTime, bool vibrate, String lang, String audioPath, String label) async {
  final alarmSettings = AlarmSettings(
    id: id,
    dateTime: dateTime,
    assetAudioPath: audioPath, 
    loopAudio: true,
    vibrate: vibrate,
    volumeSettings: VolumeSettings.fade(
      volume: 1.0,
      fadeDuration: const Duration(seconds: 3),
      volumeEnforced: true,
    ),
    notificationSettings: NotificationSettings(
      title: label.isEmpty ? 'NoSnooze' : label, 
      body: AppStrings.get('notification_body', lang),
      stopButton: null,
      icon: 'notification_icon',
    ),
    warningNotificationOnKill: true, 
    androidFullScreenIntent: true,
  );
  await Alarm.set(alarmSettings: alarmSettings);
}

// ---------------------------------------------------------------------------
// Top-level pure functions + enums (Phase 1 testability seam).
// These are the in-file extraction of bug-bearing decision logic so that
// characterization tests can exercise them without a device. They are NOT a
// modularization (no new files / module boundaries — that is Phase 2 / ARC-01).
// State methods are wired to these in Plan 02/03; this plan only defines them.
// ---------------------------------------------------------------------------

/// Type of alarm that fired. Carried via [AlarmSettings.payload] (D-03/FIX-04).
/// Legacy alarms with no payload default to [AlarmKind.real] (Pitfall 2).
enum AlarmKind { real, test, snooze }

/// Anti-cheat decision outcome on cold start (D-01/FIX-02).
enum CheatVerdict { reset, preserve, none }

/// FIX-02 / D-01: decide whether a leftover ringing flag means the user
/// genuinely escaped (reset streak) or the app was OEM-killed/crashed/rebooted
/// (preserve streak). If the app was not ringing, there is nothing to judge.
///
/// - !wasRinging                  => [CheatVerdict.none]
/// - wasRinging && escapeDetected => [CheatVerdict.reset]
/// - wasRinging && !escapeDetected => [CheatVerdict.preserve]
CheatVerdict decideCheat({required bool wasRinging, required bool escapeDetected}) {
  if (!wasRinging) return CheatVerdict.none;
  return escapeDetected ? CheatVerdict.reset : CheatVerdict.preserve;
}

/// FIX-04 / D-02/D-03/D-04: a day counts toward the streak only when a REAL
/// wake alarm is dismissed and the day has not already been counted. Test and
/// snooze alarms never count; a second scan the same day is neutral.
bool streakEligible(AlarmKind kind, String? lastScanDate, String today) =>
    kind == AlarmKind.real && lastScanDate != today;

/// FIX-05: monotonic id step. Pure helper backing the SharedPreferences
/// `alarm_id_counter` so unit tests can assert it never collides.
int incrementId(int prior) => prior + 1;

/// FIX-05 (RESEARCH Q1): mint the next unique alarm id from the persisted
/// monotonic counter `alarm_id_counter`. Used for ALL ids — entity, snooze and
/// test alarms — so two alarms minted in the same millisecond never collide
/// (the old `% N` of millisecondsSinceEpoch could). Persists before returning.
Future<int> nextAlarmId(SharedPreferences prefs) async {
  final next = incrementId(prefs.getInt('alarm_id_counter') ?? 0);
  await prefs.setInt('alarm_id_counter', next);
  return next;
}

/// UX-02 / D-09: default UI language when no `app_lang` is saved. English
/// device locale => 'en'; every other locale (incl. TR and other languages)
/// => 'tr'. Accepts either a bare language code ('en') or a full locale
/// string ('en_US') — only the language prefix matters (RESEARCH Q3).
String defaultLocaleLang(String deviceLocale) =>
    deviceLocale.toLowerCase().startsWith('en') ? 'en' : 'tr';

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

/// Next occurrence for an alarm. Top-level so `date_calc_test.dart` can
/// characterize FIX-01 behavior. Behavior is preserved EXACTLY from the prior
/// in-State implementation — this plan only makes it reachable.
DateTime calculateAlarmDateTime(TimeOfDay time, List<int> repeatDays) {
  DateTime now = DateTime.now();
  DateTime target = DateTime(now.year, now.month, now.day, time.hour, time.minute);

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

class HomeScreen extends StatefulWidget {
  final Function(String) onLanguageChanged;
  final Function(bool) onThemeChanged;
  final Function(String) onRingtoneChanged;
  final ThemeMode currentThemeMode;
  final String currentRingtone;

  const HomeScreen({
    super.key, 
    required this.onLanguageChanged,
    required this.onThemeChanged,
    required this.onRingtoneChanged,
    required this.currentThemeMode,
    required this.currentRingtone,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<AlarmEntity> alarms = [];
  List<String> savedBarcodes = [];
  
  final List<String> defaultRingtones = [
    'alarm1.mp3', 'alarm2.mp3', 'alarm3.mp3', 'alarm4.mp3', 
    'alarm5.mp3', 'alarm6.mp3', 'alarm7.mp3', 'alarm8.mp3', 
    'alarm9.mp3'
  ];
  
  List<String> get dayNames => currentLang == 'tr' 
    ? ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar']
    : ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];


  String get currentLang => Localizations.localeOf(context).languageCode;
  
  int streakCount = 0;
  int snoozeTokens = 0;
  StreamSubscription? alarmSubscription;
  // FIX-02 / D-01a: app-level foreground/background detection while an alarm is
  // ringing. A genuine FGBGType.background event = real escape (sets
  // escape_detected). flutter_fgbg is already a transitive dep (no new package).
  StreamSubscription<FGBGType>? _fgbgSubscription;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _checkCheatStatus();
    _initializeRest();
  }

  Future<void> _initializeRest() async {
    await _loadPreferences();
    await _checkPermissions();
    _startAlarmListener();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _checkBatteryOptimization();
    });
  }

  @override
  void dispose() {
    alarmSubscription?.cancel();
    _fgbgSubscription?.cancel();
    super.dispose();
  }

  // FIX-02 / D-01a: begin watching for a real app-level escape while ringing.
  // Mirrors the alarmSubscription subscribe/cancel shape (:316 / dispose).
  Future<void> _startEscapeWatch() async {
    await _fgbgSubscription?.cancel();
    _fgbgSubscription = FGBGEvents.instance.stream.listen((event) async {
      if (event == FGBGType.background) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('escape_detected', true);
      }
    });
  }

  // Stop watching once the alarm is dismissed (any path).
  Future<void> _stopEscapeWatch() async {
    await _fgbgSubscription?.cancel();
    _fgbgSubscription = null;
  }

  void _startAlarmListener() {
    // ignore: deprecated_member_use
    alarmSubscription = Alarm.ringStream.stream.listen((alarmSettings) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_ringing', true);
      // D-01b: record the wall-clock start of the ringing window (boot-guard
      // record; escape_detected is the primary discriminator). Fresh ring =>
      // no prior escape yet.
      await prefs.setInt('is_ringing_set_at', DateTime.now().millisecondsSinceEpoch);
      await prefs.setBool('escape_detected', false);
      // Begin app-level escape detection while ringing (FIX-02 / D-01a).
      await _startEscapeWatch();

      final index = alarms.indexWhere((element) => element.id == alarmSettings.id);
      
      if (index != -1) {
        if (alarms[index].repeatDays.isEmpty) {
           if (mounted) setState(() => alarms[index].isActive = false);
        }
        _saveAlarms(); 
      }

      if (!mounted) return;

      if (savedBarcodes.isNotEmpty) {
        // Pitfall 1: the camera-permission dialog backgrounds the app. Request
        // it inside FGBGEvents.ignoreWhile so it does NOT register as a real
        // escape (only genuine FGBGType.background during scanning should).
        await FGBGEvents.ignoreWhile(() async {
          await Permission.camera.request();
        });

        if (!mounted) return;

        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RingScreen(
              targetBarcodes: savedBarcodes,
              startWithoutVibration: !alarmSettings.vibrate,
              language: currentLang,
              alarmId: alarmSettings.id,
              availableTokens: snoozeTokens,
              label: index != -1 ? alarms[index].label : '',
            ),
          ),
        );

        if (!mounted) return;

        if (result == 'RESTART') {
           await Alarm.stop(alarmSettings.id);
           await Future.delayed(const Duration(milliseconds: 500));
           await scheduleAlarmFn(alarmSettings.id, DateTime.now().add(const Duration(milliseconds: 100)), false, currentLang, widget.currentRingtone, index != -1 ? alarms[index].label : '');
        } 
        else if (result == 'SNOOZE') {
           await prefs.setBool('is_ringing', false);
           await Alarm.stop(alarmSettings.id);
           
           int newTokens = snoozeTokens - 1;
           if (newTokens < 0) newTokens = 0;
           await prefs.setInt('snooze_tokens', newTokens);
           
           await scheduleAlarmFn(
             await nextAlarmId(prefs),
             DateTime.now().add(const Duration(minutes: 5)),
             true,
             currentLang,
             widget.currentRingtone,
             "Snoozed"
           );
           
           setState(() => snoozeTokens = newTokens);
           _showSnack(AppStrings.get('snooze_used', currentLang));
        }
        else if (result == 'SUCCESS') {
           await prefs.setBool('is_ringing', false);
           
           if (index != -1 && alarms[index].repeatDays.isNotEmpty) {
               final nextTime = _calculateAlarmDateTime(alarms[index].time, alarms[index].repeatDays);
               await scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label);
           }
           
           _loadPreferences();
        }

        // Ring window is over (any dismiss path): stop watching for escapes and
        // clear the transient flag so a clean dismiss leaves no stale signal.
        await _stopEscapeWatch();
        await prefs.setBool('escape_detected', false);
      }
    });
  }

  Future<void> _checkCheatStatus() async {
    final prefs = await SharedPreferences.getInstance();
    // FIX-02 / D-01: decide via the pure fn instead of unconditionally resetting.
    bool wasRinging = prefs.getBool('is_ringing') ?? false;
    bool escapeDetected = prefs.getBool('escape_detected') ?? false;
    final verdict = decideCheat(wasRinging: wasRinging, escapeDetected: escapeDetected);

    switch (verdict) {
      case CheatVerdict.none:
        // App was not ringing — nothing to judge, streak preserved.
        return;

      case CheatVerdict.preserve:
        // OEM-kill / crash / reboot assumption (D-01): the user did NOT
        // genuinely escape, so streak/tokens are KEPT. Only clear the leftover
        // ringing flags; no reset dialog. (flag-clear analog :1255/:1278.)
        await prefs.setBool('is_ringing', false);
        await prefs.setBool('escape_detected', false);
        return;

      case CheatVerdict.reset:
        // Genuine FGBG escape while ringing => reset (original behavior).
        await prefs.setBool('is_ringing', false);
        await prefs.setBool('escape_detected', false);
        await prefs.setInt('user_streak', 0);
        await prefs.setInt('snooze_tokens', 0);

        if (!mounted) return;
        setState(() {
          streakCount = 0;
          snoozeTokens = 0;
        });

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.red[900],
            title: Text(AppStrings.get('cheat_title', currentLang), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(AppStrings.get('cheat_msg', currentLang), style: const TextStyle(color: Colors.white)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))
            ],
          ),
        );
    }
  }

  Future<void> _checkBatteryOptimization() async {
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    final prefs = await SharedPreferences.getInstance();
    bool hasSeenWarning = prefs.getBool('battery_dialog_seen') ?? false;
    if (hasSeenWarning) return;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.get('battery_title', currentLang)),
        content: Text(AppStrings.get('battery_desc', currentLang)),
        actions: [
          TextButton(onPressed: () async { await prefs.setBool('battery_dialog_seen', true); if (context.mounted) Navigator.pop(context); }, child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.grey))),
          TextButton(onPressed: () async { await prefs.setBool('battery_dialog_seen', true); if (context.mounted) Navigator.pop(context); await openAppSettings(); }, child: const Text("OK", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  Future<void> _checkPermissions() async {
    if (await Permission.notification.isDenied) await Permission.notification.request();
    await Permission.camera.request();
    await Permission.scheduleExactAlarm.request();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // FIX-03 / D-05: per-entry resilient parse — a single corrupt record skips
    // only itself instead of wiping the whole list (no app crash on load).
    final String? alarmsJson = prefs.getString('alarms_data');
    final (parsedAlarms, skipped) = parseAlarmsResilient(alarmsJson);
    setState(() {
      savedBarcodes = prefs.getStringList('target_barcodes') ?? [];
      streakCount = prefs.getInt('user_streak') ?? 0;
      snoozeTokens = prefs.getInt('snooze_tokens') ?? 0;
      alarms = parsedAlarms;
    });

    // D-06: if any record was dropped, tell the user with a light snackbar
    // (NOT a full-screen dialog) after the first frame.
    if (skipped > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSnack(AppStrings.get('alarms_not_restored', currentLang).replaceAll('{n}', '$skipped'));
      });
    }
  }

  Future<void> _saveAlarms() async {
    final prefs = await SharedPreferences.getInstance();
    String encoded = jsonEncode(alarms.map((e) => e.toJson()).toList());
    await prefs.setString('alarms_data', encoded);
  }

  Future<void> _testAlarm() async {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.pop(context);
    }
    
    if (savedBarcodes.isEmpty) {
      _showSnack(AppStrings.get('add_item_first', currentLang));
      return;
    }
    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await scheduleAlarmFn(
      await nextAlarmId(prefs),
      now.add(const Duration(seconds: 5)),
      true,
      currentLang,
      widget.currentRingtone,
      "Test"
    );
    if (!mounted) return;
    _showSnack(AppStrings.get('test_start', currentLang));
  }

  void _showDeveloperOptions() {
    int tempStreak = streakCount;
    int tempTokens = snoozeTokens;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(AppStrings.get('developer_mode', currentLang), style: const TextStyle(color: Colors.blueAccent)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("Streak:"), Row(children: [IconButton(icon: const Icon(Icons.remove), onPressed: () => setDialogState(() => tempStreak = (tempStreak > 0) ? tempStreak - 1 : 0)), Text("$tempStreak", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), IconButton(icon: const Icon(Icons.add), onPressed: () => setDialogState(() => tempStreak++))])]),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("Tokens:"), Row(children: [IconButton(icon: const Icon(Icons.remove), onPressed: () => setDialogState(() => tempTokens = (tempTokens > 0) ? tempTokens - 1 : 0)), Text("$tempTokens", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), IconButton(icon: const Icon(Icons.add), onPressed: () => setDialogState(() => tempTokens = (tempTokens < 3) ? tempTokens + 1 : 3))])]),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('user_streak', tempStreak);
                    await prefs.setInt('snooze_tokens', tempTokens);
                    setState(() { streakCount = tempStreak; snoozeTokens = tempTokens; });
                    if(context.mounted) Navigator.pop(context);
                  },
                  child: const Text("SAVE", style: TextStyle(fontWeight: FontWeight.bold)),
                )
              ],
            );
          }
        );
      },
    );
  }

  // --- RINGTONE PICKER WITH PREVIEW (FIXED) ---
  void _showRingtonePicker() {
    final AudioPlayer previewPlayer = AudioPlayer();
    // Keep a reference to the active timer so we can cancel it
    Timer? previewTimer;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false, initialChildSize: 0.5, minChildSize: 0.3, maxChildSize: 0.8,
          builder: (context, scrollController) {
            return Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(AppStrings.get('select_ringtone', currentLang), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: defaultRingtones.length,
                      itemBuilder: (context, index) {
                        final fileName = defaultRingtones[index];
                        final fullPath = 'assets/sounds/$fileName';
                        String displayName = fileName.replaceAll('.mp3', '');
                        displayName = displayName[0].toUpperCase() + displayName.substring(1).replaceAllMapped(RegExp(r'(\d+)'), (Match m) => " ${m[0]}");
                        final isSelected = widget.currentRingtone == fullPath;
                        return ListTile(
                          leading: Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_off, color: Colors.red),
                          title: Text(displayName),
                          onTap: () async {
                            // 1. Cancel any existing stop timer
                            previewTimer?.cancel();

                            // 2. Stop current sound immediately
                            await previewPlayer.stop(); 

                            // 3. Play new sound
                            await previewPlayer.play(AssetSource('sounds/$fileName'));
                            
                            // 4. Update Selection
                            widget.onRingtoneChanged(fullPath);
                            
                            // 5. Schedule new stop timer
                            previewTimer = Timer(const Duration(seconds: 10), () {
                                previewPlayer.stop();
                            });
                          },
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.folder_open, color: Colors.blue),
                    title: Text(AppStrings.get('pick_from_files', currentLang)),
                    onTap: () async {
                      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
                      if (result != null && result.files.single.path != null) {
                        final path = result.files.single.path!;
                        widget.onRingtoneChanged(path);
                        
                        // Cancel old timer
                        previewTimer?.cancel();
                        await previewPlayer.stop();
                        await previewPlayer.play(DeviceFileSource(path));
                        
                        // Schedule new stop
                        previewTimer = Timer(const Duration(seconds: 10), () => previewPlayer.stop());
                      }
                    },
                  ),
                ],
              ),
            );
          }
        );
      },
    ).then((_) {
      // Clean up when modal closes
      previewTimer?.cancel();
      previewPlayer.stop();
      previewPlayer.dispose();
    });
  }

  void _showStatInfo(String type) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(type == 'streak' ? AppStrings.get('streak_title', currentLang) : AppStrings.get('token_title', currentLang)),
        content: Text(type == 'streak' ? AppStrings.get('streak_desc', currentLang) : AppStrings.get('token_desc', currentLang)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Got it!"))],
      ),
    );
  }

  // Delegates to the top-level [calculateAlarmDateTime] (now unit-testable).
  // Behavior is identical to the prior in-State implementation; existing call
  // sites are unchanged.
  DateTime _calculateAlarmDateTime(TimeOfDay time, List<int> repeatDays) =>
      calculateAlarmDateTime(time, repeatDays);

  Future<void> _addAlarm() async {
    if (savedBarcodes.isEmpty) {
      _showSnack(AppStrings.get('add_item_first', currentLang));
      return;
    }

    TimeOfDay tempTime = TimeOfDay.now();
    List<int> tempDays = [];
    String tempLabel = "";
    String repeatMode = 'once'; 

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: widget.currentThemeMode == ThemeMode.dark ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              height: 600, 
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.get('btn_cancel', currentLang), style: const TextStyle(color: Colors.grey))),
                      Text(AppStrings.get('add_alarm_title', currentLang), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      TextButton(
                        onPressed: () => Navigator.pop(context, 'SAVE'),
                        child: Text(AppStrings.get('btn_save', currentLang), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // TIME PICKER
                  SizedBox(
                    height: 150,
                    child: CupertinoTheme(
                      data: CupertinoThemeData(
                        brightness: widget.currentThemeMode == ThemeMode.dark ? Brightness.dark : Brightness.light,
                        textTheme: const CupertinoTextThemeData(
                          dateTimePickerTextStyle: TextStyle(fontSize: 26)
                        ),
                      ),
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.time,
                        use24hFormat: true,
                        initialDateTime: DateTime.now(),
                        onDateTimeChanged: (DateTime newDateTime) {
                           tempTime = TimeOfDay.fromDateTime(newDateTime);
                        },
                      ),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.label),
                    title: Text(AppStrings.get('label_title', currentLang)),
                    trailing: SizedBox(
                      width: 150,
                      child: TextField(
                        textAlign: TextAlign.end,
                        decoration: InputDecoration.collapsed(hintText: AppStrings.get('label_hint', currentLang)),
                        onChanged: (val) => tempLabel = val,
                      ),
                    ),
                  ),
                  const Divider(),
                  // REPEAT MENU
                  ListTile(
                    leading: const Icon(Icons.repeat),
                    title: Text(AppStrings.get('repeat_title', currentLang)),
                    subtitle: Text(
                        repeatMode == 'once' ? AppStrings.get('repeat_once', currentLang) :
                        repeatMode == 'daily' ? AppStrings.get('daily_repeat', currentLang) :
                        repeatMode == 'weekdays' ? AppStrings.get('weekdays_repeat', currentLang) :
                        tempDays.map((d) => AppStrings.getDayShortName(d, currentLang)).join(", ")
                    ),
                    onTap: () async {
                      await showModalBottomSheet(
                        context: context,
                        builder: (BuildContext context) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                title: Text(AppStrings.get('repeat_once', currentLang)),
                                onTap: () {
                                  setModalState(() {
                                    repeatMode = 'once';
                                    tempDays = [];
                                  });
                                  Navigator.pop(context);
                                },
                              ),
                              ListTile(
                                title: Text(AppStrings.get('daily_repeat', currentLang)),
                                onTap: () {
                                  setModalState(() {
                                    repeatMode = 'daily';
                                    tempDays = [1, 2, 3, 4, 5, 6, 7];
                                  });
                                  Navigator.pop(context);
                                },
                              ),
                              ListTile(
                                title: Text(AppStrings.get('weekdays_repeat', currentLang)),
                                onTap: () {
                                  setModalState(() {
                                    repeatMode = 'weekdays';
                                    tempDays = [1, 2, 3, 4, 5];
                                  });
                                  Navigator.pop(context);
                                },
                              ),
                              ListTile(
                                title: Text(AppStrings.get('custom_repeat', currentLang)),
                                onTap: () async {
                                  Navigator.pop(context); 
                                  await showDialog(
                                    context: context,
                                    builder: (context) {
                                      return StatefulBuilder(
                                        builder: (context, setDialogState) {
                                          return AlertDialog(
                                            title: Text(AppStrings.get('select_days', currentLang)),
                                            content: SingleChildScrollView(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: List.generate(7, (index) {
                                                  final dayIndex = index + 1;
                                                  final isSelected = tempDays.contains(dayIndex);
                                                  return CheckboxListTile(
                                                    title: Text(dayNames[index]),
                                                    value: isSelected,
                                                    activeColor: Colors.red,
                                                    onChanged: (bool? value) {
                                                      setDialogState(() {
                                                        if (value == true) {
                                                          tempDays.add(dayIndex);
                                                        } else {
                                                          tempDays.remove(dayIndex);
                                                        }
                                                        tempDays.sort();
                                                      });
                                                      setModalState(() {
                                                          repeatMode = 'custom';
                                                      }); 
                                                    },
                                                  );
                                                }),
                                              ),
                                            ),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))
                                            ],
                                          );
                                        }
                                      );
                                    }
                                  );
                                },
                              ),
                            ],
                          );
                        }
                      );
                    },
                  ),
                ],
              ),
            );
          }
        );
      }
    ).then((value) async {
       if (value == 'SAVE') {
          final dateTime = _calculateAlarmDateTime(tempTime, tempDays);
          final prefs = await SharedPreferences.getInstance();

          final newAlarm = AlarmEntity(
            id: await nextAlarmId(prefs),
            time: tempTime,
            repeatDays: tempDays, 
            label: tempLabel,
            isActive: true, 
          );

          await scheduleAlarmFn(newAlarm.id, dateTime, true, currentLang, widget.currentRingtone, tempLabel);

          setState(() {
            alarms.add(newAlarm);
            alarms.sort((a, b) => (a.time.hour * 60 + a.time.minute).compareTo(b.time.hour * 60 + b.time.minute));
          });
          _saveAlarms();
          if (mounted) _showRemainingTime(dateTime);
       }
    });
  }

  Future<void> _toggleAlarm(int index, bool value) async {
    setState(() {
      alarms[index].isActive = value;
    });

    if (value) {
       if (savedBarcodes.isEmpty) {
        _showSnack(AppStrings.get('add_item_first', currentLang));
        setState(() => alarms[index].isActive = false);
        return;
      }
      
      final nextTime = _calculateAlarmDateTime(alarms[index].time, alarms[index].repeatDays);
      
      await scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label);
      
      if (mounted) _showRemainingTime(nextTime);
    } else {
      await Alarm.stop(alarms[index].id);
      if (mounted) _showSnack(AppStrings.get('alarm_cancelled', currentLang));
    }
    _saveAlarms();
  }

  Future<void> _deleteAlarm(int index) async {
    await Alarm.stop(alarms[index].id);
    setState(() {
      alarms.removeAt(index);
    });
    _saveAlarms();
  }

  void _showRemainingTime(DateTime target) {
    final now = DateTime.now();
    final difference = target.difference(now);
    final days = difference.inDays;
    final hours = difference.inHours % 24;
    final minutes = difference.inMinutes % 60;
    
    String msg = currentLang == 'tr' 
      ? "${days > 0 ? "$days gün " : ""}${hours > 0 ? "$hours saat " : ""}$minutes dakika sonra çalacak." 
      : "${days > 0 ? "$days days " : ""}${hours > 0 ? "$hours hours " : ""}$minutes minutes.";

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      )
    );
  }

  Future<void> _scanAndAddBarcode() async {
    if (savedBarcodes.length >= 3) {
      _showSnack(AppStrings.get('max_items', currentLang));
      return;
    }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ScannerScreen(language: currentLang))
    );

    if (!mounted) return;

    if (result != null) {
      if (savedBarcodes.contains(result)) {
        _showSnack(AppStrings.get('item_exists', currentLang));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      setState(() => savedBarcodes.add(result));
      await prefs.setStringList('target_barcodes', savedBarcodes);
      
      if (mounted) _showSnack(AppStrings.get('item_added', currentLang));
    }
  }

  Future<void> _removeBarcode(int index) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => savedBarcodes.removeAt(index));
    await prefs.setStringList('target_barcodes', savedBarcodes);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = widget.currentThemeMode == ThemeMode.dark;

    return Scaffold(
      key: _scaffoldKey, 
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: _showDeveloperOptions,
          child: const Text("NoSnooze", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(), 
        ),
        actions: [
          GestureDetector(
            onTap: () => _showStatInfo('streak'),
            child: Container(
              margin: const EdgeInsets.only(left: 10),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[900] : Colors.grey[200],
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: streakCount > 0 ? Colors.orange : Colors.grey)
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department, color: Colors.orange, size: 20),
                  const SizedBox(width: 4),
                  Text("$streakCount", style: TextStyle(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),

          GestureDetector(
            onTap: () => _showStatInfo('token'),
            child: Container(
              margin: const EdgeInsets.only(right: 15, left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: isDark ? Colors.grey[900] : Colors.grey[200],
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: snoozeTokens > 0 ? Colors.cyanAccent : Colors.grey)
              ),
              child: Row(
                children: [
                  const Icon(Icons.timelapse, color: Colors.cyanAccent, size: 20),
                  const SizedBox(width: 4),
                  Text("$snoozeTokens", style: TextStyle(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.red),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.alarm_on, size: 50, color: Colors.white),
                  SizedBox(height: 10),
                  Text("NoSnooze", style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            ListTile(
              title: Text(AppStrings.get('app_version', currentLang), style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(AppStrings.get('ringtone_menu', currentLang)),
              subtitle: Text(widget.currentRingtone.split('/').last), 
              onTap: () {
                _showRingtonePicker();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.language),
              title: Text(AppStrings.get('language_menu', currentLang)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("EN", style: TextStyle(fontWeight: currentLang == 'en' ? FontWeight.bold : FontWeight.normal, color: currentLang == 'en' ? Colors.red : Colors.grey)),
                  const Text(" / "),
                  Text("TR", style: TextStyle(fontWeight: currentLang == 'tr' ? FontWeight.bold : FontWeight.normal, color: currentLang == 'tr' ? Colors.red : Colors.grey)),
                ],
              ),
              onTap: () {
                widget.onLanguageChanged(currentLang == 'tr' ? 'en' : 'tr');
              },
            ),
            SwitchListTile(
              title: Text(AppStrings.get('dark_mode_menu', currentLang)),
              secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
              value: isDark,
              onChanged: (val) {
                widget.onThemeChanged(val);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.play_circle_filled, color: Colors.green),
              title: Text(AppStrings.get('test_alarm_menu', currentLang)),
              onTap: _testAlarm,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addAlarm,
        child: const Icon(Icons.add, size: 30),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("${AppStrings.get('saved_items', currentLang)} (${savedBarcodes.length}/3)", 
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.black87)
                    ),
                    if (savedBarcodes.length < 3)
                      IconButton(onPressed: _scanAndAddBarcode, icon: Icon(Icons.qr_code_scanner, color: isDark ? Colors.white : Colors.black, size: 24))
                  ],
                ),
                if (savedBarcodes.isEmpty)
                   Padding(
                     padding: const EdgeInsets.all(8.0),
                     child: Text(AppStrings.get('list_empty', currentLang), style: const TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center),
                   )
                else
                  Wrap(
                    spacing: 8.0,
                    children: List.generate(savedBarcodes.length, (index) {
                      return Chip(
                        label: Text("${AppStrings.get('item', currentLang)} ${index + 1}"),
                        avatar: const Icon(Icons.qr_code, size: 14),
                        deleteIcon: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                        onDeleted: () => _removeBarcode(index),
                        backgroundColor: isDark ? Colors.grey[800] : Colors.grey[300],
                      );
                    }),
                  ),
              ],
            ),
          ),
          
          const Divider(color: Colors.grey),

          Expanded(
            child: alarms.isEmpty 
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.alarm_off, size: 80, color: Colors.grey[800]),
                      const SizedBox(height: 10),
                      Text(AppStrings.get('no_alarms_set', currentLang), style: const TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: alarms.length,
                  itemBuilder: (context, index) {
                    final alarm = alarms[index];
                    
                    // LIST VIEW: TIME + LABEL + DAYS
                    String daysText;
                    if (alarm.repeatDays.isEmpty) {
                      daysText = AppStrings.get('repeat_once', currentLang);
                    } else if (alarm.repeatDays.length == 7) {
                      daysText = AppStrings.get('daily_repeat', currentLang);
                    } else if (alarm.repeatDays.length == 5 && !alarm.repeatDays.contains(6) && !alarm.repeatDays.contains(7)) {
                       daysText = AppStrings.get('weekdays_repeat', currentLang);
                    } else {
                       daysText = alarm.repeatDays.map((d) => AppStrings.getDayShortName(d, currentLang)).join(', ');
                    }

                    return Dismissible(
                      key: Key(alarm.id.toString()),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (direction) => _deleteAlarm(index),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.grey[900] : Colors.white,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: alarm.isActive ? Colors.red.withValues(alpha: 0.5) : Colors.transparent),
                          boxShadow: isDark ? [] : [BoxShadow(color: Colors.grey.withValues(alpha: 0.2), blurRadius: 5, spreadRadius: 1)],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          title: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                "${alarm.time.hour.toString().padLeft(2, '0')}:${alarm.time.minute.toString().padLeft(2, '0')}",
                                style: TextStyle(
                                  fontSize: 40, 
                                  fontWeight: FontWeight.bold,
                                  color: alarm.isActive ? (isDark ? Colors.white : Colors.black) : Colors.grey
                                ),
                              ),
                              const SizedBox(width: 10),
                              if (alarm.label.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: Text(
                                    alarm.label, 
                                    style: const TextStyle(fontSize: 16, color: Colors.redAccent, fontWeight: FontWeight.w600)
                                  ),
                                )
                            ],
                          ),
                          subtitle: Text(
                              alarm.isActive ? daysText : AppStrings.get('inactive', currentLang), 
                              style: const TextStyle(color: Colors.grey)
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(Icons.delete, color: isDark ? Colors.white54 : Colors.grey),
                                onPressed: () => _deleteAlarm(index),
                              ),
                              Switch(
                                value: alarm.isActive,
                                activeTrackColor: Colors.red, 
                                onChanged: (value) => _toggleAlarm(index, value),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}

class RingScreen extends StatefulWidget {
  final List<String> targetBarcodes;
  final bool startWithoutVibration;
  final String language;
  final int alarmId; 
  final int availableTokens; 
  final String label; 

  const RingScreen({
    super.key, 
    required this.targetBarcodes, 
    this.startWithoutVibration = false, 
    required this.language,
    required this.alarmId,
    required this.availableTokens,
    required this.label,
  });

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> {
  MobileScannerController? controller;
  bool isVibrationStopped = false;
  bool isCameraReady = false;
  late String randomFact;
  bool _showEmergencyButton = false;
  Timer? _emergencyTimer;

  @override
  void initState() {
    super.initState();
    isVibrationStopped = widget.startWithoutVibration;
    randomFact = AppStrings.getRandomFact(widget.language);

    _emergencyTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) setState(() => _showEmergencyButton = true);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _initController();
        setState(() => isCameraReady = true);
      }
    });
  }

  void _initController() {
    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates, 
      returnImage: false,
      torchEnabled: false,
      autoStart: true, 
    );
  }

  void _requestRestart() {
    Navigator.pop(context, 'RESTART');
  }

  void _useSnoozeToken() {
    if (widget.availableTokens > 0) {
      Navigator.pop(context, 'SNOOZE');
    }
  }

  void _handleEmergencyStop() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_ringing', false); 

    setState(() => isLocked = true);
    Alarm.stop(widget.alarmId); 
    HapticFeedback.lightImpact();
    if (!mounted) return;
    Navigator.pop(context);
    
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("⚠️ ${AppStrings.get('alarm_cancelled', widget.language)}")),
    );
  }

  bool isLocked = false;
  Future<void> _onScanSuccess() async {
    if (isLocked) return;
    setState(() => isLocked = true);

    await Alarm.stop(widget.alarmId); 
    HapticFeedback.heavyImpact();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_ringing', false);

    String today = DateTime.now().toString().split(' ')[0];
    String? lastScan = prefs.getString('last_scan_date');
    int currentStreak = prefs.getInt('user_streak') ?? 0;
    int currentTokens = prefs.getInt('snooze_tokens') ?? 0;

    if (lastScan != today) {
        currentStreak++;
        await prefs.setInt('user_streak', currentStreak);
        await prefs.setString('last_scan_date', today);

        bool tokenEarned = false;
        if (currentStreak % 3 == 0 && currentTokens < 3) {
           currentTokens++;
           await prefs.setInt('snooze_tokens', currentTokens);
           tokenEarned = true;
        }

        if(mounted) {
          String msg = "🔥 $currentStreak ${AppStrings.get('streak_day', widget.language)}";
          if (tokenEarned) {
             msg += "\n🎁 +1 ${AppStrings.get('token_name', widget.language)}!";
          }
          if (currentStreak % 7 == 0) {
             msg += "\n\n🎉 ${AppStrings.get('weekly_msg', widget.language)} 🎉";
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "$msg\n\n${AppStrings.get('morning_msg', widget.language)} \n$randomFact",
                textAlign: TextAlign.center,
              ),
              duration: const Duration(seconds: 8),
              backgroundColor: tokenEarned ? Colors.blueAccent : Colors.green,
            ),
          );
        }
    } else {
       if(mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                "${AppStrings.get('morning_msg', widget.language)}\n\n$randomFact",
                textAlign: TextAlign.center
              ), 
              backgroundColor: Colors.green
            ),
          );
       }
    }

    await Future.delayed(const Duration(seconds: 2));

    if(mounted) {
      Navigator.pop(context, 'SUCCESS');
    }
  }

  @override
  void dispose() {
    _emergencyTimer?.cancel();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.red,
        body: Stack(
          children: [
            if (isCameraReady && controller != null)
              MobileScanner(
                controller: controller!,
                onDetect: (capture) {
                  final List<Barcode> barcodes = capture.barcodes;
                  for (final barcode in barcodes) {
                    if (barcode.rawValue != null && widget.targetBarcodes.contains(barcode.rawValue)) {
                      _onScanSuccess();
                      break;
                    }
                  }
                },
              )
            else
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text("Starting Camera...", style: TextStyle(color: Colors.white))
                  ],
                ),
              ),

            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.label.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(
                        widget.label.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold, letterSpacing: 2)
                      ),
                    ),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(20)),
                    child: Text(AppStrings.get('scan_instructions', widget.language), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                  ),
                  
                  if (widget.availableTokens > 0 && !isLocked)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: ElevatedButton.icon(
                        onPressed: _useSnoozeToken,
                        icon: const Icon(Icons.timelapse),
                        label: Text("${AppStrings.get('snooze_btn', widget.language)} (-1 ${AppStrings.get('token_name', widget.language)})"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyanAccent, 
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)
                        ),
                      ),
                    ),

                  const SizedBox(height: 300),
                ],
              ),
            ),

            if (!isVibrationStopped)
              Positioned(
                bottom: 120, left: 0, right: 0,
                child: Center(
                  child: ElevatedButton.icon(
                    onPressed: _requestRestart,
                    icon: const Icon(Icons.vibration, color: Colors.white),
                    label: Text(AppStrings.get('camera_fix_btn', widget.language), textAlign: TextAlign.center),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)),
                  ),
                ),
              ),

            if (isCameraReady && controller != null)
              Positioned(
                top: 50, right: 20,
                child: ValueListenableBuilder(
                  valueListenable: controller!,
                  builder: (context, state, child) {
                    final isFlashOn = state.torchState == TorchState.on;
                    return IconButton(
                      iconSize: 40,
                      icon: Icon(isFlashOn ? Icons.flash_on : Icons.flash_off, color: isFlashOn ? Colors.yellow : Colors.white),
                      onPressed: () => controller?.toggleTorch(),
                    );
                  },
                ),
              ),

            if (_showEmergencyButton)
              Positioned(
                top: 50, left: 20,
                child: GestureDetector(
                  onTap: _handleEmergencyStop,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.redAccent, width: 2)
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 5),
                        Text(
                          AppStrings.get('emergency_btn', widget.language),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ScannerScreen extends StatefulWidget {
  final String language;
  const ScannerScreen({super.key, required this.language});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    torchEnabled: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool isScanCompleted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.get('scan_title', widget.language)), backgroundColor: Colors.black, actions: [
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, state, child) => IconButton(
            icon: Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off, color: state.torchState == TorchState.on ? Colors.yellow : Colors.grey),
            onPressed: () => controller.toggleTorch(),
          ),
        ),
      ]),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (isScanCompleted) return;
              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                HapticFeedback.mediumImpact();
                setState(() => isScanCompleted = true);
                Navigator.pop(context, barcodes.first.rawValue);
              }
            },
          ),
          Positioned(
            bottom: 50, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(AppStrings.get('flash_hint', widget.language), style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AlarmEntity {
  final int id;         
  TimeOfDay time;       
  bool isActive;
  List<int> repeatDays; 
  String label; 
  
  AlarmEntity({
    required this.id,
    required this.time,
    this.isActive = true,
    this.repeatDays = const [], 
    this.label = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': time.hour,
    'minute': time.minute,
    'isActive': isActive,
    'repeatDays': repeatDays,
    'label': label,
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

    return AlarmEntity(
      id: id,
      time: TimeOfDay(hour: hour, minute: minute),
      isActive: isActive,
      repeatDays: repeatDays,
      label: label,
    );
  }
}

class AppStrings {
  static const Map<String, Map<String, String>> _localizedValues = {
    'notification_body': {'tr': 'Susmak için barkodu okut!', 'en': 'Scan barcode to stop alarm!'},
    'saved_items': {'tr': 'Kayıtlı Ürünler', 'en': 'Saved Items'},
    'list_empty': {'tr': 'Barkod eklemek için tarama ikonuna bas.', 'en': 'Tap scanner icon to add barcodes.'},
    'item': {'tr': 'Ürün', 'en': 'Item'},
    'alarm_cancelled': {'tr': 'Alarm İptal Edildi 🔕', 'en': 'Alarm Cancelled 🔕'},
    'scan_instructions': {'tr': 'SUSMAK İÇİN\nTANIMLI ÜRÜNÜ\nOKUT!', 'en': 'SCAN ITEM\nTO STOP!'},
    'morning_msg': {'tr': 'GÜNAYDIN ŞAMPİYON! ☀️', 'en': 'GOOD MORNING CHAMPION! ☀️'},
    'camera_fix_btn': {'tr': 'KAMERA ODAKLAMIYOR MU?\nTİTREŞİMİ KES', 'en': 'CAMERA BLURRY?\nCUT VIBRATION'},
    'scan_title': {'tr': 'Ürün Tara', 'en': 'Scan Item'},
    'flash_hint': {'tr': 'Karanlıktaysa flaşı aç 👆', 'en': 'Turn on flash if dark 👆'},
    'item_exists': {'tr': 'Bu ürün zaten ekli!', 'en': 'Item already exists!'},
    'item_added': {'tr': 'Ürün Eklendi! ✅', 'en': 'Item Added! ✅'},
    'add_item_first': {'tr': 'Önce barkod ekle!', 'en': 'Add an item first!'},
    'test_start': {'tr': '5 saniye sonra çalacak...', 'en': 'Ringing in 5 seconds...'},
    'battery_title': {'tr': '⚠️ Önemli Uyarı', 'en': '⚠️ Important'},
    'battery_desc': {
      'tr': 'Alarmın garanti çalması ve uygulamanın kapanmaması için açılan ekranda şunları yapmalısınız:\n\n'
            '1. PİL/BATARYA: "Kısıtlama Yok" veya "Sınırsız" seçeneğini seçin.\n'
            '2. BAŞLATMA: Varsa "Otomatik Başlatma" veya "Arka Planda Çalışma" iznini açın.',
      'en': 'To ensure the alarm rings reliably, please adjust these settings in the next screen:\n\n'
            '1. BATTERY: Select "Unrestricted" or "No Restrictions".\n'
            '2. LAUNCH: Enable "Autostart" or "Run in Background" if available.'
    },
    'btn_close': {'tr': 'Kapat', 'en': 'Close'},
    'emergency_btn': {'tr': 'ACİL DURUM KAPAT', 'en': 'EMERGENCY STOP'},
    'cheat_title': {'tr': '🚨 HİLE TESPİT EDİLDİ! 🚨', 'en': '🚨 CHEAT DETECTED! 🚨'},
    'cheat_msg': {
      'tr': 'Dün alarm çalarken uygulamayı zorla kapatıp kaçtığını tespit ettik.\n\nBu davranış "NoSnooze" ruhuna aykırı!\n\nCEZA: Seri (Streak) sıfırlandı.',
      'en': 'We detected that you forced closed the app while the alarm was ringing.\n\nThis is against the "NoSnooze" spirit!\n\nPENALTY: Streak reset.'
    },
    'max_items': {'tr': 'En fazla 3 ürün eklenebilir.', 'en': 'Max 3 items allowed.'},
    'streak_title': {'tr': 'Ateş Serisi (Streak)', 'en': 'Fire Streak'},
    'streak_desc': {'tr': 'Her gün zamanında uyanarak seriyi koru. Ateşin sönmesin!', 'en': 'Wake up on time daily to keep the fire burning!'},
    'token_title': {'tr': 'Erteleme Jetonu', 'en': 'Snooze Token'},
    'token_desc': {'tr': 'Her 3 günlük seride 1 jeton kazanırsın. En fazla 3 jeton birikebilir.', 'en': 'Earn 1 token every 3-day streak. Max 3 tokens allowed.'},
    'streak_day': {'tr': '. Gün', 'en': '. Day'},
    'token_name': {'tr': 'Jeton', 'en': 'Token'},
    'ringtone_menu': {'tr': 'Zil Sesi', 'en': 'Ringtone'},
    'language_menu': {'tr': 'Dil / Language', 'en': 'Language'},
    'dark_mode_menu': {'tr': 'Karanlık Mod', 'en': 'Dark Mode'},
    'test_alarm_menu': {'tr': 'Alarmı Test Et', 'en': 'Test Alarm'},
    'select_ringtone': {'tr': 'Zil Sesi Seç', 'en': 'Select Ringtone'},
    'pick_from_files': {'tr': 'Dosyalardan Seç...', 'en': 'Pick from files...'},
    'weekly_msg': {'tr': 'TEBRİKLER! BİR HAFTAYI DEVİRDİN! 🏆', 'en': 'CONGRATS! YOU CRUSHED A WEEK! 🏆'},
    'snooze_btn': {'tr': 'Zzz Ertele', 'en': 'Zzz Snooze'},
    'snooze_used': {'tr': 'Alarm 5dk ertelendi. Jeton kullanıldı.', 'en': 'Alarm snoozed for 5m. Token used.'},
    'alarms_not_restored': {'tr': '{n} alarm geri yüklenemedi', 'en': '{n} alarm(s) could not be restored'},
    'developer_mode': {'tr': '🛠️ Geliştirici Modu', 'en': '🛠️ Developer Mode'},
    'no_alarms_set': {'tr': 'Henüz Alarm Kurulmadı', 'en': 'No Alarms Set'},
    'select_days': {'tr': 'Tekrarlanacak Günleri Seç', 'en': 'Select Repeat Days'},
    'select_day_warning': {'tr': 'En az bir gün seçmelisiniz!', 'en': 'You must select at least one day!'},
    'daily_repeat': {'tr': 'Her Gün', 'en': 'Daily'},
    'weekdays_repeat': {'tr': 'Hafta İçi', 'en': 'Weekdays'},
    'custom_repeat': {'tr': 'Özel...', 'en': 'Custom...'},
    'repeat_once': {'tr': 'Tek Seferlik', 'en': 'One-time'},
    'repeat_title': {'tr': 'Tekrar', 'en': 'Repeat'},
    'label_title': {'tr': 'Etiket', 'en': 'Label'},
    'label_hint': {'tr': 'Alarm', 'en': 'Alarm'},
    'add_alarm_title': {'tr': 'Alarm Ekle', 'en': 'Add Alarm'},
    'btn_cancel': {'tr': 'İptal', 'en': 'Cancel'},
    'btn_save': {'tr': 'Kaydet', 'en': 'Save'},
    'inactive': {'tr': 'Pasif', 'en': 'Inactive'},
    'app_version': {'tr': 'v1.0.0 (Beta)', 'en': 'v1.0.0 (Beta)'},
  };
  
  static const Map<int, Map<String, String>> _dayShortNames = {
      1: {'tr': 'Pzt', 'en': 'Mon'},
      2: {'tr': 'Sal', 'en': 'Tue'},
      3: {'tr': 'Çar', 'en': 'Wed'},
      4: {'tr': 'Per', 'en': 'Thu'},
      5: {'tr': 'Cum', 'en': 'Fri'},
      6: {'tr': 'Cmt', 'en': 'Sat'},
      7: {'tr': 'Paz', 'en': 'Sun'},
  };

  static String get(String key, String lang) {
    return _localizedValues[key]?[lang] ?? key;
  }
  
  static String getDayShortName(int day, String lang) {
    return _dayShortNames[day]?[lang] ?? 'Day';
  }

  static String getRandomFact(String lang) {
    final facts = _sleepFacts[lang] ?? _sleepFacts['tr']!; 
    final randomIndex = DateTime.now().millisecondsSinceEpoch % facts.length; 
    return facts[randomIndex];
  }
  
  static const Map<String, List<String>> _sleepFacts = {
    'tr': [
      "Biliyor muydun? Ortalama bir uyku döngüsü yaklaşık 90 dakikadır.",
      "Uyku sırasında beynin gün içinde öğrendiklerini pekiştirir.",
      "Yetişkinlerin %40'ı günde 7 saatten az uyuyor. Hedefin 7-9 saat olsun!",
      "Uyku eksikliği iştahını artırabilir. Kilo kontrolü için uykuna dikkat et.",
      "Uyanır uyanmaz yatağını toplamak, güne küçük bir başarı ile başlamanı sağlar.",
    ],
    'en': [
      "Did you know? An average sleep cycle is about 90 minutes.",
      "During sleep, your brain consolidates what you learned during the day.",
      "40% of adults sleep less than 7 hours a day. Aim for 7-9 hours!",
      "Lack of sleep increases hunger hormones. Watch your sleep for weight control.",
      "Making your bed right after waking up is a great way to start the day.",
    ],
  };
}