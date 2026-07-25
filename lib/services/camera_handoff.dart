import 'dart:async';

/// Serializes camera RELEASE -> ACQUIRE across the two plugins that share one
/// process-wide CameraX instance.
///
/// ## Why this exists
///
/// `camera_android_camerax` and `mobile_scanner` both bind to the SAME
/// process-singleton `ProcessCameraProvider`. That sharing already caused one
/// core-value bug (the AE-lock leak, [[camerax-process-sticky-settings]]); this
/// is its second face.
///
/// `camera_android_camerax-0.7.2/lib/src/android_camera_camerax.dart:529`:
///
/// ```dart
/// Future<void> dispose(int cameraId) async {
///   ...
///   await processCameraProvider?.unbindAll();   // EVERY use case in the process
/// ```
///
/// `unbindAll()` unbinds every use case bound to that singleton — including
/// `mobile_scanner`'s, which it does not own.
///
/// The camera missions must tear their controller down DETACHED (see PR #20 /
/// `mission-exit-teardown-crash`): a wedged camera teardown must never delay or
/// block the exit chain, and `State.dispose()` cannot await anyway. So the
/// teardown keeps running after the mission screen is gone. If the barcode
/// scanner acquires the camera while that teardown is still in flight, the
/// teardown's `unbindAll()` lands on the SCANNER's use cases:
///
///   camera closes cleanly -> no exception -> `MobileScanner.errorBuilder` never
///   fires -> `_scheduleAutoRetry()` never runs -> permanently black preview,
///   and the alarm cannot be dismissed.
///
/// Device evidence (2026-07-25 logcat): scanner camera opened at 20:20:59.967 and
/// closed cleanly 1.4 s later at 20:21:01.353 with no exception, then never
/// reopened for the remaining 7.5 minutes of the log.
///
/// ## The contract
///
/// Releasers call [trackRelease] instead of bare `unawaited(...)` — the exit
/// stays non-blocking, exactly as before. Acquirers call [awaitRelease] before
/// binding a new camera.
///
/// The wait is BOUNDED on purpose. A wedged teardown has been observed stalling
/// ~60 s (`mission-exit-teardown-crash`); blocking the dismiss scanner that long
/// would itself be a core-value failure — strictly worse than the race we are
/// closing. So we wait only [kMaxHandoffWait] and then proceed regardless.
class CameraHandoff {
  CameraHandoff._();

  /// Upper bound on how long an acquirer will wait for a pending release.
  ///
  /// Chosen to comfortably cover a healthy teardown (stopImageStream + dispose,
  /// tens of ms in practice) while staying far below the point where a user
  /// would perceive the barcode screen as broken. NOT device-calibrated — it is
  /// a bound, not a threshold: being wrong only costs a little latency, never
  /// correctness.
  static const Duration kMaxHandoffWait = Duration(milliseconds: 1200);

  static Future<void>? _pending;

  /// Visible for tests: is a release currently in flight?
  static bool get hasPendingRelease => _pending != null;

  /// Register a detached camera release. Never throws and never rethrows —
  /// callers rely on this being a drop-in for `unawaited(...)`.
  static void trackRelease(Future<void> release) {
    // Swallow here so the stored future can be awaited by acquirers without
    // turning a teardown failure into an acquirer failure.
    final Future<void> guarded = release.catchError((Object _) {});
    _pending = guarded;
    guarded.whenComplete(() {
      // Only clear if we are still the newest release; a later release must not
      // be erased by an older one finishing.
      if (identical(_pending, guarded)) _pending = null;
    });
  }

  /// Wait for any in-flight release to finish, bounded by [timeout].
  ///
  /// Returns normally in every case — on timeout it simply gives up waiting and
  /// lets the caller proceed. Safe to call when nothing is pending.
  static Future<void> awaitRelease({
    Duration timeout = kMaxHandoffWait,
  }) async {
    final Future<void>? pending = _pending;
    if (pending == null) return;
    try {
      await pending.timeout(timeout);
    } catch (_) {
      // Timed out (or the release failed) — proceeding is the lesser evil.
    }
  }

  /// Test-only: drop any tracked release so tests start from a clean slate.
  static void resetForTest() {
    _pending = null;
  }
}
