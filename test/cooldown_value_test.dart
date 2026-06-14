import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';

// RLS-05 / D-07 (code half): the camera/vibration restart cooldown must be the
// "safe side" 2.5s value, not the old 500ms. The device-reliability half of
// RLS-05 is verified on a real device in Plan 04/D-08; here we only pin the
// constant's value so a regression to 500ms is caught without a device.
void main() {
  group('kCameraRestartCooldownMs', () {
    test('cooldown constant is 2500 ms (RLS-05/D-07 safe-side value)', () {
      expect(kCameraRestartCooldownMs, 2500);
    });

    test('cooldown is not the old 500ms value', () {
      expect(kCameraRestartCooldownMs, isNot(500));
    });
  });
}
