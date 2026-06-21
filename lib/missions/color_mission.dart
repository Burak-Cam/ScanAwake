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
/// or BGRA8888 (iOS) → RGB → HSV instead of averaging luma. Unlike Lümen
/// (headless, point-at-light), this mission DOES mount a live [CameraPreview]
/// with a center ROI reticle — device testing showed a color task is unusable
/// without seeing what you aim at (SC-4 finding). Frames are still sampled
/// in-memory only, never stored/transmitted (offline app — T-05-04). Completion
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
  // The last few landed indices — a reroll avoids repeating them so the user
  // does not get the same color 2-3 spins in a row (device feedback).
  final List<int> _recentTargets = [];
  // True while the slot strip is scrolling. The slot is shown as a full-screen
  // overlay ONLY while spinning; once it lands we reveal the camera preview +
  // ROI reticle for the finding phase (so the target is not "spoiled" at rest
  // before the spin completes, and the user can SEE what they aim at).
  bool _spinning = false;

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
      duration: const Duration(milliseconds: 2400),
    );
    _slotAnim = const AlwaysStoppedAnimation<double>(0);
    // When the spin finishes, drop the slot overlay and reveal the camera +
    // reticle finding UI.
    _slot.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _spinning = false);
      }
    });
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
    // Pick a target that is NOT one of the last 2 landed colors (avoids 2-3
    // repeats in a row). With 6 hues and a 2-deep history there are always ≥4
    // candidates; the length guard is belt-and-suspenders against a loop.
    int newIndex;
    do {
      newIndex = Random().nextInt(kColorPaletteHues.length);
    } while (_recentTargets.contains(newIndex) &&
        _recentTargets.length < kColorPaletteHues.length);
    _recentTargets.add(newIndex);
    if (_recentTargets.length > 2) _recentTargets.removeAt(0);
    // Land so the target swatch sits in the center window after _cycles full
    // palette scrolls (deterministic via Tween + Curves.decelerate).
    final end =
        (_cycles * kColorPaletteHues.length + newIndex) * _swatchHeight;
    // easeOutQuart has a long slow tail so the strip visibly settles onto the
    // landed color instead of snapping to a stop (device feedback).
    _slotAnim = Tween<double>(begin: 0, end: end)
        .animate(CurvedAnimation(parent: _slot, curve: Curves.easeOutQuart));
    if (mounted) {
      setState(() {
        _targetIndex = newIndex;
        _heldMs = 0;
        _progress = 0;
        _spinning = true;
      });
    } else {
      _targetIndex = newIndex;
      _heldMs = 0;
      _progress = 0;
      _spinning = true;
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
      // ResolutionPreset.medium: low (~240p) looked too coarse as a USER-FACING
      // preview (device feedback); medium (~480p) is a clear preview while the
      // center-ROI subsample (step 2) keeps per-frame work cheap. enableAudio:false.
      final controller = CameraController(
        cam,
        ResolutionPreset.medium,
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
    // While the slot is still spinning the user cannot aim yet — do NOT
    // accumulate hold, and clear _lastTick so the FIRST frame after the spin
    // measures dt from "now" (a stale _lastTick would inject a huge dtMs that
    // could complete the bar in one frame on a coincidental match — the
    // "reroll made the bar fill by itself" device bug).
    if (_spinning) {
      _lastTick = null;
      return;
    }

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

    // Plan 01 pure helpers: add-on-match / leaky-decay-on-miss (D-09), complete at hold.
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
    // Swap the UI off the live preview IMMEDIATELY (before disposing the
    // controller), so the CameraPreview texture is unmounted and cannot flash
    // its last/stale buffer (a solid red/blue frame) during teardown while we
    // pop back to the home screen (device feedback). build() shows a neutral
    // success surface while _finished is true.
    if (mounted) {
      setState(() => _streaming = false);
    }
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

    // Completion surface: shown the instant the mission succeeds, while the
    // camera tears down and the host pops back. A neutral dark + check frame
    // prevents the disposing CameraPreview from flashing a stale solid-color
    // texture in this window (device feedback).
    if (_finished) {
      return Container(
        color: const Color(0xFF1A237E), // indigo — matches the mission stage
        alignment: Alignment.center,
        child: const Icon(Icons.check_circle, color: Colors.greenAccent, size: 96),
      );
    }

    final pct = (_progress * 100).round();
    final nearDone = _progress >= 0.75;
    final targetHue = kColorPaletteHues[_targetIndex];
    final targetColor = HSVColor.fromAHSV(1, targetHue, 1, 1).toColor();
    final targetName = AppStrings.get(_kColorNameKeys[_targetIndex], lang);

    // MIS-02 / SC-4 (device finding): unlike Lümen (headless, point-at-light),
    // a color task REQUIRES a live preview so the user can SEE what they aim at.
    // We mount a full-bleed CameraPreview with a center ROI reticle marking the
    // sampled region. The slot machine is shown as a full-screen overlay ONLY
    // while spinning; once it lands we reveal the finding UI. The camera streams
    // frames the whole time for sampling (preview + image stream share one
    // controller). Still offline — nothing stored/transmitted (T-05-04).
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Live camera preview (or acquiring hint).
        Positioned.fill(child: _cameraLayer(lang)),

        // 2. Center ROI reticle (the ~center region _sampleCenterRgb reads).
        //    Hidden during the spin so the slot overlay reads cleanly.
        if (!_spinning)
          Center(
            child: FractionallySizedBox(
              widthFactor: 0.34,
              heightFactor: 0.22,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: nearDone ? Colors.amber : Colors.white,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),

        // 3. Top overlay: title + guide + target swatch + live sampled swatch.
        if (!_spinning)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppStrings.get('mission_color_guide', lang),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _swatch(
                            label: targetName, color: targetColor, lang: lang),
                        const SizedBox(width: 24),
                        _swatch(
                          label: AppStrings.get('mission_color_name', lang),
                          color: _liveColor ?? Colors.white12,
                          lang: lang,
                          isLive: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

        // 4. Bottom overlay: progress bar + percent + reroll.
        if (!_spinning)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _progress,
                        minHeight: 12,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.amber),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      nearDone
                          ? '$pct% — ${AppStrings.get('mission_color_hold', lang)}'
                          : '$pct%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _spin,
                      icon: const Icon(Icons.casino),
                      label: Text(AppStrings.get('mission_color_reroll', lang)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // 5. Slot-machine overlay — shown ONLY while spinning.
        if (_spinning)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.85),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppStrings.get('mission_color_title', lang).toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Scrolling vertical color strip that decelerates and LANDS on
                  // the target swatch in the window (offset == _slotAnim.value;
                  // _spin tweens 0 → (cycles*len + targetIndex)*_swatchHeight, so
                  // at rest the window shows palette[targetIndex]). The strip is
                  // taller than the 1-swatch window — OverflowBox lets it exceed
                  // the box and ClipRRect clips it (no RenderFlex overflow).
                  // AnimatedBuilder so only the strip rebuilds per frame.
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 140,
                        height: _swatchHeight,
                        child: AnimatedBuilder(
                          animation: _slot,
                          builder: (context, child) {
                            return OverflowBox(
                              minHeight: 0,
                              maxHeight: double.infinity,
                              alignment: Alignment.topCenter,
                              child: Transform.translate(
                                offset: Offset(0, -_slotAnim.value),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: List.generate(
                                    (_cycles + 1) * kColorPaletteHues.length,
                                    (i) {
                                      final hue = kColorPaletteHues[
                                          i % kColorPaletteHues.length];
                                      return Container(
                                        width: 140,
                                        height: _swatchHeight,
                                        color: HSVColor.fromAHSV(1, hue, 1, 1)
                                            .toColor(),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // Full-bleed camera preview (BoxFit.cover), or a "Starting Camera..." hint
  // while the controller is still acquiring (notably over the lock screen while
  // the prior camera is still releasing). Preview + image-stream share one
  // controller, so mounting the preview does not disturb _onFrame sampling.
  Widget _cameraLayer(String lang) {
    final cam = _cam;
    if (!_streaming || cam == null || !cam.value.isInitialized) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Text(
          AppStrings.get('camera_starting', lang),
          style: const TextStyle(color: Colors.white54, fontSize: 16),
        ),
      );
    }
    final preview = cam.value.previewSize;
    if (preview == null) return CameraPreview(cam);
    // Preview is reported in sensor (landscape) orientation; swap W/H so cover
    // fills a portrait mission stage without distortion.
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: preview.height,
        height: preview.width,
        child: CameraPreview(cam),
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
