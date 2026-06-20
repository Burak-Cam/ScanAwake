import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import '../missions/color_mission.dart';
import '../missions/lumen_mission.dart';
import '../missions/mission.dart';
import '../missions/object_mission.dart';
import '../missions/water_mission.dart';
import '../models/alarm_entity.dart';
import '../models/enums.dart';
import '../services/prefs_service.dart';
import '../services/streak_service.dart';

/// ENG-01 / Pitfall 6: the resolved source for the Stage-2 soft loop. The app
/// stores `ringtonePath` either as a bundled-asset path
/// ('assets/sounds/alarmN.mp3') OR a device-file path (a custom ringtone picked
/// via file_picker). `audioplayers` needs an AssetSource (with the leading
/// 'assets/' STRIPPED — it re-prepends it) for the former and a DeviceFileSource
/// for the latter. This record carries the decision so it is unit-testable
/// without constructing an audioplayers Source (which needs a binding).
typedef SoftLoopSource = ({bool isAsset, String value});

/// ENG-01 / Pitfall 6: pure ringtone-source resolver (unit-tested). A path that
/// begins with 'assets/' is a bundled asset → strip the prefix for AssetSource;
/// anything else (device-file path, empty) is a DeviceFileSource taken verbatim.
SoftLoopSource resolveSoftLoopSource(String path) {
  if (path.startsWith('assets/')) {
    return (isAsset: true, value: path.replaceFirst('assets/', ''));
  }
  return (isAsset: false, value: path);
}

class RingScreen extends StatefulWidget {
  final List<String> targetBarcodes;
  final bool startWithoutVibration;
  final String language;
  final int alarmId;
  final int availableTokens;
  final String label;
  final AlarmKind alarmKind; // FIX-04: type carried from payload to gate streak.
  // ENG-01 / MIS-01: the dismissal mission decoded from the fired payload. For
  // MissionType.none this screen behaves EXACTLY like v1; for a real mission the
  // barcode scan hands off to Stage 2 instead of stopping the alarm.
  final MissionType missionType;
  // ENG-01 / Pitfall 6: the alarm's own ringtone, used for the Stage-2 soft
  // loop. Same value HomeScreen already carries for _rearmIfRepeating.
  final String ringtonePath;

  const RingScreen({
    super.key,
    required this.targetBarcodes,
    this.startWithoutVibration = false,
    required this.language,
    required this.alarmId,
    required this.availableTokens,
    required this.label,
    required this.alarmKind,
    required this.missionType,
    required this.ringtonePath,
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

  // Auto-retry bookkeeping. A stuck black RingScreen camera = the user cannot
  // scan to dismiss the alarm = core-value failure. If the camera fails to
  // acquire (e.g. the user just used another camera app, or a release race on a
  // single-camera MIUI device), self-heal by restarting the controller a few
  // times before falling back to the user-facing message + 60s emergency stop.
  int _retryCount = 0;
  static const int _maxRetries = 5;
  Timer? _retryTimer;

  // ENG-01: Stage-2 state. _missionActive flips the whole screen from the red
  // barcode scanner to the indigo mission surface (D-07). _softPlayer is the
  // ~50% looping handoff audio (D-05). _mission is the hosted Mission (Lümen).
  bool _missionActive = false;
  final AudioPlayer _softPlayer = AudioPlayer();
  Mission? _mission;

  // FIX (lockscreen-mission-hidden): re-assert the lock-screen window flags after
  // Alarm.stop(). The alarm package turns setShowWhenLocked(false) the moment its
  // AlarmRingingLiveData flips false on Alarm.stop, which drops the Stage-2
  // surface behind the keyguard. This native call (MainActivity) re-enables
  // showWhenLocked/turnScreenOn so Stage 2 stays visible over the lock screen,
  // exactly like Stage 1 was (no keyguard dismiss — see MainActivity comment).
  static const MethodChannel _keyguardChannel =
      MethodChannel('com.burakcam.uyan/keyguard');

  // CYCLE 2 (device-verified): the alarm package flips AlarmRingingLiveData via
  // postValue(false) — which is ASYNCHRONOUS — so the observer's
  // setShowWhenLocked(false) runs on the main looper AFTER our synchronous
  // re-assert and re-clears the flag. A single re-assert is therefore NOT enough.
  // We re-assert several times: immediately, on the next frame, and on a few
  // short delays, so a late postValue(false) is overridden. Best-effort: a
  // channel failure (e.g. iOS) must never trap the user.
  Future<void> _showOverLockscreen() async {
    try {
      await _keyguardChannel.invokeMethod('showOverLockscreen');
    } catch (_) {
      // No-op: not available on this platform / engine; the mission still runs.
    }
  }

  // Re-assert across the postValue(false) race window. Best-effort throughout.
  void _reassertLockscreenOverRace() {
    // 1) Immediate (synchronous-ish) re-assert.
    _showOverLockscreen();
    // 2) Next frame — after the current main-looper tasks (incl. a queued
    //    observer false) have a chance to run.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showOverLockscreen();
    });
    // 3) A few short delayed retries to outlast a late postValue(false) dispatch.
    for (final ms in const [50, 150, 400]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        _showOverLockscreen();
      });
    }
  }

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
    // Detection-reliability config tuned for dense real-product EAN-13 codes on
    // low-end / MIUI devices, where ML Kit can take many seconds to land its
    // first decode (Redmi Note 9S field report):
    // - DetectionSpeed.normal + a short detectionTimeoutMs (100ms) lets ML Kit
    //   retry decoding ~10x/sec instead of suppressing repeated attempts as
    //   DetectionSpeed.noDuplicates does. The isLocked guard in _onScanSuccess
    //   makes any repeated emission of the same barcode harmless.
    // - cameraResolution 1920x1080 (vs the 640x480 Android default) gives ML Kit
    //   far more pixels-per-bar, which dense 1D barcodes need to decode quickly.
    // NOTE: formats are intentionally left at the default (all formats). The
    // add-barcode flow (ScannerScreen) stores ANY scanned format verbatim, so
    // restricting formats here could permanently trap a user who saved a non
    // EAN-13 code — a core-value ("must be able to dismiss") violation.
    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 100,
      cameraResolution: const Size(1920, 1080),
      returnImage: false,
      torchEnabled: false,
      autoStart: true,
    );
  }

  // Self-heal a transient camera-acquire failure on the dismiss path. Retries
  // more times than ScannerScreen (5 vs 3) because being unable to dismiss the
  // alarm is the worst-case core-value failure; the 60s emergency-stop button is
  // the final backstop if every retry fails.
  void _scheduleAutoRetry() {
    if (_retryCount >= _maxRetries) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryCount++;
    _retryTimer = Timer(Duration(milliseconds: 400 * _retryCount), () async {
      if (!mounted || controller == null) return;
      try {
        await controller!.stop();
      } catch (_) {
        // ignore — controller may already be stopped
      }
      if (!mounted || controller == null) return;
      try {
        await controller!.start();
      } catch (_) {
        // a failed start surfaces again via errorBuilder, which re-schedules
      }
    });
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

    // SHARED by both branches: stop the alarm-package audio + a confirming
    // haptic. THE FORK happens immediately after this (D-05 / Pattern 5):
    // - MissionType.none keeps the EXACT v1 tail (prefs + setRinging(false) +
    //   streak block + delay + pop).
    // - a real mission hands off to Stage 2 and must NOT clear is_ringing, NOT
    //   run the streak block, and NOT pop here (D-15: is_ringing stays TRUE
    //   through the mission so a mid-mission kill reads as an escape).
    await Alarm.stop(widget.alarmId);
    HapticFeedback.heavyImpact();

    if (widget.missionType != MissionType.none) {
      await _handoffToMission();
      return;
    }

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

  // ENG-01 / D-05 / D-07 / Pattern 5: barcode-verified handoff into Stage 2.
  // Alarm.stop was ALREADY called at the shared scan tail, so it is NOT repeated
  // here. CRITICALLY this method NEVER calls prefs.setRinging(false): is_ringing
  // must stay TRUE through the whole mission so a kill mid-mission is judged an
  // escape by decideCheat (D-15). It does NOT run the streak block and does NOT
  // pop — the screen transforms in place to the indigo Stage-2 mission surface.
  Future<void> _handoffToMission() async {
    // FIX (lockscreen-mission-hidden): Alarm.stop() (called at the shared scan
    // tail, just before this) made the alarm package run setShowWhenLocked(false)
    // via its AlarmRingingLiveData observer, which would let MIUI's keyguard
    // re-engage and hide the Stage-2 surface. Because that flip uses an ASYNC
    // postValue(false), the observer's false runs AFTER a single synchronous
    // re-assert — so we re-assert across the race window (immediate + post-frame
    // + short delayed retries) to override the late false. Best-effort: a channel
    // failure (e.g. iOS) must never trap the user.
    _reassertLockscreenOverRace();
    if (!mounted) return;

    // D-05: start the ~50% soft loop of the alarm's own ringtone so the audio
    // dips but never cuts (SPIKE 001-validated). Pitfall 6: resolve AssetSource
    // (prefix stripped) vs DeviceFileSource (custom file).
    final source = resolveSoftLoopSource(widget.ringtonePath);
    try {
      // RESEARCH Pattern 1 audio-context note: hold media focus in the
      // foreground alarm activity so the soft loop keeps playing (incl. under
      // lock — SC-4 device-verified in Task 2).
      await _softPlayer.setReleaseMode(ReleaseMode.loop);
      if (!mounted) return;
      await _softPlayer.play(
        source.isAsset ? AssetSource(source.value) : DeviceFileSource(source.value),
        // D-01: the Su Sesi mission DUCKS the soft loop to kWaterDuckVolume so the
        // alarm bleed into the mic drops (SC-4 #1) — but it is NEVER silenced
        // (ENG-01). All other missions keep the default 0.5.
        volume: widget.missionType == MissionType.su ? kWaterDuckVolume : 0.5,
      );
    } catch (_) {
      // Audio handoff is best-effort: a failed soft loop must NOT trap the user
      // (core value). The mission still proceeds; the alarm-package audio is
      // already stopped, so worst case is silence, not an un-dismissable alarm.
    }
    if (!mounted) return;

    // Single-camera MIUI discipline: tear the barcode scanner controller down
    // FULLY before the Lümen camera opens (LumenMission also lazy-defers — this
    // is belt-and-suspenders so the lens is free).
    try {
      await controller?.stop();
    } catch (_) {}
    controller?.dispose();
    controller = null;
    if (!mounted) return;

    setState(() {
      // MIS-02 / MIS-03: select the concrete Mission by the alarm's type. renk →
      // ColorMission; nesne → the new ObjectMission; lumen (and any future/default
      // value) → LumenMission. none never reaches here (handled by the != none
      // guard upstream). Success path is identical across missions (same onSuccess
      // → _onMissionSuccess; no new RingResult).
      _mission = switch (widget.missionType) {
        MissionType.renk => ColorMission(language: widget.language),
        MissionType.nesne => ObjectMission(language: widget.language),
        MissionType.su => WaterMission(language: widget.language),
        _ => LumenMission(language: widget.language),
      };
      _missionActive = true;
    });
  }

  // ENG-02 / Pattern 3: the mission-success callback handed to the Mission. This
  // is the ONLY place a mission alarm clears is_ringing and the ONLY place its
  // streak is awarded (DUPLICATED from the none-path v1 tail — Pitfall 3: the
  // streak block must NOT live on any path a mission alarm reaches at scan
  // time). Returns the existing RingResult.success (NO new variant): HomeScreen
  // re-arms (FIX-01) and reloads prefs unchanged.
  bool _missionDone = false;
  Future<void> _onMissionSuccess() async {
    if (_missionDone) return;
    _missionDone = true;

    await _softPlayer.stop();
    HapticFeedback.heavyImpact();

    final prefs = PrefsService(await SharedPreferences.getInstance());
    // Cleared HERE — the sole is_ringing clear on the mission path (D-15).
    await prefs.setRinging(false);

    String today = DateTime.now().toString().split(' ')[0];
    String? lastScan = prefs.lastScanDate;
    int currentStreak = prefs.userStreak;
    int currentTokens = prefs.snoozeTokens;

    // FIX-04: SAME streakEligible gate as the v1 tail; widget.alarmKind is
    // already carried from the payload.
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

    if (mounted) {
      Navigator.pop(context, RingResult.success);
    }
  }

  @override
  void dispose() {
    _emergencyTimer?.cancel();
    _retryTimer?.cancel();
    controller?.dispose();
    // ENG-01: best-effort teardown of the Stage-2 soft loop.
    _softPlayer.stop();
    _softPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ENG-01 / D-07: once the mission starts, the whole screen hard-swaps from
    // the red barcode scanner to the indigo Stage-2 mission surface.
    if (_missionActive) {
      return _buildMissionStage(context);
    }
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.red,
        body: Stack(
          children: [
            if (isCameraReady && controller != null)
              MobileScanner(
                controller: controller!,
                // If the camera pipeline fails, auto-retry acquiring it (a stuck
                // camera here means the user cannot dismiss the alarm) and show a
                // clear message instead of a silent black screen. The user still
                // has the 60s emergency-stop fallback if every retry fails.
                errorBuilder: (context, error, child) {
                  _scheduleAutoRetry();
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        AppStrings.get('scan_instructions', widget.language),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 20),
                      ),
                    ),
                  );
                },
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

  // ENG-01 / D-07 / D-08 / D-13 / D-14: the Stage-2 mission surface. Hard indigo
  // background (D-07). Shows the sound-lowered status (D-08: vibration already
  // stopped by Alarm.stop; no new vibration loop) and hosts the Mission body
  // INSTEAD of the scanner. The snooze button is gone (D-14 — naturally, since
  // isLocked is true post-scan and this layout omits it). The emergency pill
  // (D-13) stays available; its 60s timer already runs from initState.
  Widget _buildMissionStage(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.indigo,
        body: Stack(
          children: [
            // D-06 headless: the Mission renders its own UI (no CameraPreview)
            // on this indigo surface.
            if (_mission != null) _mission!.build(context, _onMissionSuccess),

            // D-08: sound-lowered status (volume_down) — the alarm package audio
            // is stopped and only the ~50% soft loop plays; vibration is halted.
            Positioned(
              top: 50, right: 20,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.volume_down, color: Colors.white70, size: 22),
                  const SizedBox(width: 6),
                  Text(
                    AppStrings.get('mission_sound_lowered', widget.language),
                    style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                ],
              ),
            ),

            // D-13: emergency stop stays reachable in mission mode (not success,
            // awards no streak). The same 60s gate applies.
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
                      border: Border.all(color: Colors.redAccent, width: 2),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 5),
                        Text(
                          AppStrings.get('emergency_btn', widget.language),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
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
