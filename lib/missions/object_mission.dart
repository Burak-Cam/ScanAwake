import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// google_mlkit_image_labeling re-exports all of google_mlkit_commons
// (InputImage / InputImageMetadata / InputImageRotation / InputImageFormat), so
// a single import covers both — importing commons directly trips the
// `unnecessary_import` lint. commons stays a DIRECT pubspec dependency (the
// flutter_fgbg precedent) so the package we rely on is declared, not just
// transitive.
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import 'mission.dart';

/// MIS-03: the fourth concrete [Mission] — "Nesne Bul" (Find the Object). On open
/// a random target household item is picked from [kObjectTargets]; the user must
/// physically show that object to the camera and HOLD it for [kObjectHoldMs] (a
/// single non-matching throttled tick resets progress — sustained, not
/// cumulative, mirroring Lümen/Renk's D-02 discipline). An unlimited "Başka
/// Nesne" reroll re-picks with no penalty.
///
/// The camera lifecycle is a VERBATIM clone of [ColorMission] (Phase 5,
/// device-hardened on the Redmi Note 9S: postFrame+450ms acquire, 6-step backoff
/// retry for the single-camera release race, full teardown-before-onSuccess,
/// live [CameraPreview]). The ONLY material differences are:
///   1. the [CameraController] is created with `imageFormatGroup`
///      `nv21` (Android) / `bgra8888` (iOS) so ML Kit gets a SINGLE plane
///      (RESEARCH Pitfall 1 — load-bearing; default yuv420 yields 3 planes and
///      the single-plane recipe returns null → labels never appear), and
///   2. the per-frame work converts the [CameraImage] to an ML Kit [InputImage]
///      and runs a THROTTLED ([kObjectThrottleMs], `_isBusy` re-entry guard)
///      [ImageLabeler.processImage] instead of HSV-sampling a center ROI; the
///      resulting labels feed the SAME [accumulateObjectHold] / [objectComplete]
///      pure-helper pattern via [hasMatch].
///
/// Frames are sampled in-memory only, never stored/transmitted (offline bundled
/// model — T-06-04). The whole per-frame ML body is wrapped in try/catch so a
/// malformed frame / native exception never crashes the dismiss (T-06-03 / V5).
/// The native labeler is closed on BOTH exit paths (_finish AND dispose) so it
/// never leaks the native detector (T-06-05). Completion fires the [onSuccess]
/// callback supplied by the hosting RingScreen — no new RingResult variant.
class ObjectMission implements Mission {
  /// The user's language ('tr'/'en') so the mission UI localizes via
  /// [AppStrings]. Passed in by the caller (RingScreen).
  final String language;

  const ObjectMission({required this.language});

  @override
  String get title => AppStrings.get('mission_object_title', language);

  @override
  Widget build(BuildContext context, VoidCallback onSuccess) =>
      _ObjectView(language: language, onSuccess: onSuccess);
}

/// The internal StatefulWidget host that owns the camera lifecycle + ML Kit
/// labeler + target/progress UI. Split out so [ObjectMission] stays a thin,
/// const-constructible contract impl and all mutable state lives here.
class _ObjectView extends StatefulWidget {
  final String language;
  final VoidCallback onSuccess;
  const _ObjectView({required this.language, required this.onSuccess});

  @override
  State<_ObjectView> createState() => _ObjectViewState();
}

/// RESEARCH Pattern 1: device-orientation → degrees, for the Android rotation
/// compensation in [_inputImageFromCameraImage].
const Map<DeviceOrientation, int> _kOrientations = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

class _ObjectViewState extends State<_ObjectView> with WidgetsBindingObserver {
  // Created lazily in a postFrameCallback (NOT a field initializer). On the
  // single-camera MIUI device (Redmi Note 9S, "Max allowed cameras: 1") the
  // prior screen's mobile_scanner camera releases the native camera
  // ASYNCHRONOUSLY/UNAWAITED on dispose. Acquiring a new controller
  // synchronously in build races that teardown and fails to acquire (silent
  // black). Deferring to after the first frame gives the prior camera a moment
  // to release; the backoff auto-retry below self-heals any remaining transient
  // acquire failure. (color_mission analog.)
  CameraController? _cam;
  // The chosen CameraDescription — _inputImageFromCameraImage needs its
  // sensorOrientation + lensDirection for the rotation math (RESEARCH Pattern 1).
  CameraDescription? _camDesc;
  bool _streaming = false;

  // Sustained-hold bookkeeping (Plan 01 helpers). dt is measured between
  // THROTTLED ticks (not raw frames) so the hold cadence tracks the throttle.
  int _heldMs = 0;
  DateTime? _lastTick;
  double _progress = 0; // 0..1
  bool _finished = false; // re-entry guard on completion

  // ML Kit throttle (RESEARCH Pattern 2): _isBusy is the async re-entry guard
  // (skip while a processImage future is in flight); _lastInfer is the cadence
  // gate against kObjectThrottleMs.
  bool _isBusy = false;
  DateTime _lastInfer = DateTime.fromMillisecondsSinceEpoch(0);

  // The native ML Kit labeler. Created ASYNCHRONOUSLY in _initLabeler() (the
  // bundled .tflite asset must first be copied to a file path for
  // LocalLabelerOptions(modelPath:)), so it is NULLABLE — _onFrame skips until it
  // is ready. Closed in BOTH _finish and dispose (RESEARCH Pitfall 5 — a leaked
  // native detector blocks the next camera open on the single-camera device).
  ImageLabeler? _imageLabeler;

  // Live-feedback readout: the single best (top-confidence) label of the most
  // recent inference, for the "Algılanan: <label> NN%" line.
  String? _bestLabel;
  double? _bestConfidence;
  // The GROUPED (summed) confidence of all detected labels that belong to the
  // CURRENT target's accepted set — this is the value hasMatch actually uses, so
  // the user sees the grouped score (e.g. cup 0.40 + coffee mug 0.30 = "Bardak
  // 70%") rather than the misleadingly-low individual labels (device feedback).
  double _targetSum = 0;

  // Auto-retry backoff for transient camera-acquire failures (release race on
  // the single-camera device). Mirrors color_mission lines 89-91 / 237-259.
  int _retryCount = 0;
  static const int _maxRetries = 6;
  Timer? _retryTimer;

  // MIS-03: the random target key (a key of kObjectTargets, e.g. 'cup'). Picked
  // by _spin() on open + on every reroll.
  late String _targetKey;
  // The last few picked keys — a reroll avoids repeating them so the user does
  // not get the same target 2-3 spins in a row (color_mission _recentTargets).
  final List<String> _recentTargets = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // CUSTOM LOCAL MODEL (Phase 6 pivot): the default ML Kit model is too coarse
    // for household items (fork→"Wheel", banana→"Insect" on the device), so we
    // ship a bundled metadata-embedded ImageNet TFLite classifier and load it via
    // LocalLabelerOptions. Asset→file copy is async → labeler is created in
    // _initLabeler(). Native confidenceThreshold kept LOW (0.05) so the SC-4 debug
    // readout sees near-misses; the real floor (kObjectConfidence) is re-checked
    // in hasMatch (single-sourced + device-calibratable in app_constants).
    _initLabeler();
    // Pick the first target immediately (CONTEXT decision — user sees a target on
    // open). Resets _heldMs/_progress.
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

  // Phase 6 pivot: copy the bundled .tflite asset to an app-support file ONCE
  // (LocalLabelerOptions needs an absolute file path, not an asset path), then
  // create the local-model labeler. Best-effort: on any failure the labeler stays
  // null and _onFrame simply never matches (the alarm keeps ringing — core value
  // preserved, never crashes).
  Future<String> _copyAssetModel() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/object_labeler.tflite');
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/ml/object_labeler.tflite');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  }

  Future<void> _initLabeler() async {
    try {
      final path = await _copyAssetModel();
      if (!mounted) return;
      _imageLabeler = ImageLabeler(
        options: LocalLabelerOptions(
          confidenceThreshold: 0.05,
          modelPath: path,
          maxCount: 5,
        ),
      );
    } catch (_) {
      // Labeler stays null; _onFrame guards on it. Mission can't complete, but
      // the alarm keeps ringing and the emergency stop remains reachable.
    }
  }

  // MIS-03: pick a new random target, avoiding the last 2 picked keys (so the
  // user does not get the same object 2-3 rerolls in a row). Resets _heldMs so a
  // reroll mid-hold carries NO progress penalty (unlimited, no-penalty reroll).
  void _spin() {
    final keys = kObjectTargets.keys.toList();
    String newKey;
    do {
      newKey = keys[Random().nextInt(keys.length)];
    } while (_recentTargets.contains(newKey) &&
        _recentTargets.length < keys.length);
    _recentTargets.add(newKey);
    if (_recentTargets.length > 2) _recentTargets.removeAt(0);
    if (mounted) {
      setState(() {
        _targetKey = newKey;
        _heldMs = 0;
        _progress = 0;
        _lastTick = null;
        _bestLabel = null;
        _bestConfidence = null;
        _targetSum = 0;
      });
    } else {
      _targetKey = newKey;
      _heldMs = 0;
      _progress = 0;
      _lastTick = null;
    }
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
      // RESEARCH Pitfall 1 (LOAD-BEARING): ML Kit needs a SINGLE-plane image.
      // Build the controller with nv21 (Android) / bgra8888 (iOS) — ColorMission
      // uses the default 3-plane yuv420 for HSV, which the single-plane InputImage
      // recipe cannot consume (labels would never appear). enableAudio:false.
      // ResolutionPreset.high (~720p): the labeler recognizes better with a
      // sharper frame than medium/480p (device feedback — low res hurt
      // recognition). The ~400ms throttle keeps the heavier NV21 conversion off
      // the jank path. enableAudio:false.
      final controller = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _cam = controller;
      _camDesc = cam;
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
  // giving up. (color_mission analog, lines 237-259.)
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

  // MIS-03 THE NEW WORK (RESEARCH Pattern 2): throttled ML Kit labeling. KEEP the
  // ColorMission spin-guard preamble verbatim (prevents the reroll false-fill
  // bug), then gate on _isBusy (async re-entry) + kObjectThrottleMs (cadence),
  // convert the frame to an InputImage, run processImage, and feed the matched
  // labels into the SAME sustained-hold skeleton as Lümen/Renk. The whole ML body
  // is wrapped in try/catch with `finally { _isBusy = false; }` so a malformed
  // frame / native hiccup never crashes the dismiss (T-06-03 / Pitfall 6).
  Future<void> _onFrame(CameraImage img) async {
    if (_finished || !mounted) return;
    // While we are between reroll picks the user cannot aim yet (mirrors the
    // ColorMission _spinning guard); _spin() already clears _lastTick so the
    // FIRST throttled tick after a reroll measures dt from "now" (a stale
    // _lastTick would inject a huge dtMs that could complete the bar in one tick).
    if (_isBusy) return; // a processImage is still in flight
    final now = DateTime.now();
    if (now.difference(_lastInfer).inMilliseconds < kObjectThrottleMs) return;
    _isBusy = true;
    _lastInfer = now;
    try {
      final cam = _cam;
      final desc = _camDesc;
      final labeler = _imageLabeler;
      if (cam == null || desc == null || labeler == null) return;
      final input = _inputImageFromCameraImage(img, desc, cam);
      if (input == null) return; // malformed/non-single-plane frame — skip.
      final labels = await labeler.processImage(input);
      // The processImage await can outlive teardown — re-check before touching
      // state (the in-flight result is dropped after _finish/dispose).
      if (_finished || !mounted) return;

      final matched = hasMatch(
        labels.map((l) => (l.label, l.confidence)).toList(),
        kObjectTargets[_targetKey]!,
        kObjectConfidence,
      );
      // dt measured between THROTTLED ticks (not raw frames).
      final dtMs =
          _lastTick == null ? 0 : now.difference(_lastTick!).inMilliseconds;
      _lastTick = now;
      _heldMs = accumulateObjectHold(_heldMs, matched, dtMs);

      if (objectComplete(_heldMs)) {
        _finish();
        return;
      }

      // GROUPED confidence for the current target — the same sum hasMatch uses
      // (concept aggregation), surfaced to the UI so the grouping is VISIBLE.
      final acc = kObjectTargets[_targetKey]!.map((e) => e.toLowerCase()).toSet();
      double targetSum = 0;
      for (final l in labels) {
        if (acc.contains(l.label.toLowerCase())) targetSum += l.confidence;
      }
      // Live feedback: the single top raw label (informational secondary line).
      final sorted = labels.toList()
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      final best = sorted.isEmpty ? null : sorted.first;

      if (!mounted) return;
      setState(() {
        _progress = (_heldMs / kObjectHoldMs).clamp(0.0, 1.0);
        _bestLabel = best?.label;
        _bestConfidence = best?.confidence;
        _targetSum = targetSum.clamp(0.0, 1.0);
      });
    } catch (_) {
      // malformed frame / native ML Kit exception — skip this tick. The dismiss
      // must NEVER crash (T-06-03 / Pitfall 6).
    } finally {
      _isBusy = false;
    }
  }

  // RESEARCH Pattern 1: convert a camera-plugin CameraImage to an ML Kit
  // InputImage with correct rotation + format metadata. The CameraController was
  // built with nv21 (Android) / bgra8888 (iOS) so the stream delivers a SINGLE
  // plane. Returns null for any frame that is not single-plane or whose rotation
  // cannot be resolved (skipped upstream — never crashes the dismiss).
  InputImage? _inputImageFromCameraImage(
      CameraImage image, CameraDescription cam, CameraController controller) {
    final sensorOrientation = cam.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _kOrientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (cam.lensDirection == CameraLensDirection.front) {
        // front-facing: counter-clockwise
        rotationCompensation =
            (sensorOrientation + rotationCompensation) % 360;
      } else {
        // back-facing: clockwise
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    // Guard the expected single-plane format per platform (nv21 / bgra8888).
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    // nv21 / bgra8888 deliver a single plane; the recipe reads only that plane.
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used on Android
        format: format, // used on iOS
        bytesPerRow: plane.bytesPerRow, // used on iOS
      ),
    );
  }

  // Completion: tear the camera DOWN FULLY (stopImageStream + dispose) AND close
  // the native labeler BEFORE invoking onSuccess, so the single-camera device
  // frees the lens + the native detector for whatever the host screen does next.
  // Re-entry guarded.
  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    // Swap the UI off the live preview IMMEDIATELY (before disposing the
    // controller), so the CameraPreview texture is unmounted and cannot flash a
    // stale buffer during teardown while we pop back to the home screen.
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
      try {
        await cam.dispose();
      } catch (_) {}
    }
    // Release the native ML Kit detector (RESEARCH Pitfall 5 — close on BOTH exit
    // paths; a leaked labeler blocks the next camera/model open).
    try {
      await _imageLabeler?.close();
    } catch (_) {}
    if (!mounted) return;
    // Camera + labeler fully torn down — safe to hand control back to the host.
    widget.onSuccess();
  }

  @override
  void dispose() {
    // MIUI single-camera discipline: stop the stream FIRST (shortens the native
    // release window so the next camera open is less likely to race teardown),
    // THEN dispose. dispose() cannot be async, so these are best-effort but fired
    // before the controller is torn down. (color_mission lines 421-435.)
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final cam = _cam;
    _cam = null;
    cam?.stopImageStream();
    cam?.dispose();
    // Close the native labeler on the mid-mission unmount path too (Pitfall 5).
    _imageLabeler?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language;

    // Completion surface: shown the instant the mission succeeds, while the
    // camera tears down and the host pops back. A neutral dark + check frame
    // prevents the disposing CameraPreview from flashing a stale texture.
    if (_finished) {
      return Container(
        color: const Color(0xFF1A237E), // indigo — matches the mission stage
        alignment: Alignment.center,
        child: const Icon(Icons.check_circle,
            color: Colors.greenAccent, size: 96),
      );
    }

    final pct = (_progress * 100).round();
    final nearDone = _progress >= 0.75;
    final targetName = AppStrings.get('object_$_targetKey', lang);
    // "Algılanan: <bestLabel> NN%" live readout (parallels ColorMission's live
    // swatch). When nothing has been detected yet, show an em-dash.
    final detectedLabel = _bestLabel ?? '—';
    final detectedPct =
        _bestConfidence == null ? '' : ' ${(_bestConfidence! * 100).round()}%';
    // GROUPED match score for the current target (the value the bar uses).
    final targetMatchPct = (_targetSum * 100).round();

    // MIS-03: a live preview is REQUIRED so the user can SEE what they aim at
    // (Renk SC-4 finding). Full-bleed CameraPreview + target text/icon + a live
    // "detected" readout + amber progress bar + "Başka Nesne" reroll. Still
    // offline — nothing stored/transmitted (T-06-04).
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Live camera preview (or acquiring hint).
        Positioned.fill(child: _cameraLayer(lang)),

        // 2. Top overlay: guide + target name/icon + live detected readout.
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
                  // "ŞUNU GÖSTER:" + the localized target name.
                  Text(
                    AppStrings.get('mission_object_guide', lang),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.category,
                          color: Colors.amber, size: 32),
                      const SizedBox(width: 12),
                      Text(
                        targetName.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // GROUPED match: the summed confidence of every label that maps
                  // to this target — what the progress bar actually uses, so the
                  // user sees "Bardak %70" not a misleadingly-low single label.
                  Text(
                    '$targetName: %$targetMatchPct',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Secondary: the single top raw label (informational).
                  Text(
                    '${AppStrings.get('mission_object_detected', lang)} '
                    '$detectedLabel$detectedPct',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 3. Bottom overlay: progress bar + percent + reroll.
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
                        ? '$pct% — ${AppStrings.get('mission_object_hold', lang)}'
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
                    label:
                        Text(AppStrings.get('mission_object_reroll', lang)),
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
      ],
    );
  }

  // Full-bleed camera preview (BoxFit.cover), or a "Starting Camera..." hint
  // while the controller is still acquiring (notably over the lock screen while
  // the prior camera is still releasing). Preview + image-stream share one
  // controller, so mounting the preview does not disturb _onFrame inference.
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
}
