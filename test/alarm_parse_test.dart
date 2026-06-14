import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/models/alarm_entity.dart';

// FIX-03 / D-05 characterization: per-entry resilient parse.
// A corrupt record skips only itself; valid records are preserved; malformed
// top-level input never crashes.
void main() {
  Map<String, dynamic> validEntry(int id, int hour, int minute) => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'isActive': true,
        'repeatDays': <int>[1, 2],
        'label': 'wake',
      };

  group('parseAlarmsResilient', () {
    test('two valid records => (2, skipped:0)', () {
      final json = jsonEncode([validEntry(1, 7, 0), validEntry(2, 8, 30)]);
      final (alarms, skipped) = parseAlarmsResilient(json);
      expect(alarms.length, 2);
      expect(skipped, 0);
      expect(alarms[0].id, 1);
      expect(alarms[1].time.hour, 8);
      expect(alarms[1].time.minute, 30);
    });

    test('one valid + one corrupt => (1, skipped:1)', () {
      final json = jsonEncode([
        validEntry(1, 7, 0),
        {'id': 'not-an-int', 'hour': 9, 'minute': 0, 'isActive': true},
      ]);
      final (alarms, skipped) = parseAlarmsResilient(json);
      expect(alarms.length, 1);
      expect(skipped, 1);
      expect(alarms.single.id, 1);
    });

    test('null input => ([], 0) without crashing', () {
      final (alarms, skipped) = parseAlarmsResilient(null);
      expect(alarms, isEmpty);
      expect(skipped, 0);
    });

    test('empty/whitespace input => ([], 0)', () {
      expect(parseAlarmsResilient('').$1, isEmpty);
      expect(parseAlarmsResilient('   ').$2, 0);
    });

    test('non-JSON garbage => ([], 0) without crashing', () {
      final (alarms, skipped) = parseAlarmsResilient('{not valid json');
      expect(alarms, isEmpty);
      expect(skipped, 0);
    });

    test('valid JSON that is not a list => ([], 0)', () {
      final (alarms, skipped) = parseAlarmsResilient(jsonEncode({'id': 1}));
      expect(alarms, isEmpty);
      expect(skipped, 0);
    });
  });

  group('AlarmEntity.fromJson hardening', () {
    test('valid map round-trips through toJson/fromJson', () {
      final original = AlarmEntity(
        id: 5,
        time: const TimeOfDay(hour: 6, minute: 45),
        isActive: false,
        repeatDays: const [1, 3, 5],
        label: 'gym',
      );
      final restored = AlarmEntity.fromJson(original.toJson());
      expect(restored.id, 5);
      expect(restored.time.hour, 6);
      expect(restored.time.minute, 45);
      expect(restored.isActive, false);
      expect(restored.repeatDays, [1, 3, 5]);
      expect(restored.label, 'gym');
    });

    test('throws (not NoSuchMethodError) when id is wrong type', () {
      expect(
        () => AlarmEntity.fromJson({
          'id': 'x',
          'hour': 7,
          'minute': 0,
          'isActive': true,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when hour is out of range', () {
      expect(
        () => AlarmEntity.fromJson({
          'id': 1,
          'hour': 99,
          'minute': 0,
          'isActive': true,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when isActive is wrong type', () {
      expect(
        () => AlarmEntity.fromJson({
          'id': 1,
          'hour': 7,
          'minute': 0,
          'isActive': 'yes',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws when repeatDays is not List<int>', () {
      expect(
        () => AlarmEntity.fromJson({
          'id': 1,
          'hour': 7,
          'minute': 0,
          'isActive': true,
          'repeatDays': ['mon', 'tue'],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing label defaults to empty string', () {
      final e = AlarmEntity.fromJson({
        'id': 1,
        'hour': 7,
        'minute': 0,
        'isActive': true,
      });
      expect(e.label, '');
    });
  });
}
