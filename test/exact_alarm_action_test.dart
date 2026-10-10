import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/l10n/app_strings.dart';
import 'package:no_snooze/services/alarm_service.dart';

// CR-03 follow-up (2026-10-10): revoking the exact-alarm permission cancels
// the app's alarms while the UI still shows them active.
void main() {
  ExactAlarmAction d({
    required bool granted,
    bool wasDenied = false,
    bool hasActive = true,
    bool ringing = false,
    bool rawDenied = false,
  }) =>
      decideExactAlarmAction(
          granted: granted,
          wasDenied: wasDenied,
          hasActive: hasActive,
          ringing: ringing,
          rawDenied: rawDenied);

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

  // F-2 (2026-10-10, Redmi Note 9S / Android 12): a battery-exempt app keeps
  // canScheduleExactAlarms()==true even with the permission switched off.
  group('F-2 warnExempt (alarms only work via battery exemption)', () {
    test('raw op denied but effectively granted -> warnExempt', () {
      expect(d(granted: true, rawDenied: true), ExactAlarmAction.warnExempt);
    });

    test('no exempt warning while an alarm is ringing', () {
      expect(d(granted: true, rawDenied: true, ringing: true),
          ExactAlarmAction.none);
    });

    test('no exempt warning without an active alarm', () {
      expect(d(granted: true, rawDenied: true, hasActive: false),
          ExactAlarmAction.none);
    });

    test('effective denial dominates the raw state -> warn', () {
      expect(d(granted: false, rawDenied: true), ExactAlarmAction.warn);
    });

    test('re-arm takes priority over the exempt warning', () {
      expect(d(granted: true, wasDenied: true, rawDenied: true),
          ExactAlarmAction.rearm);
    });
  });

  group('CR-03 takip metinleri', () {
    test('new keys exist in TR and EN and differ', () {
      for (final key in const [
        'exact_alarm_exempt_desc',
        'kill_warning_title',
        'kill_warning_body',
      ]) {
        final tr = AppStrings.get(key, 'tr');
        final en = AppStrings.get(key, 'en');
        expect(tr, isNot(key), reason: '$key missing in tr');
        expect(en, isNot(key), reason: '$key missing in en');
        expect(tr, isNot(en), reason: '$key tr == en');
      }
    });
  });
}
