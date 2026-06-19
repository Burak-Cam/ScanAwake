import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import 'mission.dart';

/// MIS-02: the third concrete [Mission] — "Renk Bul" (Find the Color). A slot
/// machine auto-spins on open and lands on a random target hue from
/// [kColorPaletteHues]; the user must show an object of that color to the
/// camera and HOLD it for [kColorHoldMs] (a single non-matching frame resets
/// progress — sustained, not cumulative, mirroring Lümen's D-02 discipline). An
/// unlimited Reroll button re-spins with no penalty.
///
/// The camera lifecycle is a VERBATIM clone of [LumenMission] (postFrame+450ms
/// acquire, 6-step backoff retry for the Redmi Note 9S single-camera release
/// race, full teardown-before-onSuccess) — the ONLY material difference is the
/// per-frame work, which samples the center ROI and converts YUV420 (Android)
/// or BGRA8888 (iOS) → RGB → HSV instead of averaging luma. The camera runs
/// HEADLESS (no [CameraPreview] mounted — D-06): frames are sampled in-memory
/// only, never stored/shown/transmitted (offline app — T-05-04). Completion
/// fires the [onSuccess] callback supplied by the hosting RingScreen.
class ColorMission implements Mission {
  /// The user's language ('tr'/'en') so the mission UI localizes via
  /// [AppStrings]. Passed in by the caller (RingScreen).
  final String language;

  const ColorMission({required this.language});

  @override
  String get title => AppStrings.get('mission_color_title', language);

  @override
  Widget build(BuildContext context, VoidCallback onSuccess) =>
      _ColorView(language: language, onSuccess: onSuccess);
}

/// The internal StatefulWidget host that owns the camera lifecycle + slot
/// animation + swatch/progress UI. Split out so [ColorMission] stays a thin,
/// const-constructible contract impl and all mutable state lives here.
class _ColorView extends StatefulWidget {
  final String language;
  final VoidCallback onSuccess;
  const _ColorView({required this.language, required this.onSuccess});

  @override
  State<_ColorView> createState() => _ColorViewState();
}

/// MIS-02: palette index → localized color-name key, aligned with
/// [kColorPaletteHues] order (0=red … 5=purple). Used to label the target
/// swatch.
const List<String> _kColorNameKeys = [
  'color_red',
  'color_orange',
  'color_yellow',
  'color_green',
  'color_blue',
  'color_purple',
];

class _ColorViewState extends State<_ColorView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // Created lazily in a postFrameCallback (NOT a field initializer). On the
  // single-camera MIUI device (Redmi Note 9S, "Max allowed cameras: 1") the
  // prior screen's mobile_scanner camera releases the native camera
  // ASYNCHRONOUSLY/UNAWAITED on dispose. Acquiring a new controller
  // synchronously in build races that teardown and fails to acquire (silent
  // black). Deferring to after the first frame gives the prior camera a moment
  // to release; the backoff auto-retry below self-heals any remaining transient
  // acquire failure. (lumen_mission analog.)
  CameraController? _cam;
  bool _streaming = false;

  // Sustained-hold bookkeeping (Plan 01 helpers).
  int _heldMs = 0;
  DateTime? _lastTick;
  double _progress = 0; // 0..1
  bool _finished = false; // re-entry guard on completion

  // The live sampled-color swatch fill (null until the first frame is sampled).
  Color? _liveColor;

  // Auto-retry backoff for transient camera-acquire failures (release race on
  // the single-camera device). Mirrors lumen_mission lines 63-81.
  int _retryCount = 0;
  static const int _maxRetries = 6;
  Timer? _retryTimer;

  // MIS-02 slot machine: a single stock AnimationController drives the vertical
  // color-strip scroll (Curves.decelerate) over ~1.5s, landing on the random
  // target. Disposed in dispose(). No new package (CLAUDE.md constraint).
  late final AnimationController _slot;
  late Animation<double> _slotAnim;
  int _targetIndex = 0;

  // Slot strip geometry (logical px). The visible window shows one swatch; the
  // strip repeats the palette several cycles so it scrolls before settling.
  static const double _swatchHeight = 56;
  static const int _cycles = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Slot controller — vsync from SingleTickerProviderStateMixin.
    _slot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _slotAnim = const AlwaysStoppedAnimation<double>(0);
    // Auto-spin once on open so the user sees a target immediately (CONTEXT
    // decision). Picks _targetIndex + resets _heldMs.
    _spin();
    // The prior screen's mobile_scanner releases the single MIUI camera
    // ASYNCHRONOUSLY on dispose; opening our controller too soon races that
    // teardown and fails to acquire (device symptom: the mission stays on
    // "Starting Camera...", especially when fired over the lock screen). Wait a
    // beat after the first frame before the first acquire; the backoff retry
    // (up to 6 attempts) self-heals any remaining race.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        _initCamera();
      });
    });
  }

  // MIS-02: pick a new random target and (re)build + run the slot animation.
  // Resets _heldMs so a reroll mid-hold carries NO progress penalty (unlimited,
  // no-penalty reroll — MIS-02). A mid-spin tap restarts cleanly.
  void _spin() {
    final newIndex = Random().nextInt(kColorPaletteHues.length);
    // Land so the target swatch sits in the center window after _cycles full
    // palette scrolls (deterministic via Tween + Curves.decelerate).
    final end =
        (_cycles * kColorPaletteHues.length + newIndex) * _swatchHeight;
    _slotAnim = Tween<double>(begin: 0, end: end)
        .animate(CurvedAnimation(parent: _slot, curve: Curves.decelerate));
    if (mounted) {
      setState(() {
        _targetIndex = newIndex;
        _heldMs = 0;
        _progress = 0;
      });
    } else {
      _targetIndex = newIndex;
      _heldMs = 0;
      _progress = 0;
    }
    if (_slot.isAnimating) _slot.stop();
    _slot.forward(from: 0);
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
      // ResolutionPreset.low: we only sample a small center ROI — high
      // resolution wastes the isolate (RESEARCH Anti-Pattern). enableAudio:false.
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
      // DELIBERATE DIVERGENCE from LumenMission (RESEARCH Pitfall 2 / Open Q1):
      // do NOT call setExposureMode(locked)/setFocusMode(locked) here. Color
      // hue is largely exposure-invariant, and AUTO-exposure + AUTO white
      // balance brighten/normalize a real colored object so it can reach the
      // kColorMinSat/kColorMinVal floors (a lock taken on the dim pickup scene
      // would starve the val floor). SC-4 (Task 3) may revisit these modes on
      // the device if needed.
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
  // giving up. (lumen_mission analog, lines 147-169.)
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

  // MIS-02 THE NEW WORK: sample the center ~20% ROI of the frame, convert to RGB
  // (YUV420 on Android with chroma row/pixel strides; BGRA8888 on iOS), average
  // → HSV, then feed the SAME sustained-hold skeleton as Lümen. Subsampled
  // (step 2) and ROI-only so it stays cheap at 15-30fps (RESEARCH Pitfall 3).
  void _onFrame(CameraImage img) {
    if (_finished || !mounted) return;

    final sample = _sampleCenterRgb(img);
    if (sample == null) return; // malformed/short frame — skip (T-05-03 / V5).

    final color = Color.fromARGB(255, sample.r, sample.g, sample.b);
    final hsv = HSVColor.fromColor(color);
    final h = hsv.hue; // 0..360
    final s = hsv.saturation; // 0..1
    final v = hsv.value; // 0..1

    final now = DateTime.now();
    final dtMs =
        _lastTick == null ? 0 : now.difference(_lastTick!).inMilliseconds;
    _lastTick = now;

    // Plan 01 pure helpers: add-on-match / reset-on-miss, complete at hold.
    _heldMs = accumulateColorHold(
      _heldMs,
      h,
      s,
      v,
      kColorPaletteHues[_targetIndex],
      dtMs,
    );
    final progress = (_heldMs / kColorHoldMs).clamp(0.0, 1.0);

    if (colorComplete(_heldMs)) {
      _finish();
      return;
    }

    if (!mounted) return;
    setState(() {
      _progress = progress;
      _liveColor = color;
    });
  }

  // Center-ROI RGB averager. Branches on the frame format: BGRA8888 (iOS) reads
  // one plane's B,G,R,A 4-byte pixels; YUV420 (Android) reads luma plane[0] +
  // chroma plane[1]/[2] honoring bytesPerRow (row stride) and bytesPerPixel
  // (uv pixel stride, usually 2 = semi-planar on CameraX) per RESEARCH Pattern
  // 1. All indices bounds-guarded; YUV→RGB clamped 0..255 (T-05-03 / V5).
  ({int r, int g, int b})? _sampleCenterRgb(CameraImage img) {
    final int w = img.width, hgt = img.height;
    if (w <= 0 || hgt <= 0) return null;
    final int x0 = (w * 0.4).round();
    final int x1 = (w * 0.6).round();
    final int y0 = (hgt * 0.4).round();
    final int y1 = (hgt * 0.6).round();

    // BGRA8888 path (iOS): single plane, 4 bytes/pixel in B,G,R,A order.
    if (img.format.group == ImageFormatGroup.bgra8888) {
      if (img.planes.isEmpty) return null;
      final p = img.planes[0];
      final bytes = p.bytes;
      if (bytes.isEmpty) return null;
      final rowStride = p.bytesPerRow;
      int rs = 0, gs = 0, bs = 0, n = 0;
      for (int y = y0; y < y1; y += 2) {
        final row = y * rowStride;
        for (int x = x0; x < x1; x += 2) {
          final i = row + x * 4;
          if (i + 2 >= bytes.length) continue;
          bs += bytes[i]; // B
          gs += bytes[i + 1]; // G
          rs += bytes[i + 2]; // R
          n++;
        }
      }
      if (n == 0) return null;
      return (r: (rs / n).round(), g: (gs / n).round(), b: (bs / n).round());
    }

    // YUV420 path (Android): 3 planes; chroma uses row + pixel stride.
    if (img.planes.length != 3) return null;
    final yP = img.planes[0], uP = img.planes[1], vP = img.planes[2];
    final yBytes = yP.bytes, uBytes = uP.bytes, vBytes = vP.bytes;
    if (yBytes.isEmpty || uBytes.isEmpty || vBytes.isEmpty) return null;
    final yRow = yP.bytesPerRow;
    final uvRow = uP.bytesPerRow;
    final uvPix = uP.bytesPerPixel ?? 1; // CameraX: usually 2 (semi-planar).
    int rs = 0, gs = 0, bs = 0, n = 0;
    for (int y = y0; y < y1; y += 2) {
      final yRowBase = y * yRow;
      final uvRowBase = (y >> 1) * uvRow;
      for (int x = x0; x < x1; x += 2) {
        final yIdx = yRowBase + x;
        final uvIdx = uvRowBase + (x >> 1) * uvPix;
        if (yIdx >= yBytes.length) continue;
        if (uvIdx >= uBytes.length || uvIdx >= vBytes.length) continue;
        // BT.601 full-range YUV→RGB (Y 0..255, U/V centered at 128).
        final yf = yBytes[yIdx].toDouble();
        final uf = uBytes[uvIdx] - 128.0;
        final vf = vBytes[uvIdx] - 128.0;
        final r = (yf + 1.402 * vf).clamp(0.0, 255.0);
        final g =
            (yf - 0.344136 * uf - 0.714136 * vf).clamp(0.0, 255.0);
        final b = (yf + 1.772 * uf).clamp(0.0, 255.0);
        rs += r.round();
        gs += g.round();
        bs += b.round();
        n++;
      }
    }
    if (n == 0) return null;
    return (r: (rs / n).round(), g: (gs / n).round(), b: (bs / n).round());
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
    // fired before the controller is torn down. (lumen_mission lines 235-248.)
    _retryTimer?.cancel();
    _slot.dispose();
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
    final targetHue = kColorPaletteHues[_targetIndex];
    final targetColor = HSVColor.fromAHSV(1, targetHue, 1, 1).toColor();
    final targetName = AppStrings.get(_kColorNameKeys[_targetIndex], lang);

    // D-06 headless: NO CameraPreview is mounted — the camera streams frames in
    // the background only. The indigo Scaffold is owned by RingScreen; this
    // view renders on a transparent background.
    return Container(
      color: Colors.transparent,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(24),
        // Reused translucent card decoration from lumen_mission / ring_screen.
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppStrings.get('mission_color_title', lang).toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.get('mission_color_guide', lang),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 22),
            ),
            const SizedBox(height: 20),
            // Slot-machine window: a scrolling vertical color strip that
            // decelerates to rest on the target. AnimatedBuilder so only the
            // strip rebuilds per animation frame (RESEARCH Pattern 3 — never
            // setState per frame); the live swatch/progress update via _onFrame.
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 120,
                height: _swatchHeight,
                child: AnimatedBuilder(
                  animation: _slot,
                  builder: (context, child) {
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Transform.translate(
                          offset: Offset(0, -_slotAnim.value % _swatchHeight -
                              _swatchHeight),
                          child: Column(
                            children: List.generate(
                              kColorPaletteHues.length + 2,
                              (i) {
                                final hue = kColorPaletteHues[
                                    i % kColorPaletteHues.length];
                                return Container(
                                  width: 120,
                                  height: _swatchHeight,
                                  color:
                                      HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Target + live sampled-color swatches side by side.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _swatch(
                  label: targetName,
                  color: targetColor,
                  lang: lang,
                ),
                const SizedBox(width: 24),
                _swatch(
                  label: AppStrings.get('mission_color_name', lang),
                  color: _liveColor ?? Colors.white12,
                  lang: lang,
                  isLive: true,
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Amber closeness progress bar — parallel to Lümen's bar.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 12,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$pct%',
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            // Near-done nudge: "HOLD STEADY!" as the bar fills.
            if (nearDone)
              Text(
                AppStrings.get('mission_color_hold', lang),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 16),
            // Prominent unlimited Reroll button (MIS-02 — no penalty).
            ElevatedButton.icon(
              onPressed: _spin,
              icon: const Icon(Icons.casino),
              label: Text(AppStrings.get('mission_color_reroll', lang)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
            // While the headless camera is still acquiring (notably over the
            // lock screen while the prior camera is still releasing), show a
            // "Starting Camera..." hint; once frames stream the bar/swatch are
            // the feedback.
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

  // A labeled square swatch (target or live sampled color).
  Widget _swatch({
    required String label,
    required Color color,
    required String lang,
    bool isLive = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white54, width: 2),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }
}
