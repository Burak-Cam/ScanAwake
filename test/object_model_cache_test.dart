import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/constants/app_constants.dart';

// Review 2026-10-10 #4: a truncated object_labeler.tflite left by a pre-atomic
// build was accepted forever (any length > 0), so Nesne could never complete.
// The cache is now accepted only at the bundled model's exact byte size.
void main() {
  test('kObjectModelBytes matches the bundled model asset', () {
    expect(File('assets/ml/object_labeler.tflite').lengthSync(),
        kObjectModelBytes);
  });

  test('only a cache of exactly the bundled size is valid', () {
    expect(objectModelCacheValid(kObjectModelBytes), isTrue);
    expect(objectModelCacheValid(kObjectModelBytes - 1), isFalse);
    expect(objectModelCacheValid(1000000), isFalse);
    expect(objectModelCacheValid(0), isFalse);
    expect(objectModelCacheValid(kObjectModelBytes + 1), isFalse);
  });
}
