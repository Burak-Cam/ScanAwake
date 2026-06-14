import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/l10n/app_strings.dart';

// UX-02 / D-09 characterization: English device => en; everything else => tr.
void main() {
  group('defaultLocaleLang', () {
    test('English locales => en', () {
      expect(defaultLocaleLang('en'), 'en');
      expect(defaultLocaleLang('en_US'), 'en');
      expect(defaultLocaleLang('en_GB'), 'en');
      expect(defaultLocaleLang('EN'), 'en'); // case-insensitive
    });

    test('Turkish and all other locales => tr', () {
      expect(defaultLocaleLang('tr'), 'tr');
      expect(defaultLocaleLang('tr_TR'), 'tr');
      expect(defaultLocaleLang('de'), 'tr');
      expect(defaultLocaleLang('fr'), 'tr');
    });
  });
}
