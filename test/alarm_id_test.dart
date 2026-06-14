import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/services/alarm_service.dart';

// FIX-05 characterization: monotonic id step never collides.
void main() {
  group('incrementId', () {
    test('increments by one', () {
      expect(incrementId(0), 1);
      expect(incrementId(41), 42);
    });

    test('consecutive calls produce strictly increasing, non-colliding ids', () {
      int counter = 0;
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        counter = incrementId(counter);
        ids.add(counter);
      }
      expect(ids, [1, 2, 3, 4, 5]);
      expect(ids.toSet().length, ids.length); // no collisions
    });
  });
}
