import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:no_snooze/models/alarm_entity.dart';
import 'package:no_snooze/models/enums.dart';
import 'package:no_snooze/services/alarm_service.dart';

// ENG-03 / MIS-01 / D-10/D-11 / Pitfall 5 characterization: MissionType
// persists in alarms_data and rides the AlarmSettings.payload alongside `kind`.
// Back-compat is the core-value guarantee here: a legacy alarm (no field) and
// an unknown/future mission ('water') BOTH decode to MissionType.none WITHOUT
// throwing — dismiss must never crash.

class MockAlarmGateway extends Mock implements AlarmGateway {}

class _FakeAlarmSettings extends Fake implements AlarmSettings {}

void main() {
  Map<String, dynamic> baseEntry({String? mission}) => {
        'id': 1,
        'hour': 7,
        'minute': 0,
        'isActive': true,
        'repeatDays': <int>[1, 2],
        'label': 'wake',
        if (mission != null) 'missionType': mission,
      };

  group('MissionType enum (D-10)', () {
    test('contains exactly none, lumen and renk', () {
      // D-10: a value is added only when its concrete Mission ships. lumen
      // shipped in Phase 4; renk (ColorMission) ships in Phase 5. Pinned here so
      // a stray/pre-declared value is caught.
      expect(MissionType.values,
          [MissionType.none, MissionType.lumen, MissionType.renk]);
    });
  });

  group('AlarmEntity.fromJson missionType decode (D-11 / Pitfall 5)', () {
    test('legacy JSON with NO missionType key => MissionType.none', () {
      final e = AlarmEntity.fromJson(baseEntry());
      expect(e.missionType, MissionType.none);
    });

    test("missionType:'lumen' => MissionType.lumen", () {
      final e = AlarmEntity.fromJson(baseEntry(mission: 'lumen'));
      expect(e.missionType, MissionType.lumen);
    });

    test("unknown/future missionType:'water' => none WITHOUT throwing", () {
      late AlarmEntity e;
      expect(
        () => e = AlarmEntity.fromJson(baseEntry(mission: 'water')),
        returnsNormally,
      );
      expect(e.missionType, MissionType.none);
    });

    test('non-string missionType (e.g. int) => none WITHOUT throwing', () {
      final json = baseEntry();
      json['missionType'] = 42;
      late AlarmEntity e;
      expect(() => e = AlarmEntity.fromJson(json), returnsNormally);
      expect(e.missionType, MissionType.none);
    });

    test('toJson(fromJson(x)) round-trips missionType (lumen)', () {
      final original = AlarmEntity(
        id: 5,
        time: const TimeOfDay(hour: 6, minute: 45),
        missionType: MissionType.lumen,
      );
      final restored = AlarmEntity.fromJson(original.toJson());
      expect(restored.missionType, MissionType.lumen);
    });

    test('toJson(fromJson(x)) round-trips missionType (none default)', () {
      final original = AlarmEntity(
        id: 6,
        time: const TimeOfDay(hour: 8, minute: 0),
      );
      expect(original.missionType, MissionType.none);
      final restored = AlarmEntity.fromJson(original.toJson());
      expect(restored.missionType, MissionType.none);
    });
  });

  group('parseAlarmsResilient — unknown mission is NOT corruption', () {
    test('record with unknown mission is KEPT (defaults none), not skipped', () {
      final json = jsonEncode([
        baseEntry(mission: 'water'),
        baseEntry(mission: 'lumen'),
      ]);
      final (alarms, skipped) = parseAlarmsResilient(json);
      expect(alarms.length, 2);
      expect(skipped, 0);
      expect(alarms[0].missionType, MissionType.none);
      expect(alarms[1].missionType, MissionType.lumen);
    });
  });

  group('scheduleAlarmFn payload carries mission (ENG-03)', () {
    late MockAlarmGateway gateway;

    setUpAll(() {
      registerFallbackValue(_FakeAlarmSettings());
    });

    setUp(() {
      gateway = MockAlarmGateway();
      when(() => gateway.set(any())).thenAnswer((_) async {});
      when(() => gateway.canScheduleExact()).thenAnswer((_) async => true);
    });

    test("payload contains both 'kind' and 'mission':'lumen'", () async {
      await scheduleAlarmFn(
        7,
        DateTime(2030, 1, 1, 6, 0),
        true,
        'en',
        'assets/sounds/alarm1.mp3',
        'Wake',
        AlarmKind.real,
        missionType: MissionType.lumen,
        gateway: gateway,
      );
      final captured = verify(() => gateway.set(captureAny())).captured.single
          as AlarmSettings;
      final decoded = jsonDecode(captured.payload!) as Map<String, dynamic>;
      expect(decoded['kind'], 'real');
      expect(decoded['mission'], 'lumen');
    });

    test("default missionType => payload 'mission':'none'", () async {
      await scheduleAlarmFn(
        8,
        DateTime(2030, 1, 1, 6, 0),
        false,
        'tr',
        'assets/sounds/alarm1.mp3',
        'Test',
        AlarmKind.test,
        gateway: gateway,
      );
      final captured = verify(() => gateway.set(captureAny())).captured.single
          as AlarmSettings;
      final decoded = jsonDecode(captured.payload!) as Map<String, dynamic>;
      expect(decoded['kind'], 'test');
      expect(decoded['mission'], 'none');
    });
  });
}
