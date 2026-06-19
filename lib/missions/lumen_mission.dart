import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import 'mission.dart';

/// MIS-01 / D-04 / D-06: the first concrete [Mission] — "Lümen". The user must
/// point the phone at a bright light and HOLD it bright for [kLumenHoldMs] (a
/// single below-[kLumenThreshold] frame resets progress — sustained, not
/// cumulative). The camera runs HEADLESS (no [CameraPreview] mounted — D-06):
/// raw frames are streamed, the Y/luma plane is averaged in-memory, and nothing
/// is stored, shown, or transmitted (offline app — T-04-03). Completion fires
/// the [onSuccess] callback supplied by the hosting RingScreen (wired in Plan
/// 03); this plan only proves it compiles + acquires + tears down cleanly.
class LumenMission implements Mission {
  /// The user's language ('tr'/'en') so the mission UI localizes via
  /// [AppStrings]. Passed in by the caller (RingScreen in Plan 03).
  final String language;

  const LumenMission({required this.language});

  @override
  String get title => AppStrings.get('mission_lumen_title', language);

  @override
  Widget build(BuildContext context, VoidCallback onSuccess) =>
      _LumenView(language: language, onSuccess: onSuccess);
}

/// The internal StatefulWidget host that owns the camera lifecycle + progress
/// UI. Split out so [LumenMission] stays a thin, const-constructible contract
/// impl and all the mutable camera/timer state lives here.
class _LumenView extends StatefulWidget {
  final String language;
  final VoidCallback onSuccess;
  const _LumenView({required this.language, required this.onSuccess});

  @override
  State<_LumenView> createState() => _LumenViewState();
}

class _LumenViewState extends State<_LumenView> with WidgetsBindingObserver {
  // Created lazily in a postFrameCallback (NOT a field initializer). On the
  // single-camera MIUI device (Redmi Note 9S, "Max allowed cameras: 1") the
  // prior screen's mobile_scanner camera releases the native camera
  // ASYNCHRONOUSLY/UNAWAITED on dispose. Acquiring a new controller
  // synchronously in build races that teardown and fails to acquire (silent
  // black). Deferring to after the first frame gives the prior camera a moment
  // to release; the backoff auto-retry below self-heals any remaining transient
  // acquire failure. (scanner_screen analog, lines 33-42.)
  CameraController? _cam;
  bool _streaming = false;

  // Sustained-hold bookkeeping (Plan 01 helpers).
  int _heldMs = 0;
  DateTime? _lastTick;
  double _progress = 0; // 0..1
  bool _finished = false; // re-entry guard on completion

  // Auto-retry backoff for transient camera-acquire failures (release race on
  // the single-camera device). Mirrors scanner_screen lines 63-81.
  int _retryCount = 0;
  static const int _maxRetries = 6;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The prior screen's mobile_scanner releases the single MIUI camera
    // ASYNCHRONOUSLY on dispose; opening our controller too soon races that
    // teardown and fails to acquire (device symptom: the mission stays on
    // "Starting Camera...", especially when fired over the lock screen). Wait a
    // beat after the first frame before the first acquire; the backoff retry
    // (now up to 6 attempts) self-heals any remaining race.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        _initCamera();
      });
    });
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (!mounted) return;
      if (cameras.isEmpty) {
        _scheduleAutoRetry();
        return;
      }
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // ResolutionPreset.low: we only average luma — high resolution wastes the
      // isolate (RESEARCH Anti-Pattern). enableAudio:false: no mic needed.
      final controller = CameraController(
        cam,
        ResolutionPreset.low,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // CRITICAL (device-confirmed on Redmi Note 9S): with AUTO-exposure the
      // camera normalizes the FRAME AVERAGE to ~mid-gray (~110) no matter how
      // bright the scene — so avg-luma can never reach a high threshold (the bulb
      // test capped at ~110). Lock exposure (and focus) right after init so the
      // average actually tracks scene brightness: ambient stays low, a real
      // bright light pushes it well up. Best-effort — unsupported modes just
      // throw and we fall back to auto (still usable with the calibrated low
      // threshold). Lock is taken at the ambient pickup scene, so pointing at a
      // bright light then exceeds the baseline.
      try {
        await controller.setExposureMode(ExposureMode.locked);
      } catch (_) {}
      try {
        await controller.setFocusMode(FocusMode.locked);
      } catch (_) {}
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _cam = controller;
      await controller.startImageStream(_onFrame);
      if (!mounted) {
        await controller.stopImageStream();
        await controller.dispose();
        _cam = null;
        return;
      }
      setState(() => _streaming = true);
    } catch (_) {
      // CameraException (acquire race / busy) — self-heal via backoff retry.
      _scheduleAutoRetry();
    }
  }

  // Self-heal a transient camera-acquire failure with a short backoff before
  // giving up. (scanner_screen analog, lines 63-81.)
  void _scheduleAutoRetry() {
    if (_finished) return;
    if (_retryCount >= _maxRetries) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryCount++;
    _retryTimer = Timer(Duration(milliseconds: 300 * _retryCount), () async {
      if (!mounted) return;
      // Tear down any half-open controller before re-acquiring.
      final old = _cam;
      _cam = null;
      _streaming = false;
      if (old != null) {
        try {
          await old.stopImageStream();
        } catch (_) {}
        try {
          await old.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      await _initCamera();
    });
  }

  void _onFrame(CameraImage img) {
    if (_finished || !mounted) return;

    // Y/luma plane (plane 0). Subsample (i += 16) — per-pixel work janks the
    // isolate at ~15-30fps (RESEARCH Anti-Pattern). avg is on a 0..255 scale.
    final bytes = img.planes[0].bytes;
    if (bytes.isEmpty) return;
    int sum = 0;
    int count = 0;
    for (int i = 0; i < bytes.length; i += 16) {
      sum += bytes[i];
      count++;
    }
    if (count == 0) return;
    final avg = sum / count;

    final now = DateTime.now();
    final dtMs =
        _lastTick == null ? 0 : now.difference(_lastTick!).inMilliseconds;
    _lastTick = now;

    // Plan 01 pure helpers: add-on-above / reset-on-drop, complete at hold.
    _heldMs = accumulateHold(_heldMs, avg, dtMs);
    final progress = (_heldMs / kLumenHoldMs).clamp(0.0, 1.0);

    if (lumenComplete(_heldMs)) {
      _finish();
      return;
    }

    if (!mounted) return;
    setState(() {
      _progress = progress;
    });
  }

  // Completion: tear the camera DOWN FULLY (stopImageStream + dispose) BEFORE
  // invoking onSuccess, so the single-camera device frees the lens for whatever
  // the host screen does next and the screen can pop cleanly. Re-entry guarded.
  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    _retryTimer?.cancel();
    final cam = _cam;
    _cam = null;
    if (cam != null) {
      try {
        await cam.stopImageStream();
      } catch (_) {}
      if (!mounted) {
        try {
          await cam.dispose();
        } catch (_) {}
        return;
      }
      try {
        await cam.dispose();
      } catch (_) {}
    }
    if (!mounted) return;
    // Camera is fully torn down — safe to hand control back to the host.
    widget.onSuccess();
  }

  @override
  void dispose() {
    // MIUI single-camera discipline: stop the stream FIRST (shortens the native
    // release window so the next camera open is less likely to race teardown),
    // THEN dispose. dispose() cannot be async, so these are best-effort but
    // fired before the controller is torn down. (scanner_screen lines 96-108.)
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final cam = _cam;
    _cam = null;
    cam?.stopImageStream();
    cam?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language;
    final pct = (_progress * 100).round();
    final nearDone = _progress >= 0.75;

    // D-06 headless: NO CameraPreview is mounted — the camera streams frames in
    // the background only. The indigo Scaffold is owned by RingScreen (Plan 03);
    // this view renders on a transparent background.
    return Container(
      color: Colors.transparent,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(24),
        // Reused translucent card decoration from ring_screen.dart:296.
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppStrings.get('mission_lumen_title', lang).toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.get('mission_lumen_guide', lang),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 28),
            ),
            const SizedBox(height: 24),
            // Amber 12px-tall progress bar fed by _progress, on the indigo
            // mission surface (D-04 / UI-SPEC: amber fill).
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 12,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '$pct%',
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // D-04: nudge — "DAHA PARLAK!" below threshold, "...SABIT TUT!" near
            // completion. Progress resets visibly on a drop (D-02) because
            // _progress is driven straight off accumulateHold.
            Text(
              AppStrings.get(
                nearDone ? 'mission_lumen_hold' : 'mission_lumen_brighter',
                lang,
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: nearDone ? Colors.amber : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            // While the headless camera is still acquiring (notably when the
            // mission fires over the lock screen and the prior camera is still
            // releasing), show a "Starting Camera..." hint; once frames stream
            // the progress bar above is the only feedback.
            if (!_streaming) ...[
              const SizedBox(height: 16),
              Text(
                AppStrings.get('camera_starting', lang),
                style: const TextStyle(color: Colors.white30, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
