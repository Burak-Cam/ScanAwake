import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;
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

import 'constants/app_constants.dart';
import 'l10n/app_strings.dart';
import 'models/alarm_entity.dart';
import 'models/enums.dart';
import 'services/alarm_service.dart';
import 'services/prefs_service.dart';
import 'services/streak_service.dart';

// Re-export shim (RESEARCH Pattern 1): the characterization tests import
// `package:no_snooze/main.dart`, so the symbols extracted into the modules
// below stay reachable from this file. 02-04 rewrites the test imports and
// drops these exports.
export 'constants/app_constants.dart';
export 'l10n/app_strings.dart';
export 'models/alarm_entity.dart';
export 'models/enums.dart';
export 'services/alarm_service.dart';
export 'services/streak_service.dart';

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
    final prefs = PrefsService(await SharedPreferences.getInstance());
    setState(() {
      String? savedLang = prefs.appLang;
      // UX-02 / D-09: saved preference wins; otherwise fall back to the
      // device-aware default instead of a hard English default.
      _locale = Locale(savedLang ??
          defaultLocaleLang(PlatformDispatcher.instance.locale.languageCode));

      bool isDark = prefs.isDarkMode;
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;

      _currentRingtone = prefs.ringtonePath;
    });
  }

  void setLanguage(String langCode) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setAppLang(langCode);
    setState(() => _locale = Locale(langCode));
  }

  void toggleTheme(bool isDark) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setDarkMode(isDark);
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
  }

  void setRingtone(String path) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setRingtonePath(path);
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
        final prefs = PrefsService(await SharedPreferences.getInstance());
        await prefs.setEscapeDetected(true);
      }
    });
  }

  // Stop watching once the alarm is dismissed (any path).
  Future<void> _stopEscapeWatch() async {
    await _fgbgSubscription?.cancel();
    _fgbgSubscription = null;
  }

  /// FIX-01 (Pitfall 4): re-arm a REPEATING alarm to its next occurrence after
  /// any dismiss path (success/snooze/restart/emergency) so it never silently
  /// disappears. One-shot alarms (empty repeatDays) and unknown indices are a
  /// no-op. CRITICAL: re-arm with the STABLE entity id (`alarms[index].id`),
  /// never a transient `% N` id, so `Alarm.set` replaces the same occurrence
  /// instead of double-scheduling. Canonical analog: the old inline SUCCESS
  /// re-arm. Type is AlarmKind.real (a repeating wake alarm is always real).
  Future<void> _rearmIfRepeating(int index) async {
    if (index == -1) return;
    if (alarms[index].repeatDays.isEmpty) return;
    final nextTime = _calculateAlarmDateTime(alarms[index].time, alarms[index].repeatDays);
    await scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label, AlarmKind.real);
  }

  void _startAlarmListener() {
    // ignore: deprecated_member_use
    alarmSubscription = Alarm.ringStream.stream.listen((alarmSettings) async {
      final prefs = PrefsService(await SharedPreferences.getInstance());
      await prefs.setRinging(true);
      // D-01b: record the wall-clock start of the ringing window (boot-guard
      // record; escape_detected is the primary discriminator). Fresh ring =>
      // no prior escape yet.
      await prefs.setRingingSetAt(DateTime.now().millisecondsSinceEpoch);
      await prefs.setEscapeDetected(false);
      // Begin app-level escape detection while ringing (FIX-02 / D-01a).
      await _startEscapeWatch();

      // FIX-04 / D-03 (Pitfall 2): decode the alarm TYPE from the payload. A
      // legacy alarm scheduled before this change has no payload (null/empty)
      // and is treated as AlarmKind.real — back-compat, never crashes.
      AlarmKind firedKind = AlarmKind.real;
      final rawPayload = alarmSettings.payload;
      if (rawPayload != null && rawPayload.isNotEmpty) {
        try {
          final decodedPayload = jsonDecode(rawPayload);
          if (decodedPayload is Map && decodedPayload['kind'] is String) {
            firedKind = AlarmKind.values.byName(decodedPayload['kind'] as String);
          }
        } catch (_) {
          // Corrupt/unknown payload => safe default (real). Never crash on dismiss.
          firedKind = AlarmKind.real;
        }
      }

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
              alarmKind: firedKind,
            ),
          ),
        );

        if (!mounted) return;

        // ARC-03 / D-03: branch on the typed RingResult contract (was the
        // stringly-typed 'RESTART'/'SNOOZE'/'SUCCESS'/'EMERGENCY' sentinels).
        // Navigator results are dynamic, so a non-RingResult value falls
        // through to no dismiss-path action (every real dismiss returns one of
        // the four variants from RingScreen). Re-arm (FIX-01) stays on every path.
        switch (result) {
          case RingResult.restart:
           await Alarm.stop(alarmSettings.id);
           // RLS-05 / D-07: safe-side 2.5s cooldown before re-firing so the
           // camera/vibration stack settles (avoids camera-busy on restart).
           await Future.delayed(const Duration(milliseconds: kCameraRestartCooldownMs));
           await scheduleAlarmFn(alarmSettings.id, DateTime.now().add(const Duration(milliseconds: 100)), false, currentLang, widget.currentRingtone, index != -1 ? alarms[index].label : '', AlarmKind.real);
           // FIX-01: the transient restart fire above is a one-off; a REPEATING
           // alarm must still keep its next scheduled occurrence (stable id).
           await _rearmIfRepeating(index);
            break;
          case RingResult.snooze:
           await prefs.setRinging(false);
           await Alarm.stop(alarmSettings.id);

           int newTokens = snoozeTokens - 1;
           if (newTokens < 0) newTokens = 0;
           await prefs.setSnoozeTokens(newTokens);

           // 5-min transient snooze alarm (separate, transient id).
           await scheduleAlarmFn(
             await nextAlarmId(prefs),
             DateTime.now().add(const Duration(minutes: 5)),
             true,
             currentLang,
             widget.currentRingtone,
             "Snoozed",
             AlarmKind.snooze, // FIX-04 / D-03: snooze re-arm never earns streak.
           );
           // FIX-01: the snooze above is transient; the REPEATING entity must
           // also be re-armed to its next occurrence (stable id) so it survives.
           await _rearmIfRepeating(index);

           setState(() => snoozeTokens = newTokens);
           _showSnack(AppStrings.get('snooze_used', currentLang));
            break;
          case RingResult.success:
           await prefs.setRinging(false);

           // FIX-01: re-arm the repeating alarm to its next occurrence.
           await _rearmIfRepeating(index);

           _loadPreferences();
            break;
          case RingResult.emergency:
           // FIX-01: emergency stop halts the current fire, but a REPEATING
           // alarm must still keep its next occurrence (no silent loss).
           await prefs.setRinging(false);
           await _rearmIfRepeating(index);
            break;
          default:
            // Non-RingResult / null pop (no dismiss action). Re-arm paths above
            // already cover every real dismiss; nothing to do here.
            break;
        }

        // Ring window is over (any dismiss path): stop watching for escapes and
        // clear the transient flag so a clean dismiss leaves no stale signal.
        await _stopEscapeWatch();
        await prefs.setEscapeDetected(false);
      }
    });
  }

  Future<void> _checkCheatStatus() async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    // FIX-02 / D-01: decide via the pure fn instead of unconditionally resetting.
    bool wasRinging = prefs.isRinging;
    bool escapeDetected = prefs.escapeDetected;
    final verdict = decideCheat(wasRinging: wasRinging, escapeDetected: escapeDetected);

    switch (verdict) {
      case CheatVerdict.none:
        // App was not ringing — nothing to judge, streak preserved.
        return;

      case CheatVerdict.preserve:
        // OEM-kill / crash / reboot assumption (D-01): the user did NOT
        // genuinely escape, so streak/tokens are KEPT. Only clear the leftover
        // ringing flags; no reset dialog. (flag-clear analog :1255/:1278.)
        await prefs.setRinging(false);
        await prefs.setEscapeDetected(false);
        return;

      case CheatVerdict.reset:
        // Genuine FGBG escape while ringing => reset (original behavior).
        await prefs.setRinging(false);
        await prefs.setEscapeDetected(false);
        await prefs.setUserStreak(0);
        await prefs.setSnoozeTokens(0);

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
    final prefs = PrefsService(await SharedPreferences.getInstance());
    bool hasSeenWarning = prefs.batteryDialogSeen;
    if (hasSeenWarning) return;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.get('battery_title', currentLang)),
        content: Text(AppStrings.get('battery_desc', currentLang)),
        actions: [
          TextButton(onPressed: () async { await prefs.setBatteryDialogSeen(true); if (context.mounted) Navigator.pop(context); }, child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.grey))),
          TextButton(onPressed: () async { await prefs.setBatteryDialogSeen(true); if (context.mounted) Navigator.pop(context); await openAppSettings(); }, child: const Text("OK", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
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
    final prefs = PrefsService(await SharedPreferences.getInstance());
    if (!mounted) return;
    // FIX-03 / D-05: per-entry resilient parse — a single corrupt record skips
    // only itself instead of wiping the whole list (no app crash on load).
    final String? alarmsJson = prefs.alarmsData;
    final (parsedAlarms, skipped) = parseAlarmsResilient(alarmsJson);
    setState(() {
      savedBarcodes = prefs.targetBarcodes;
      streakCount = prefs.userStreak;
      snoozeTokens = prefs.snoozeTokens;
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
    final prefs = PrefsService(await SharedPreferences.getInstance());
    String encoded = jsonEncode(alarms.map((e) => e.toJson()).toList());
    await prefs.setAlarmsData(encoded);
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
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await scheduleAlarmFn(
      await nextAlarmId(prefs),
      now.add(const Duration(seconds: 5)),
      true,
      currentLang,
      widget.currentRingtone,
      "Test",
      AlarmKind.test, // FIX-04 / D-03: a test alarm never earns streak.
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
                    final prefs = PrefsService(await SharedPreferences.getInstance());
                    await prefs.setUserStreak(tempStreak);
                    await prefs.setSnoozeTokens(tempTokens);
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
          final prefs = PrefsService(await SharedPreferences.getInstance());

          final newAlarm = AlarmEntity(
            id: await nextAlarmId(prefs),
            time: tempTime,
            repeatDays: tempDays, 
            label: tempLabel,
            isActive: true, 
          );

          await scheduleAlarmFn(newAlarm.id, dateTime, true, currentLang, widget.currentRingtone, tempLabel, AlarmKind.real);

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
      
      await scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label, AlarmKind.real);

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
    if (savedBarcodes.length >= kMaxBarcodes) {
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
      final prefs = PrefsService(await SharedPreferences.getInstance());
      setState(() => savedBarcodes.add(result));
      await prefs.setTargetBarcodes(savedBarcodes);

      if (mounted) _showSnack(AppStrings.get('item_added', currentLang));
    }
  }

  Future<void> _removeBarcode(int index) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    setState(() => savedBarcodes.removeAt(index));
    await prefs.setTargetBarcodes(savedBarcodes);
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
                    if (savedBarcodes.length < kMaxBarcodes)
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
  final AlarmKind alarmKind; // FIX-04: type carried from payload to gate streak.

  const RingScreen({
    super.key,
    required this.targetBarcodes,
    this.startWithoutVibration = false,
    required this.language,
    required this.alarmId,
    required this.availableTokens,
    required this.label,
    required this.alarmKind,
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
    Navigator.pop(context, RingResult.restart);
  }

  void _useSnoozeToken() {
    if (widget.availableTokens > 0) {
      Navigator.pop(context, RingResult.snooze);
    }
  }

  void _handleEmergencyStop() async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setRinging(false);

    setState(() => isLocked = true);
    await Alarm.stop(widget.alarmId);
    HapticFeedback.lightImpact();
    if (!mounted) return;
    // FIX-01: return RingResult.emergency (was an arg-less pop) so the dismiss
    // chain in _startAlarmListener can re-arm a repeating alarm to its next
    // occurrence. The user-facing cancelled-snackbar is shown there/here.
    Navigator.pop(context, RingResult.emergency);

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

    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setRinging(false);

    String today = DateTime.now().toString().split(' ')[0];
    String? lastScan = prefs.lastScanDate;
    int currentStreak = prefs.userStreak;
    int currentTokens = prefs.snoozeTokens;

    // FIX-04 / D-02,D-03,D-04: a day counts only for a REAL wake alarm not yet
    // counted today. Test and snooze re-arms never earn streak; a second scan
    // the same day is neutral (streakEligible folds in the lastScan != today
    // guard). Snooze stays streak-neutral here AND on its re-arm path.
    if (streakEligible(widget.alarmKind, lastScan, today)) {
        currentStreak++;
        await prefs.setUserStreak(currentStreak);
        await prefs.setLastScanDate(today);

        bool tokenEarned = false;
        if (currentStreak % 3 == 0 && currentTokens < 3) {
           currentTokens++;
           await prefs.setSnoozeTokens(currentTokens);
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
      Navigator.pop(context, RingResult.success);
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

