import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';

// PERF (review 2026-10-10): the per-frame rebuild gates used by the camera
// missions. They only decide WHETHER to repaint — the hold accumulation runs on
// every frame regardless — so the contract pinned here is "never skip a change
// the user could see".
void main() {
  group('progressUiChanged', () {
    test('same rounded percent and same nudge => no rebuild', () {
      expect(progressUiChanged(0.401, 0.404), isFalse);
    });

    test('percent step => rebuild', () {
      expect(progressUiChanged(0.40, 0.41), isTrue);
    });

    test('crossing the near-done threshold inside one percent => rebuild', () {
      // Both round to 75% but sit on either side of 0.75, so only the nudge
      // text changes — that alone must still trigger a rebuild.
      expect((0.7496 * 100).round(), (0.7504 * 100).round());
      expect(progressUiChanged(0.7496, 0.7504), isTrue);
    });

    test('decay back to zero => rebuild', () {
      expect(progressUiChanged(0.05, 0.0), isTrue);
    });

    test('kMissionNearDone stays 0.75 (UI nudge contract)', () {
      expect(kMissionNearDone, 0.75);
    });
  });

  group('uiRefreshDue', () {
    final t0 = DateTime(2026, 10, 10, 7, 0, 0);

    test('first frame always refreshes', () {
      expect(uiRefreshDue(null, t0, kColorUiMinIntervalMs), isTrue);
    });

    test('inside the interval => skip', () {
      expect(
          uiRefreshDue(t0, t0.add(const Duration(milliseconds: 30)),
              kColorUiMinIntervalMs),
          isFalse);
    });

    test('at the interval => refresh', () {
      expect(
          uiRefreshDue(t0, t0.add(const Duration(milliseconds: 66)),
              kColorUiMinIntervalMs),
          isTrue);
    });

    test('backwards clock step never freezes the UI', () {
      expect(
          uiRefreshDue(t0, t0.subtract(const Duration(seconds: 5)),
              kColorUiMinIntervalMs),
          isTrue);
    });
  });
}
