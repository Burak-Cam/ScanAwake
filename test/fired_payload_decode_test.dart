import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:no_snooze/models/alarm_entity.dart';
import 'package:no_snooze/models/enums.dart';
import 'package:no_snooze/services/alarm_service.dart';
import 'package:no_snooze/services/streak_service.dart';

// FIX (checkup-260711 WR-03) regression pins: the restart re-fire must carry
// the FIRED kind (not a hardcoded AlarmKind.real), so a restarted snooze/test
// ring can never be upgraded to streak-eligible (D-03/FIX-04 invariant:
// "snooze re-arms never earn streak"). decodeFiredPayload is the extracted,
// pure decode of home_screen's ring-listener payload block — these tests pin
// its round-trip semantics AND its defensive back-compat defaults (a dismiss
// path must NEVER crash — core value).

class MockAlarmGateway extends Mock implements AlarmGateway {}

class _FakeAlarmSettings extends Fake implements AlarmSettings {}

void main() {
  late MockAlarmGateway gateway;

  setUpAll(() {
    registerFallbackValue(_FakeAlarmSettings());
  });

  setUp(() {
    gateway = MockAlarmGateway();
    when(() => gateway.set(any())).thenAnswer((_) async {});
    when(() => gateway.canScheduleExact()).thenAnswer((_) async => true);
  });

  // Schedule through the real funnel and hand the CAPTURED payload back —
  // exactly what the ring listener sees at fire time.
  Future<String?> scheduledPayload(AlarmKind kind, MissionType mission) async {
    await scheduleAlarmFn(
      42,
      DateTime(2030, 1, 1, 7, 0),
      true,
      'tr',
      'assets/sounds/alarm1.mp3',
      'Wake',
      kind,
      missionType: mission,
      gateway: gateway,
    );
    final captured =
        verify(() => gateway.set(captureAny())).captured.single as AlarmSettings;
    return captured.payload;
  }

  group('decodeFiredPayload round-trip (scheduleAlarmFn → decode)', () {
    test('snooze/su payload decodes back to (snooze, su)', () async {
      final payload = await scheduledPayload(AlarmKind.snooze, MissionType.su);
      final fired = decodeFiredPayload(payload);
      expect(fired.kind, AlarmKind.snooze);
      expect(fired.mission, MissionType.su);
    });

    test('real/lumen payload decodes back to (real, lumen)', () async {
      final payload = await scheduledPayload(AlarmKind.real, MissionType.lumen);
      final fired = decodeFiredPayload(payload);
      expect(fired.kind, AlarmKind.real);
      expect(fired.mission, MissionType.lumen);
    });
  });

  group('WR-03: a restart re-fire carrying the decoded kind never earns streak',
      () {
    test('decoded snooze kind is NOT streak-eligible', () async {
      final payload = await scheduledPayload(AlarmKind.snooze, MissionType.su);
      final fired = decodeFiredPayload(payload);
      // The restart re-fire now carries fired.kind — so scanning a restarted
      // snooze ring runs streakEligible(snooze, ...) == false, never awarding
      // a streak/token on a snoozed morning.
      expect(streakEligible(fired.kind, null, '2026-07-11'), isFalse);
    });

    test('decoded test kind is NOT streak-eligible', () async {
      final payload = await scheduledPayload(AlarmKind.test, MissionType.none);
      final fired = decodeFiredPayload(payload);
      expect(streakEligible(fired.kind, null, '2026-07-11'), isFalse);
    });

    test('legitimate reward preserved: decoded real kind IS streak-eligible',
        () async {
      final payload = await scheduledPayload(AlarmKind.real, MissionType.none);
      final fired = decodeFiredPayload(payload);
      expect(fired.kind, AlarmKind.real);
      expect(streakEligible(fired.kind, null, '2026-07-11'), isTrue);
    });
  });

  group('defensive defaults (back-compat — dismiss must never crash)', () {
    test('null payload (legacy alarm) => (real, none) without throwing', () {
      late ({AlarmKind kind, MissionType mission}) fired;
      expect(() => fired = decodeFiredPayload(null), returnsNormally);
      expect(fired.kind, AlarmKind.real);
      expect(fired.mission, MissionType.none);
    });

    test('empty payload => (real, none) without throwing', () {
      late ({AlarmKind kind, MissionType mission}) fired;
      expect(() => fired = decodeFiredPayload(''), returnsNormally);
      expect(fired.kind, AlarmKind.real);
      expect(fired.mission, MissionType.none);
    });

    test('invalid JSON => (real, none) without throwing', () {
      late ({AlarmKind kind, MissionType mission}) fired;
      expect(() => fired = decodeFiredPayload('{not json'), returnsNormally);
      expect(fired.kind, AlarmKind.real);
      expect(fired.mission, MissionType.none);
    });

    test(
        'unknown kind name => BOTH fall to (real, none) — byName throws, the '
        'catch resets both (existing semantics pinned)', () {
      final payload = jsonEncode({'kind': 'nap', 'mission': 'lumen'});
      late ({AlarmKind kind, MissionType mission}) fired;
      expect(() => fired = decodeFiredPayload(payload), returnsNormally);
      expect(fired.kind, AlarmKind.real);
      // Pitfall-2 back-compat: the kind decode throws AFTER the mission may
      // have been read — the catch deliberately resets BOTH to defaults.
      expect(fired.mission, MissionType.none);
    });

    test('unknown mission name falls to none WITHOUT throwing (Pitfall 5)', () {
      final payload = jsonEncode({'kind': 'snooze', 'mission': 'yoga'});
      final fired = decodeFiredPayload(payload);
      expect(fired.kind, AlarmKind.snooze);
      expect(fired.mission, MissionType.none);
    });

    test('non-string kind (int) => kind stays real', () {
      final payload = jsonEncode({'kind': 7, 'mission': 'lumen'});
      late ({AlarmKind kind, MissionType mission}) fired;
      expect(() => fired = decodeFiredPayload(payload), returnsNormally);
      expect(fired.kind, AlarmKind.real);
      expect(fired.mission, MissionType.lumen);
    });
  });
}
