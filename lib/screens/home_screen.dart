import 'dart:async';
import 'dart:convert';
import 'package:alarm/alarm.dart';
// RLS-06: AlarmSet (the Alarm.ringing ValueStream payload) is NOT re-exported
// from the package root in alarm 5.1.5; import it from its utils path.
import 'package:alarm/utils/alarm_set.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_fgbg/flutter_fgbg.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import '../models/alarm_entity.dart';
import '../models/enums.dart';
import '../services/alarm_service.dart';
import '../services/prefs_service.dart';
import '../services/streak_service.dart';
import 'ring_screen.dart';
import 'scanner_screen.dart';

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
    _bootstrap();
  }

  // WR-02: sequence cold-start init. _checkCheatStatus and _startAlarmListener
  // both read/write the same is_ringing / escape_detected prefs keys; running
  // them concurrently (the old fire-and-forget pair) let a fresh-ring write race
  // a genuine escape verdict. Finish the cheat verdict BEFORE the listener can
  // overwrite those flags.
  Future<void> _bootstrap() async {
    await _checkCheatStatus();
    await _initializeRest();
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
      if (event != FGBGType.background) return;
      final prefs = PrefsService(await SharedPreferences.getInstance());
      // WR-06: a background event already queued when the subscription is
      // cancelled (dismiss/dispose) could otherwise flip escape_detected after
      // teardown and poison the next cold-start cheat verdict. Skip the write if
      // the State is gone.
      if (!mounted) return;
      await prefs.setEscapeDetected(true);
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
  /// CR-02: returns whether the re-arm actually scheduled. A no-op (one-shot /
  /// unknown index) returns true. When `scheduleAlarmFn` returns false the
  /// exact-alarm permission was revoked mid-ring, so a REPEATING alarm would
  /// silently never re-arm — the caller surfaces the redirect dialog instead of
  /// dropping it on the floor (FIX-01's guarantee was being lost).
  Future<bool> _rearmIfRepeating(int index) async {
    if (index == -1) return true;
    if (alarms[index].repeatDays.isEmpty) return true;
    final nextTime = _calculateAlarmDateTime(alarms[index].time, alarms[index].repeatDays);
    // ENG-03 / MIS-01: carry the alarm's persisted mission into the re-arm.
    // scheduleAlarmFn's missionType defaults to none, so omitting it here would
    // silently DOWNGRADE a repeating Lümen alarm to MissionType.none on every
    // re-fire (losing its mission forever). A repeating Lümen alarm MUST re-arm
    // AS Lümen — hence the explicit pass of alarms[index].missionType.
    return scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label, AlarmKind.real, missionType: alarms[index].missionType);
  }

  void _startAlarmListener() {
    // RLS-06 / D-05: migrated from the deprecated ring-stream API (a
    // StreamController<AlarmSettings>) to `Alarm.ringing`, a
    // ValueStream<AlarmSet> whose `.alarms` is a Set<AlarmSettings>. We iterate
    // the set (Pitfall 2 — handle every ringing alarm, not just the first) and
    // run the IDENTICAL per-alarm dismiss body. Subscribe exactly ONCE and
    // cancel in dispose (preserved below).
    //
    // Pitfall 1 (ValueStream replay): a ValueStream re-emits its last value to
    // every new subscriber, so a re-subscribe (hot reload / re-init / after
    // cancel) could replay a STALE AlarmSet and re-open RingScreen for an alarm
    // that is no longer ringing. Guard the body with a freshness check
    // (`Alarm.isRinging`) and skip any alarm the platform no longer reports as
    // ringing, so a clean dismiss is never re-triggered.
    alarmSubscription = Alarm.ringing.listen((AlarmSet alarmSet) async {
      for (final alarmSettings in alarmSet.alarms) {
      // Pitfall 1 replay guard: ignore an alarm the native layer is no longer
      // actually ringing (stale ValueStream replay after dismiss).
      if (!await Alarm.isRinging(alarmSettings.id)) continue;
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
           // WR-01: clear the ringing flag like the other dismiss paths (was
           // omitted here); the restart fire below makes the listener set it
           // true again, so this avoids a stale is_ringing on an OEM-kill.
           await prefs.setRinging(false);
           await Alarm.stop(alarmSettings.id);
           // RLS-05 / D-07: safe-side 2.5s cooldown before re-firing so the
           // camera/vibration stack settles (avoids camera-busy on restart).
           await Future.delayed(const Duration(milliseconds: kCameraRestartCooldownMs));
           final restarted = await scheduleAlarmFn(alarmSettings.id, DateTime.now().add(const Duration(milliseconds: 100)), false, currentLang, widget.currentRingtone, index != -1 ? alarms[index].label : '', AlarmKind.real);
           // FIX-01: the transient restart fire above is a one-off; a REPEATING
           // alarm must still keep its next scheduled occurrence (stable id).
           final restartRearmed = await _rearmIfRepeating(index);
           // CR-02: if exact-alarm permission was revoked mid-ring, the restart
           // (and/or the repeating re-arm) silently failed — surface it.
           if ((!restarted || !restartRearmed) && mounted) await _showExactAlarmDialog();
            break;
          case RingResult.snooze:
           await prefs.setRinging(false);
           await Alarm.stop(alarmSettings.id);

           int newTokens = snoozeTokens - 1;
           if (newTokens < 0) newTokens = 0;
           await prefs.setSnoozeTokens(newTokens);

           // 5-min transient snooze alarm (separate, transient id).
           final snoozed = await scheduleAlarmFn(
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
           final snoozeRearmed = await _rearmIfRepeating(index);

           setState(() => snoozeTokens = newTokens);
           // CR-02: only claim the snooze succeeded when it was actually
           // scheduled; otherwise tell the user the exact-alarm permission is
           // missing instead of a misleading "snooze used" message.
           if ((!snoozed || !snoozeRearmed) && mounted) {
             await _showExactAlarmDialog();
           } else {
             _showSnack(AppStrings.get('snooze_used', currentLang));
           }
            break;
          case RingResult.success:
           await prefs.setRinging(false);

           // FIX-01: re-arm the repeating alarm to its next occurrence.
           final successRearmed = await _rearmIfRepeating(index);
           // CR-02: a revoked exact-alarm permission would drop the repeating
           // alarm silently — surface it so the user can re-grant.
           if (!successRearmed && mounted) await _showExactAlarmDialog();

           _loadPreferences();
            break;
          case RingResult.emergency:
           // FIX-01: emergency stop halts the current fire, but a REPEATING
           // alarm must still keep its next occurrence (no silent loss).
           await prefs.setRinging(false);
           final emergencyRearmed = await _rearmIfRepeating(index);
           if (!emergencyRearmed && mounted) await _showExactAlarmDialog();
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
      } // end for (alarmSettings in alarmSet.alarms)
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

  // RLS-04 / D-03: redirect dialog shown when the funnel reports the exact-alarm
  // permission is missing. Mirrors the _checkBatteryOptimization dialog: a
  // "close" action and an "Open Settings" action that deep-links to the system
  // permission page via openAppSettings(). barrierDismissible:false so the user
  // makes an explicit choice. context.mounted guard preserves async-safety.
  Future<void> _showExactAlarmDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(AppStrings.get('exact_alarm_title', currentLang)),
        content: Text(AppStrings.get('exact_alarm_desc', currentLang)),
        actions: [
          TextButton(
            onPressed: () { if (context.mounted) Navigator.pop(context); },
            child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async { if (context.mounted) Navigator.pop(context); await openAppSettings(); },
            child: Text(AppStrings.get('btn_open_settings', currentLang), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // RLS-04 / D-03: catch the funnel signal. Runs the schedule thunk; if it
  // returns false (exact-alarm permission missing => no Alarm.set happened) and
  // we still have a UI context, show the redirect dialog. Returns the same bool
  // so callers can roll back their optimistic state on failure. Signature is
  // BYTE-IDENTICAL to Plan 03 Task 2 (Wave 2 signature compatibility).
  Future<bool> _ensureExactAlarmOrPrompt(Future<bool> Function() scheduleCall) async {
    final ok = await scheduleCall();
    if (!ok && mounted) await _showExactAlarmDialog();
    return ok;
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
    final testId = await nextAlarmId(prefs);
    // RLS-04 / D-03: route through the funnel-signal helper; if exact-alarm
    // permission is missing the dialog is shown and we return silently.
    final ok = await _ensureExactAlarmOrPrompt(() => scheduleAlarmFn(
      testId,
      now.add(const Duration(seconds: 5)),
      true,
      currentLang,
      widget.currentRingtone,
      "Test",
      AlarmKind.test, // FIX-04 / D-03: a test alarm never earns streak.
    ));
    if (!mounted || !ok) return;
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

  // UX-01: single source of truth for deriving the repeat-mode label from a
  // list of repeat days. MUST stay byte-consistent with the list-render
  // derivation (see build()'s ListView.builder daysText) so the modal pre-fill
  // and the list row never diverge. 'once' (empty) / 'daily' (all 7) /
  // 'weekdays' (Mon-Fri, no Sat/Sun) / 'custom' (anything else).
  String _deriveRepeatMode(List<int> days) {
    if (days.isEmpty) return 'once';
    if (days.length == 7) return 'daily';
    if (days.length == 5 && !days.contains(6) && !days.contains(7)) return 'weekdays';
    return 'custom';
  }

  // UX-01 / D-01: shared add/edit modal. `editing == null` => add a new alarm
  // (existing flow, new monotonic id). `editing != null` => in-place edit: the
  // fields are pre-filled and the SAME editing.id is preserved on save (Task 2).
  Future<void> _addAlarm({AlarmEntity? editing}) async {
    if (savedBarcodes.isEmpty) {
      _showSnack(AppStrings.get('add_item_first', currentLang));
      return;
    }

    // UX-01 / D-01: pre-fill from `editing` when editing, else add-mode defaults.
    TimeOfDay tempTime = editing?.time ?? TimeOfDay.now();
    List<int> tempDays = editing != null ? List<int>.from(editing.repeatDays) : [];
    String tempLabel = editing?.label ?? "";
    // D-11 / UX-01: pre-fill the per-alarm mission. Legacy alarms (predating the
    // field) read MissionType.none via the Plan-01 defensive fromJson.
    MissionType tempMissionType = editing?.missionType ?? MissionType.none;
    String repeatMode = _deriveRepeatMode(tempDays);

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
                      Text(AppStrings.get(editing == null ? 'add_alarm_title' : 'edit_alarm_title', currentLang), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
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
                        // Pitfall 3: a TimeOfDay cannot be passed directly; when
                        // editing, build a DateTime on today's date carrying the
                        // alarm's hour/minute so the picker shows the real time
                        // (not 00:00). Add-mode keeps DateTime.now().
                        initialDateTime: editing != null
                            ? () {
                                final now = DateTime.now();
                                return DateTime(now.year, now.month, now.day, tempTime.hour, tempTime.minute);
                              }()
                            : DateTime.now(),
                        onDateTimeChanged: (DateTime newDateTime) {
                           setModalState(() {
                             tempTime = TimeOfDay.fromDateTime(newDateTime);
                           });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Live "remaining time" label — rebuilt by StatefulBuilder
                  // whenever tempTime (time picker) or tempDays (repeat menu)
                  // change, so the user sees how far away the alarm is BEFORE
                  // saving. Pure _remainingText needs no `mounted` guard.
                  Text(
                    _remainingText(_calculateAlarmDateTime(tempTime, tempDays)),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
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
                  const Divider(),
                  // MISSION MENU (D-09): verbatim mirror of the repeat-menu
                  // ListTile + showModalBottomSheet pattern above.
                  ListTile(
                    leading: const Icon(Icons.flag),
                    title: Text(AppStrings.get('mission_menu_title', currentLang)),
                    subtitle: Text(
                      tempMissionType == MissionType.lumen
                          ? AppStrings.get('mission_lumen_name', currentLang)
                          : AppStrings.get('mission_none', currentLang),
                    ),
                    onTap: () async {
                      await showModalBottomSheet(
                        context: context,
                        builder: (BuildContext context) {
                          // D-10: ONLY the two ready missions — no coming-soon /
                          // disabled rows.
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  AppStrings.get('mission_select_title', currentLang),
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ),
                              ListTile(
                                leading: const Icon(Icons.block),
                                title: Text(AppStrings.get('mission_none', currentLang)),
                                onTap: () {
                                  setModalState(() => tempMissionType = MissionType.none);
                                  Navigator.pop(context);
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.wb_sunny),
                                title: Text(AppStrings.get('mission_lumen_name', currentLang)),
                                onTap: () {
                                  setModalState(() => tempMissionType = MissionType.lumen);
                                  Navigator.pop(context);
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
       if (value != 'SAVE') return;

       final dateTime = _calculateAlarmDateTime(tempTime, tempDays);

       if (editing == null) {
          // --- ADD path (unchanged): new monotonic id ---
          final prefs = PrefsService(await SharedPreferences.getInstance());

          final newAlarm = AlarmEntity(
            id: await nextAlarmId(prefs),
            time: tempTime,
            repeatDays: tempDays,
            label: tempLabel,
            isActive: true,
            missionType: tempMissionType,
          );

          // RLS-04 / D-03: if exact-alarm permission is missing the funnel does
          // NOT set the alarm and the dialog is shown — do not add/persist it.
          final ok = await _ensureExactAlarmOrPrompt(() => scheduleAlarmFn(newAlarm.id, dateTime, true, currentLang, widget.currentRingtone, tempLabel, AlarmKind.real, missionType: tempMissionType));
          if (!ok) return;

          setState(() {
            alarms.add(newAlarm);
            alarms.sort((a, b) => (a.time.hour * 60 + a.time.minute).compareTo(b.time.hour * 60 + b.time.minute));
          });
          _saveAlarms();
          if (mounted) _showRemainingTime(dateTime);
          return;
       }

       // --- EDIT path (UX-01 / D-01, D-02): preserve the SAME editing.id ---
       // T-03-08 mitigation: nextAlarmId() is NEVER called here, so re-arming
       // replaces the same occurrence instead of orphaning a stale schedule.
       final idx = alarms.indexWhere((a) => a.id == editing.id);
       if (idx == -1) return; // alarm vanished (e.g. deleted) — nothing to edit.

       setState(() {
         alarms[idx].time = tempTime;
         alarms[idx].repeatDays = tempDays;
         alarms[idx].label = tempLabel;
         // ENG-03 / MIS-01: persist the selected mission on the same entity (the
         // editing.id stays stable — UX-01).
         alarms[idx].missionType = tempMissionType;
         // UX-01 (deliberate D-02 reversal): editing a PASSIVE (Switch off) alarm
         // and tapping SAVE now auto-activates it. Idempotent for already-active
         // alarms (true → true). User confirmed this during device UAT.
         alarms[idx].isActive = true;
         // Same time-of-day ordering the add path uses.
         alarms.sort((a, b) => (a.time.hour * 60 + a.time.minute).compareTo(b.time.hour * 60 + b.time.minute));
       });
       _saveAlarms();

       // UX-01: passive AND active alarms now go through the SAME scheduling
       // funnel below. The previous D-02 early-return (passive alarm just
       // updated its entity without scheduling) was deliberately removed —
       // editing + SAVE always arms the alarm. The CR-01 ghost-alarm fallback
       // still protects the passive→active path (exact-alarm permission denied
       // flips isActive back to false + persists).

       // Cancel the old schedule, then re-arm at the new time with the SAME id.
       // The re-arm goes through Plan 02's funnel-signal helper (same signature,
       // not redefined) so the edit save passes the in-funnel exact-alarm gate
       // (T-03-10 — no leaked Alarm.set; single funnel / D-03).
       await Alarm.stop(editing.id);
       final ok = await _ensureExactAlarmOrPrompt(() => scheduleAlarmFn(editing.id, dateTime, true, currentLang, widget.currentRingtone, tempLabel, AlarmKind.real, missionType: tempMissionType));
       if (!ok) {
         // CR-01: the old schedule was already stopped and the new one was NOT
         // set (exact-alarm permission missing — the helper already showed the
         // redirect dialog). Flip the visible state to OFF so the user never
         // sees an "active" alarm that the OS will never fire (core-value
         // breach). Re-enabling the Switch re-attempts the arm via _toggleAlarm.
         if (mounted) setState(() => alarms[idx].isActive = false);
         _saveAlarms();
         return;
       }
       if (mounted) _showRemainingTime(dateTime);
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

      // RLS-04 / D-03: catch the funnel signal. If exact-alarm permission is
      // missing, the dialog is shown and the Switch is rolled back to off.
      final ok = await _ensureExactAlarmOrPrompt(() => scheduleAlarmFn(alarms[index].id, nextTime, true, currentLang, widget.currentRingtone, alarms[index].label, AlarmKind.real));
      if (!ok) {
        if (mounted) setState(() => alarms[index].isActive = false);
        _saveAlarms();
        return;
      }

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

  // Pure helper: build the human-readable "rings in ..." string for a target
  // DateTime. Uses DateTime.now() only (no `mounted`/BuildContext needed), so it
  // is safe to call during widget builds (e.g. the live modal label). Single
  // source of truth — _showRemainingTime delegates here (DRY).
  String _remainingText(DateTime target) {
    final now = DateTime.now();
    final difference = target.difference(now);
    final days = difference.inDays;
    final hours = difference.inHours % 24;
    final minutes = difference.inMinutes % 60;

    return currentLang == 'tr'
      ? "${days > 0 ? "$days gün " : ""}${hours > 0 ? "$hours saat " : ""}$minutes dakika sonra çalacak."
      : "Rings in ${days > 0 ? "$days days " : ""}${hours > 0 ? "$hours hours " : ""}$minutes minutes.";
  }

  void _showRemainingTime(DateTime target) {
    final msg = _remainingText(target);

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
                    // UX-01: derive the repeat label through the SAME helper the
                    // edit modal uses (_deriveRepeatMode) so the list row and the
                    // pre-filled modal never diverge (single source of truth).
                    final String daysText;
                    switch (_deriveRepeatMode(alarm.repeatDays)) {
                      case 'once':
                        daysText = AppStrings.get('repeat_once', currentLang);
                      case 'daily':
                        daysText = AppStrings.get('daily_repeat', currentLang);
                      case 'weekdays':
                        daysText = AppStrings.get('weekdays_repeat', currentLang);
                      default:
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
                          // UX-01 / D-01: tap the row to open the pre-filled edit
                          // modal. Distinct from the Dismissible swipe (delete)
                          // and the trailing Switch (toggle) — gestures don't clash.
                          onTap: () => _addAlarm(editing: alarm),
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
