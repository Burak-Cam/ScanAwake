import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/camera_handoff.dart';

/// Guards the release -> acquire serialization that closes the "silent camera
/// death" defect: a mission's DETACHED camera teardown ends in
/// processCameraProvider.unbindAll(), which unbinds every use case in the
/// process — including a barcode scanner that bound in the meantime. The
/// scanner then dies with no exception, so errorBuilder (and therefore
/// _scheduleAutoRetry) never fires and the alarm cannot be dismissed.
void main() {
  setUp(CameraHandoff.resetForTest);
  tearDown(CameraHandoff.resetForTest);

  group('CameraHandoff.awaitRelease (serializes camera handoff)', () {
    test('returns immediately when no release is pending', () async {
      expect(CameraHandoff.hasPendingRelease, isFalse);
      // Must not hang: a fresh scanner with no prior mission binds at once.
      await CameraHandoff.awaitRelease().timeout(const Duration(seconds: 1));
    });

    test('waits for an in-flight release before letting the acquirer proceed',
        () async {
      final completer = Completer<void>();
      var released = false;

      CameraHandoff.trackRelease(
        completer.future.whenComplete(() => released = true),
      );
      expect(CameraHandoff.hasPendingRelease, isTrue);

      var acquired = false;
      final acquire = CameraHandoff.awaitRelease().then((_) => acquired = true);

      // Give the microtask queue a chance: the acquirer must still be blocked.
      await Future<void>.delayed(Duration.zero);
      expect(acquired, isFalse,
          reason: 'acquirer bound while the teardown was still in flight — '
              'this is exactly the unbindAll() race');

      completer.complete();
      await acquire;
      expect(released, isTrue);
      expect(acquired, isTrue);
    });

    test('a failing release does NOT propagate to the acquirer', () async {
      // A wedged/throwing teardown is expected (device-observed
      // releaseFlutterSurfaceTexture PlatformException). It must never turn
      // into a failure on the dismiss path.
      CameraHandoff.trackRelease(Future<void>.error(StateError('teardown blew up')));
      await CameraHandoff.awaitRelease().timeout(const Duration(seconds: 1));
    });

    test('gives up after the timeout instead of blocking the dismiss path',
        () async {
      // A teardown has been observed stalling ~60s. Blocking the barcode
      // scanner that long would be WORSE than the race we are closing, so the
      // wait is bounded and the acquirer proceeds regardless.
      final stalled = Completer<void>();
      CameraHandoff.trackRelease(stalled.future);

      final sw = Stopwatch()..start();
      await CameraHandoff.awaitRelease(
        timeout: const Duration(milliseconds: 60),
      );
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'awaitRelease must not outlive its timeout');
      stalled.complete(); // keep the pending future from dangling
    });

    test('clears the pending release once it completes', () async {
      final completer = Completer<void>();
      CameraHandoff.trackRelease(completer.future);
      expect(CameraHandoff.hasPendingRelease, isTrue);

      completer.complete();
      await CameraHandoff.awaitRelease();
      await Future<void>.delayed(Duration.zero);

      expect(CameraHandoff.hasPendingRelease, isFalse,
          reason: 'a settled release must not make later acquisitions wait');
    });

    test('a newer release supersedes an older one', () async {
      final older = Completer<void>();
      final newer = Completer<void>();

      CameraHandoff.trackRelease(older.future);
      CameraHandoff.trackRelease(newer.future);

      var acquired = false;
      final acquire = CameraHandoff.awaitRelease().then((_) => acquired = true);

      // Completing only the OLDER release must not release the gate.
      older.complete();
      await Future<void>.delayed(Duration.zero);
      expect(acquired, isFalse,
          reason: 'the gate tracked a stale release instead of the newest one');

      newer.complete();
      await acquire;
      expect(acquired, isTrue);
    });

    test('an older release completing last does not clear a newer gate',
        () async {
      final older = Completer<void>();
      final newer = Completer<void>();

      CameraHandoff.trackRelease(older.future);
      CameraHandoff.trackRelease(newer.future);

      // Older settles after the newer was registered: it must not null out the
      // newer pending release (identical() guard in trackRelease).
      older.complete();
      await Future<void>.delayed(Duration.zero);
      expect(CameraHandoff.hasPendingRelease, isTrue);

      newer.complete();
      await Future<void>.delayed(Duration.zero);
      expect(CameraHandoff.hasPendingRelease, isFalse);
    });
  });
}
