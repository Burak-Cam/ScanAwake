import 'dart:ui' show PlatformDispatcher;
import 'package:alarm/alarm.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/app_strings.dart';
import 'services/prefs_service.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();

  // Formality: surface the bundled on-device ML models' Apache-2.0 attribution
  // in the in-app Licenses page (showLicensePage). Dart/Flutter package licenses
  // are aggregated automatically; the bundled models are not, so register them.
  // See the NOTICE file. (LicenseRegistry collects lazily on first open.)
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['ScanAwake — bundled ML models'],
      'The bundled on-device models (YAMNet audio classifier + its AudioSet '
      'class map, and the EfficientNet-Lite0 ImageNet image classifier) are '
      '© Google / TensorFlow and licensed under the Apache License, Version 2.0. '
      'See the NOTICE file and http://www.apache.org/licenses/LICENSE-2.0.',
    );
  });

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // Lock the app to portrait so the UI never rotates with the device — an alarm
  // app has no landscape layout and the lock-screen ring/scan flow must stay
  // upright. Mirrors android:screenOrientation="portrait" on MainActivity (this
  // also covers iOS, whose Info.plist still lists landscape).
  await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp]);

  runApp(const ScanAwakeApp());
}

class ScanAwakeApp extends StatefulWidget {
  const ScanAwakeApp({super.key});

  @override
  State<ScanAwakeApp> createState() => _ScanAwakeAppState();
}

class _ScanAwakeAppState extends State<ScanAwakeApp> {
  // UX-02 / D-09: device-aware default (EN device => en, otherwise => tr),
  // resolved at construction and overridden by a saved app_lang in
  // _loadPreferences. No longer a hard English default.
  Locale _locale = Locale(defaultLocaleLang(
      PlatformDispatcher.instance.locale.languageCode));
  ThemeMode _themeMode = ThemeMode.dark;
  String _currentRingtone = 'assets/sounds/alarm1.mp3'; 

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    setState(() {
      String? savedLang = prefs.appLang;
      // UX-02 / D-09: saved preference wins; otherwise fall back to the
      // device-aware default instead of a hard English default.
      _locale = Locale(savedLang ??
          defaultLocaleLang(PlatformDispatcher.instance.locale.languageCode));

      bool isDark = prefs.isDarkMode;
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;

      _currentRingtone = prefs.ringtonePath;
    });
  }

  void setLanguage(String langCode) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setAppLang(langCode);
    setState(() => _locale = Locale(langCode));
  }

  void toggleTheme(bool isDark) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setDarkMode(isDark);
    setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
  }

  void setRingtone(String path) async {
    final prefs = PrefsService(await SharedPreferences.getInstance());
    await prefs.setRingtonePath(path);
    setState(() => _currentRingtone = path);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ScanAwake',
      locale: _locale, 
      supportedLocales: const [Locale('en'), Locale('tr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: _themeMode,
      theme: ThemeData.light().copyWith(
        primaryColor: Colors.red,
        scaffoldBackgroundColor: Colors.grey[100],
        colorScheme: const ColorScheme.light(
          primary: Colors.red,
          secondary: Colors.redAccent,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black, 
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData.dark().copyWith(
        primaryColor: Colors.red,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.red,
          secondary: Colors.redAccent,
          surface: Colors.black,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: HomeScreen(
        onLanguageChanged: setLanguage,
        onThemeChanged: toggleTheme,
        onRingtoneChanged: setRingtone,
        currentThemeMode: _themeMode,
        currentRingtone: _currentRingtone,
      ),
    );
  }
}
