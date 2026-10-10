import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/alarm_service.dart';

// CR-03 follow-up (2026-10-10): revoking the exact-alarm permission cancels
// the app's alarms while the UI still shows them active.
void main() {
  ExactAlarmAction d({
    required bool granted,
    bool wasDenied = false,
    bool hasActive = true,
    bool ringing = false,
  }) =>
      decideExactAlarmAction(
          granted: granted,
          wasDenied: wasDenied,
          hasActive: hasActive,
          ringing: ringing);

  test('denied with an active alarm warns', () {
    expect(d(granted: false), ExactAlarmAction.warn);
  });

  test('re-granted after a denial re-arms', () {
    expect(d(granted: true, wasDenied: true), ExactAlarmAction.rearm);
  });

  test('never re-arms while an alarm is ringing', () {
    expect(d(granted: true, wasDenied: true, ringing: true),
        ExactAlarmAction.none);
  });

  test('healthy permission does nothing', () {
    expect(d(granted: true), ExactAlarmAction.none);
  });

  test('no active alarm -> nothing to warn about or re-arm', () {
    expect(d(granted: false, hasActive: false), ExactAlarmAction.none);
    expect(d(granted: true, wasDenied: true, hasActive: false),
        ExactAlarmAction.none);
  });
}
