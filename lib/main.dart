import 'dart:ui' show PlatformDispatcher;
import 'package:alarm/alarm.dart';
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

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(const NoSnoozeApp());
}

class NoSnoozeApp extends StatefulWidget {
  const NoSnoozeApp({super.key});

  @override
  State<NoSnoozeApp> createState() => _NoSnoozeAppState();
}

class _NoSnoozeAppState extends State<NoSnoozeApp> {
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
      title: 'NoSnooze',
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
