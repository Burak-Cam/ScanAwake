import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import 'mission.dart';

/// MIS-04: the fifth and final concrete [Mission] — "Su Sesi" (Water Sound). The
/// user must run a real water source (faucet/shower) near the phone mic; the
/// sound is classified ON-DEVICE by a bundled YAMNet `.tflite` (offline, no
/// network — T-07-04) and the mission completes once "running water" is detected
/// for [kWaterHoldMs] of SUSTAINED hold (a single non-matching throttled tick
/// resets progress — D-09, mirroring every other mission's discipline).
///
/// This is a near-clone of [ObjectMission] (Phase 6) with exactly two material
/// swaps:
///   1. the `record` PCM16 MIC STREAM replaces the camera image stream, and
///   2. a raw [Interpreter] over YAMNet replaces ML Kit's `ImageLabeler`.
/// Everything else copies verbatim: the `_isBusy` + throttle re-entry guard, the
/// per-tick try/catch/finally "dismiss never crashes" envelope, the sustained-
/// hold pure helpers ([accumulateWaterHold] / [waterComplete]), the GROUPED-sum
/// match ([waterGroupedScore] over [kWaterClassIndices]), and the two-path
/// teardown (the mic + interpreter are released on BOTH `_finish` AND `dispose`).
///
/// Audio stays in an in-memory sliding [Float32List] ONLY — never written to disk
/// or transmitted (T-07-04). The whole per-tick inference body is wrapped in
/// try/catch so a malformed chunk / native TFLite exception never crashes the
/// dismiss (T-07-05 / Pitfall 6). When mic permission is missing at task time the
/// mission shows an İzin Ver/Ayarlar gate and the alarm KEEPS RINGING — there is
/// NO permission-denied easy-dismiss (T-07-07 / D-08). Completion fires the
/// [onSuccess] callback supplied by the hosting RingScreen — no new RingResult.
class WaterMission implements Mission {
  /// The user's language ('tr'/'en') so the mission UI localizes via
  /// [AppStrings]. Passed in by the caller (RingScreen).
  final String language;

  const WaterMission({required this.language});

  @override
  String get title => AppStrings.get('mission_water_title', language);

  @override
  Widget build(BuildContext context, VoidCallback onSuccess) =>
      _WaterView(language: language, onSuccess: onSuccess);
}

/// The internal StatefulWidget host that owns the mic lifecycle + YAMNet
/// interpreter + listening/progress UI. Split out so [WaterMission] stays a thin,
/// const-constructible contract impl and all mutable state lives here.
class _WaterView extends StatefulWidget {
  final String language;
  final VoidCallback onSuccess;
  const _WaterView({required this.language, required this.onSuccess});

  @override
  State<_WaterView> createState() => _WaterViewState();
}

/// YAMNet classification `.tflite` takes a FIXED input of 15600 float32 samples
/// (~0.975s @ 16kHz). TFLite does not support dynamic input, so the mic chunks
/// (variable size) are accumulated into a sliding buffer and inference only runs
/// once 15600 samples are filled (Pitfall 4).
const int _kYamnetSamples = 15600;

class _WaterViewState extends State<_WaterView>
    with SingleTickerProviderStateMixin {
  // Sustained-hold bookkeeping (Plan 01 helpers). dt is measured between
  // THROTTLED ticks (not raw chunks) so the hold cadence tracks the throttle.
  int _heldMs = 0;
  DateTime? _lastTick;
  double _progress = 0; // 0..1
  bool _finished = false; // re-entry guard on completion

  // YAMNet throttle (RESEARCH Pattern 2): _isBusy is the async re-entry guard
  // (skip while a run is conceptually in flight / a chunk is being processed);
  // _lastInfer is the cadence gate against kWaterThrottleMs.
  bool _isBusy = false;
  DateTime _lastInfer = DateTime.fromMillisecondsSinceEpoch(0);

  // The native TFLite interpreter over the bundled YAMNet model. Created
  // ASYNCHRONOUSLY in _loadModel() so it is NULLABLE — _onAudioChunk skips until
  // it is ready. Closed in BOTH _finish and dispose (Anti-Pattern: one-path
  // teardown leaks the native interpreter).
  Interpreter? _interpreter;

  // The mic recorder + its PCM16 stream subscription. The recorder is stopped +
  // disposed and the subscription cancelled on BOTH exit paths (two-path
  // teardown) so the mic is never left busy.
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  // Sliding waveform buffer of the last 15600 float32 samples ([-1,1]). _filled
  // tracks how many valid samples are present (the fixed-input guard waits for
  // 15600 before the first run).
  final Float32List _waveform = Float32List(_kYamnetSamples);
  int _filled = 0;

  // D-08: set true if the mic permission is denied at task time → the gate UI is
  // shown and the mic is NOT opened (the alarm keeps ringing, no bypass).
  bool _needsPermission = false;

  // Live-feedback readout: the grouped water score (0..100%) of the most recent
  // inference, for the "Su algılandı %X" line.
  int _groupedPct = 0;

  // D-10: drives the detection-reactive ripple animation (0..1) — gives the
  // "listening" feel without a camera preview.
  double _rippleLevel = 0;

  // D-10: a continuous animation controller for the idle/listening ripple. The
  // ripple radius is modulated by _rippleLevel (stronger water → bigger ripple).
  late final AnimationController _rippleCtrl;

  @override
  void initState() {
    super.initState();
    _rippleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    // Best-effort model + class-map load (async). The interpreter stays null on
    // failure → _onAudioChunk simply never matches (the alarm keeps ringing —
    // core value preserved, never crashes).
    _loadModel();
    // Re-check the mic permission and open the stream (D-08). Deferred to after
    // the first frame so the gate UI can render if permission is denied.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initMic();
    });
  }

  // Best-effort: load the bundled YAMNet model directly from the asset path
  // (tflite_flutter accepts an asset path — no asset→file copy needed, unlike ML
  // Kit's LocalLabelerOptions). On any failure the interpreter stays null and
  // _onAudioChunk never runs inference (the alarm keeps ringing).
  Future<void> _loadModel() async {
    try {
      final interp = await Interpreter.fromAsset('assets/ml/yamnet.tflite');
      if (!mounted) {
        interp.close();
        return;
      }
      _interpreter = interp;
    } catch (_) {
      // Interpreter stays null; _onAudioChunk guards on it. Mission can't
      // complete, but the alarm keeps ringing and emergency stop stays reachable.
    }
  }

  // D-08: re-check the mic permission (it may have been revoked since the up-front
  // home-screen request), then open the PCM16 mic stream. If denied, show the
  // İzin Ver/Ayarlar gate and DO NOT open the mic (the alarm keeps ringing).
  Future<void> _initMic() async {
    try {
      final granted = await Permission.microphone.isGranted;
      if (!granted) {
        if (mounted) setState(() => _needsPermission = true);
        return; // mic NOT opened; no bypass (D-08 / T-07-07)
      }
      if (mounted) setState(() => _needsPermission = false);
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000, // YAMNet's 16kHz mono — no resample needed
          numChannels: 1,
          echoCancel: true, // SC-4 alarm-bleed mitigation (device-dependent)
          noiseSuppress: true,
          androidConfig: AndroidRecordConfig(
            // Least music-style processing; some OEMs apply AEC here (SC-4).
            audioSource: AndroidAudioSource.voiceRecognition,
          ),
        ),
      );
      if (!mounted) {
        await _recorder.stop();
        return;
      }
      _sub = stream.listen(_onAudioChunk, onError: (_) {});
    } catch (_) {
      // Mic could not open — best-effort. The mission can't complete but the
      // alarm keeps ringing and emergency stop stays reachable.
    }
  }

  // PCM16 LE bytes → float32 [-1,1], appended to the sliding waveform buffer.
  // Once full, oldest samples are dropped as new ones arrive (sliding window).
  void _appendPcm(Uint8List bytes) {
    // `record` can deliver chunks whose offsetInBytes is odd; asInt16List requires
    // a 2-byte-aligned offset (else RangeError). Copy to a fresh offset-0 buffer to
    // guarantee alignment, then decode little-endian PCM16 → float [-1, 1].
    final aligned = Uint8List.fromList(bytes);
    final i16 = aligned.buffer.asInt16List(0, aligned.lengthInBytes ~/ 2);
    for (final s in i16) {
      if (_filled < _kYamnetSamples) {
        _waveform[_filled++] = s / 32768.0;
      } else {
        // slide: drop oldest, append newest. Cheap for our chunk sizes.
        _waveform.setRange(0, _kYamnetSamples - 1, _waveform, 1);
        _waveform[_kYamnetSamples - 1] = s / 32768.0;
      }
    }
  }

  // MIS-04 THE NEW WORK (RESEARCH Pattern 2): throttled YAMNet inference. The
  // gate/guard/finally envelope is IDENTICAL to object_mission's _onFrame; only
  // the camera-frame middle is swapped for the PCM→buffer→YAMNet run. The whole
  // body is wrapped in try/catch with `finally { _isBusy = false; }` so a
  // malformed chunk / native hiccup never crashes the dismiss (T-07-05 / Pitfall 6).
  Future<void> _onAudioChunk(Uint8List bytes) async {
    if (_finished || !mounted) return;
    // Always accumulate (cheap) so the buffer keeps filling even between throttled
    // inferences.
    _appendPcm(bytes);
    if (_filled < _kYamnetSamples) return; // not yet 0.975s of audio
    if (_isBusy) return; // an inference is still in flight
    final now = DateTime.now();
    if (now.difference(_lastInfer).inMilliseconds < kWaterThrottleMs) return;
    _isBusy = true;
    _lastInfer = now;
    try {
      final interp = _interpreter;
      if (interp == null) return; // model not loaded / load failed
      // Model input tensor is rank-1 [15600] (verified on-device); feed the flat
      // waveform directly so tflite_flutter does NOT resize it to [1, 15600].
      final output = List.filled(1 * 521, 0.0).reshape([1, 521]);
      interp.run(_waveform, output); // synchronous native invoke
      // The run can outlive teardown — re-check before touching state.
      if (_finished || !mounted) return;

      final scores = (output[0] as List).cast<double>();
      final grouped = waterGroupedScore(scores, kWaterClassIndices);
      final matched = grouped >= kWaterConfidence;
      // dt measured between THROTTLED ticks (not raw chunks).
      final dtMs =
          _lastTick == null ? 0 : now.difference(_lastTick!).inMilliseconds;
      _lastTick = now;
      _heldMs = accumulateWaterHold(_heldMs, matched, dtMs);

      if (waterComplete(_heldMs)) {
        _finish();
        return;
      }

      if (!mounted) return;
      setState(() {
        _progress = (_heldMs / kWaterHoldMs).clamp(0.0, 1.0);
        _groupedPct = (grouped * 100).clamp(0, 100).round();
        _rippleLevel = grouped.clamp(0.0, 1.0);
      });
    } catch (_) {
      // malformed chunk / native TFLite exception — skip this tick. The dismiss
      // must NEVER crash (T-07-05 / Pitfall 6).
    } finally {
      _isBusy = false;
    }
  }

  // Completion: tear the mic DOWN FULLY (cancel sub + stop + dispose) AND close
  // the native interpreter BEFORE invoking onSuccess. Re-entry guarded.
  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    // Stop the mic FIRST (close the capture window), then release the interpreter.
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
    // Release the native interpreter on BOTH exit paths (Anti-Pattern: one-path
    // teardown leaks the native interpreter).
    try {
      _interpreter?.close();
    } catch (_) {}
    _interpreter = null;
    if (!mounted) return;
    // Mic + interpreter fully torn down — safe to hand control back to the host.
    widget.onSuccess();
  }

  @override
  void dispose() {
    // Two-path teardown: a mid-mission unmount also tears everything down. dispose
    // cannot be async, so these are best-effort but fired before super.dispose().
    _rippleCtrl.dispose();
    _sub?.cancel();
    _sub = null;
    _recorder.stop();
    _recorder.dispose();
    _interpreter?.close();
    _interpreter = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language;

    // Completion surface: shown the instant the mission succeeds, while the mic
    // tears down and the host pops back. Matches object_mission's indigo Stage-2.
    if (_finished) {
      return Container(
        color: const Color(0xFF1A237E), // indigo — matches the mission stage
        alignment: Alignment.center,
        child: const Icon(Icons.check_circle,
            color: Colors.greenAccent, size: 96),
      );
    }

    // D-08: the permission gate — shown when the mic permission is denied at task
    // time. The alarm keeps ringing; the user must grant or open settings. There
    // is NO bypass (the mission cannot complete without the mic).
    if (_needsPermission) {
      return _permissionGate(lang);
    }

    final pct = (_progress * 100).round();
    final nearDone = _progress >= 0.75;

    // Indigo Stage-2 surface (04-UI-SPEC). No camera preview — the D-10 ripple
    // animation gives the "listening" feel. Still offline (T-07-04).
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. The detection-reactive ripple background (D-10).
        Positioned.fill(child: _rippleLayer()),

        // 2. Top overlay: guide + the "su algılandı %X" / "Dinleniyor..." readout.
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
                    AppStrings.get('mission_water_title', lang).toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.get('mission_water_guide', lang),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Grouped water score (the value the bar uses) or "Dinleniyor..."
                  // when nothing is detected yet.
                  Text(
                    _groupedPct > 0
                        ? '${AppStrings.get('mission_water_detected', lang)} %$_groupedPct'
                        : AppStrings.get('mission_water_listening', lang),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 3. Bottom overlay: amber 12px progress bar + percent.
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
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.amber),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    nearDone
                        ? '$pct% — ${AppStrings.get('mission_water_hold', lang)}'
                        : '$pct%',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
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

  // D-10: the detection-reactive ripple/wave background. A set of expanding
  // concentric circles whose amplitude scales with _rippleLevel (stronger water →
  // livelier ripples). Replaces the camera preview (no analog — preview is
  // camera-only).
  Widget _rippleLayer() {
    return Container(
      color: const Color(0xFF1A237E), // indigo Stage-2 surface
      child: AnimatedBuilder(
        animation: _rippleCtrl,
        builder: (context, _) {
          return CustomPaint(
            painter: _RipplePainter(
              progress: _rippleCtrl.value,
              level: _rippleLevel,
            ),
            child: const Center(
              child: Icon(Icons.water_drop, color: Colors.white24, size: 96),
            ),
          );
        },
      ),
    );
  }

  // D-08: the permission-denied gate. Alarm keeps ringing; the user grants the
  // mic permission or opens app settings. Re-tries _initMic on grant.
  Widget _permissionGate(String lang) {
    return Container(
      color: const Color(0xFF1A237E),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic_off, color: Colors.amber, size: 72),
          const SizedBox(height: 16),
          Text(
            AppStrings.get('water_permission_title', lang),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () async {
                  final status = await Permission.microphone.request();
                  if (!mounted) return;
                  if (status.isGranted) {
                    setState(() => _needsPermission = false);
                    await _initMic();
                  }
                },
                icon: const Icon(Icons.mic),
                label: Text(AppStrings.get('water_permission_grant', lang)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings, color: Colors.white),
                label: Text(
                  AppStrings.get('water_permission_settings', lang),
                  style: const TextStyle(color: Colors.white),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

/// D-10: paints expanding concentric "ripple" rings whose opacity/spread scale
/// with the detection [level] (0..1). [progress] is the 0..1 animation phase.
class _RipplePainter extends CustomPainter {
  final double progress;
  final double level;
  const _RipplePainter({required this.progress, required this.level});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide / 2;
    // A baseline gentle idle ripple plus extra liveliness when water is detected.
    final intensity = (0.25 + 0.75 * level).clamp(0.0, 1.0);
    const rings = 3;
    for (var i = 0; i < rings; i++) {
      final phase = (progress + i / rings) % 1.0;
      final radius = maxRadius * phase;
      final opacity = (1.0 - phase) * intensity * 0.5;
      if (opacity <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + 2 * level
        ..color = Colors.amber.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) =>
      old.progress != progress || old.level != level;
}
