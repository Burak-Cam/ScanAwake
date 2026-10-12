import 'package:alarm/alarm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:no_snooze/services/alarm_service.dart';

// Review 2026-10-10 #3: revoking the exact-alarm permission cancels EVERY
// pending alarm of the app, including transient snooze / restart re-fires
// whose ids are not entity ids. Re-granting must restore those too, not only
// the entity alarms — otherwise the "restored" snackbar lies.

class MockAlarmGateway extends Mock implements AlarmGateway {}

class _FakeAlarmSettings extends Fake implements AlarmSettings {}

AlarmSettings _alarm(int id, DateTime at, {String? payload}) => AlarmSettings(
      id: id,
      dateTime: at,
      assetAudioPath: 'assets/sounds/alarm1.mp3',
      payload: payload,
      volumeSettings: VolumeSettings.fade(
        volume: 1.0,
        fadeDuration: const Duration(seconds: 3),
      ),
      notificationSettings: const NotificationSettings(
        title: 'ScanAwake',
        body: 'body',
      ),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeAlarmSettings());
  });

  final now = DateTime(2026, 10, 10, 7, 0);

  group('transientAlarmsToRestore (pure)', () {
    test('keeps only future non-entity alarms beyond the minimum lead', () {
      final stored = [
        _alarm(5, now.add(const Duration(days: 1))), // entity
        _alarm(99, now.add(const Duration(minutes: 5))), // pending snooze
        _alarm(98, now.subtract(const Duration(minutes: 1))), // past / ringing
        _alarm(97, now.add(const Duration(milliseconds: 100))), // restart re-fire
      ];
      final result =
          transientAlarmsToRestore(stored, entityIds: {5}, now: now);
      expect(result.map((a) => a.id).toList(), [99]);
    });
  });

  group('restoreTransientAlarms', () {
    late MockAlarmGateway gateway;

    setUp(() {
      gateway = MockAlarmGateway();
      when(() => gateway.set(any())).thenAnswer((_) async {});
    });

    test('permission still missing -> false, nothing read or set', () async {
      when(() => gateway.canScheduleExact()).thenAnswer((_) async => false);
      final ok = await restoreTransientAlarms(
          entityIds: {5}, gateway: gateway, now: now);
      expect(ok, isFalse);
      verifyNever(() => gateway.storedAlarms());
      verifyNever(() => gateway.set(any()));
    });

    test('re-sets the pending transient alarm verbatim, skips entities',
        () async {
      const payload = '{"kind":"snooze","mission":"lumen"}';
      when(() => gateway.canScheduleExact()).thenAnswer((_) async => true);
      when(() => gateway.storedAlarms()).thenAnswer((_) async => [
            _alarm(5, now.add(const Duration(days: 1))),
            _alarm(99, now.add(const Duration(minutes: 5)), payload: payload),
          ]);
      final ok = await restoreTransientAlarms(
          entityIds: {5}, gateway: gateway, now: now);
      expect(ok, isTrue);
      final captured =
          verify(() => gateway.set(captureAny())).captured.cast<AlarmSettings>();
      expect(captured, hasLength(1));
      expect(captured.single.id, 99);
      expect(captured.single.payload, payload);
      expect(captured.single.dateTime, now.add(const Duration(minutes: 5)));
    });

    test('empty plugin store -> true, nothing set', () async {
      when(() => gateway.canScheduleExact()).thenAnswer((_) async => true);
      when(() => gateway.storedAlarms()).thenAnswer((_) async => []);
      final ok = await restoreTransientAlarms(
          entityIds: {5}, gateway: gateway, now: now);
      expect(ok, isTrue);
      verifyNever(() => gateway.set(any()));
    });
  });
}
