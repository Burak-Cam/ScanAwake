import 'dart:async';
import 'package:alarm/alarm.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'NoSnooze',
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: Colors.black,
      primaryColor: Colors.red,
      colorScheme: const ColorScheme.dark(
        primary: Colors.red,
        secondary: Colors.redAccent,
      ),
    ),
    home: const HomeScreen(),
  ));
}

Future<void> scheduleAlarmFn(DateTime dateTime, bool isTest, bool vibrate, String lang) async {
  final alarmSettings = AlarmSettings(
    id: 42,
    dateTime: dateTime,
    assetAudioPath: 'assets/alarm.mp3',
    loopAudio: true,
    vibrate: vibrate,
    volumeSettings: VolumeSettings.fade(
      volume: 1.0,
      fadeDuration: const Duration(seconds: 2),
      volumeEnforced: true,
    ),
    notificationSettings: NotificationSettings(
      title: isTest ? 'TEST' : 'NoSnooze',
      body: AppStrings.get('notification_body', lang),
      stopButton: null,
      icon: 'notification_icon',
    ),
  );
  await Alarm.set(alarmSettings: alarmSettings);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<String> savedBarcodes = [];
  TimeOfDay selectedTime = TimeOfDay.now();
  bool isAlarmActive = false;
  String currentLang = 'tr';
  
  // --- GAMIFICATION DEĞİŞKENLERİ ---
  int streakCount = 0;
  bool cheatDetected = false; 

  StreamSubscription? alarmSubscription;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _checkPermissions();
    _checkAlarmStatus();
    _startAlarmListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkBatteryOptimization();
      _checkCheatStatus(); // Hile kontrolü
    });
  }

  @override
  void dispose() {
    alarmSubscription?.cancel();
    super.dispose();
  }

  // --- HİLE KONTROLÜ (SHERLOCK HOLMES) ---
  Future<void> _checkCheatStatus() async {
    final prefs = await SharedPreferences.getInstance();
    // Eğer "is_ringing" true kalmışsa, kullanıcı alarm çalarken uygulamayı öldürmüştür.
    bool wasRinging = prefs.getBool('is_ringing') ?? false;

    if (wasRinging) {
      // CEZA KESME VAKTİ
      await prefs.setBool('is_ringing', false); // Bayrağı indir
      await prefs.setInt('user_streak', 0); // SERİYİ SIFIRLA!
      
      setState(() {
        streakCount = 0;
        cheatDetected = true;
      });

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.red[900],
            title: const Text("🚨 HİLE TESPİT EDİLDİ! 🚨", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(
              AppStrings.get('cheat_msg', currentLang),
              style: const TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("ÖZÜR DİLERİM", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              )
            ],
          ),
        );
      }
    }
  }

  void _startAlarmListener() {
    alarmSubscription = Alarm.ringStream.stream.listen((alarmSettings) async {
      // ALARM ÇALMAYA BAŞLADI: TUZAĞI KUR (Flag = True)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_ringing', true);

      setState(() => isAlarmActive = false);

      if (savedBarcodes.isNotEmpty) {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RingScreen(
              targetBarcodes: savedBarcodes,
              startWithoutVibration: !alarmSettings.vibrate,
              language: currentLang,
            ),
          ),
        );

        if (result == 'RESTART') {
          _handleRestartSequence();
        } else if (result == 'SUCCESS') {
           // Başarılı dönüş, streak güncellenmiş olmalı
           _loadPreferences(); // Ekrandaki streak'i güncelle
        }
      }
    });
  }

  Future<void> _handleRestartSequence() async {
    await Alarm.stop(42);
    await Future.delayed(const Duration(milliseconds: 500));
    await scheduleAlarmFn(DateTime.now().add(const Duration(milliseconds: 100)), false, false, currentLang);
  }

  Future<void> _checkBatteryOptimization() async {
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;

    final prefs = await SharedPreferences.getInstance();
    bool hasSeenWarning = prefs.getBool('battery_dialog_seen') ?? false;
    if (hasSeenWarning) return;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(AppStrings.get('battery_title', currentLang)),
          content: Text(AppStrings.get('battery_desc', currentLang)),
          actions: [
            TextButton(
              onPressed: () async {
                await prefs.setBool('battery_dialog_seen', true);
                Navigator.pop(context);
              },
              child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () async {
                await prefs.setBool('battery_dialog_seen', true);
                Navigator.pop(context);
                await openAppSettings();
              },
              child: const Text("OK", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _checkAlarmStatus() async {
    final alarm = await Alarm.getAlarm(42);
    if (alarm != null) {
      setState(() {
        isAlarmActive = true;
        selectedTime = TimeOfDay.fromDateTime(alarm.dateTime);
      });
    }
  }

  Future<void> _checkPermissions() async {
    if (await Permission.notification.isDenied) await Permission.notification.request();
    await Permission.camera.request();
    await Permission.scheduleExactAlarm.request();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      savedBarcodes = prefs.getStringList('target_barcodes') ?? [];
      currentLang = prefs.getString('app_lang') ?? 'tr';
      streakCount = prefs.getInt('user_streak') ?? 0; // Streak yükle
    });
  }

  Future<void> _toggleLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      currentLang = (currentLang == 'tr') ? 'en' : 'tr';
    });
    await prefs.setString('app_lang', currentLang);
  }

  Future<void> _scanAndAddBarcode() async {
    if (savedBarcodes.length >= 3) {
      _showSnack(AppStrings.get('max_items', currentLang));
      return;
    }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ScannerScreen(language: currentLang))
    );

    if (result != null) {
      if (savedBarcodes.contains(result)) {
        if(mounted) _showSnack(AppStrings.get('item_exists', currentLang));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      setState(() => savedBarcodes.add(result));
      await prefs.setStringList('target_barcodes', savedBarcodes);
      if (mounted) _showSnack(AppStrings.get('item_added', currentLang));
    }
  }

  Future<void> _removeBarcode(int index) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => savedBarcodes.removeAt(index));
    await prefs.setStringList('target_barcodes', savedBarcodes);
  }

  void _pickTime() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext builder) {
        return SizedBox(
          height: 300,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10),
                width: 50, height: 5,
                decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(10)),
              ),
              Expanded(
                child: CupertinoTheme(
                  data: const CupertinoThemeData(
                    brightness: Brightness.dark,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(color: Colors.white, fontSize: 24),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: true,
                    initialDateTime: DateTime(2024, 1, 1, selectedTime.hour, selectedTime.minute),
                    onDateTimeChanged: (DateTime newDateTime) {
                      setState(() {
                        selectedTime = TimeOfDay.fromDateTime(newDateTime);
                      });
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    child: const Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _testAlarm() async {
    if (savedBarcodes.isEmpty) {
      _showSnack(AppStrings.get('add_item_first', currentLang));
      return;
    }
    scheduleAlarmFn(DateTime.now().add(const Duration(seconds: 5)), true, true, currentLang);
    if (mounted) _showSnack(AppStrings.get('test_start', currentLang));
  }

  Future<void> _handleAlarmButton() async {
    if (isAlarmActive) {
      await Alarm.stop(42);
      
      // ALARM İPTAL EDİLDİĞİNDE TUZAĞI KALDIR
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_ringing', false);

      setState(() {
        isAlarmActive = false;
        selectedTime = TimeOfDay.now();
      });
      if(mounted) _showSnack(AppStrings.get('alarm_cancelled', currentLang));
    } else {
      if (savedBarcodes.isEmpty) {
        _showSnack(AppStrings.get('add_item_first', currentLang));
        HapticFeedback.heavyImpact();
        return;
      }
      final now = DateTime.now();
      DateTime dateTime = DateTime(now.year, now.month, now.day, selectedTime.hour, selectedTime.minute);
      if (dateTime.isBefore(now)) dateTime = dateTime.add(const Duration(days: 1));

      await scheduleAlarmFn(dateTime, false, true, currentLang);
      setState(() => isAlarmActive = true);

      final difference = dateTime.difference(now);
      final hours = difference.inHours;
      final minutes = difference.inMinutes % 60;
      String durationMsg = "";
      if (currentLang == 'tr') {
        durationMsg = "Alarm $hours saat $minutes dakika sonra çalacak.";
      } else {
        durationMsg = "Alarm set for $hours hours and $minutes minutes from now.";
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(durationMsg, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.green,
          )
        );
      }
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("NoSnooze", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
        centerTitle: true,
        backgroundColor: Colors.black,
        leading: TextButton(
          onPressed: _toggleLanguage,
          child: Text(currentLang.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 15),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: streakCount > 0 ? Colors.orange : Colors.grey)
            ),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department, color: Colors.orange, size: 20),
                const SizedBox(width: 5),
                Text("$streakCount", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          )
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          GestureDetector(
            onTap: isAlarmActive ? null : _pickTime,
            child: Opacity(
              opacity: isAlarmActive ? 0.6 : 1.0,
              child: Column(
                children: [
                  Text(
                    "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}",
                    style: TextStyle(fontSize: 90, fontWeight: FontWeight.bold, color: isAlarmActive ? Colors.green : Colors.white, letterSpacing: 5),
                  ),
                  Text(
                    isAlarmActive ? AppStrings.get('status_active', currentLang) : AppStrings.get('status_inactive', currentLang),
                    style: const TextStyle(color: Colors.grey)
                  ),
                ],
              ),
            ),
          ),
          
          TextButton.icon(
            onPressed: _testAlarm,
            icon: const Icon(Icons.bolt, color: Colors.yellow),
            label: const Text("TEST", style: TextStyle(color: Colors.yellow)),
          ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("${AppStrings.get('saved_items', currentLang)} (${savedBarcodes.length}/3)", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    if (savedBarcodes.length < 3)
                      IconButton(onPressed: isAlarmActive ? null : _scanAndAddBarcode, icon: const Icon(Icons.add_circle, color: Colors.green, size: 30))
                  ],
                ),
                const SizedBox(height: 10),
                if (savedBarcodes.isEmpty)
                  Text(AppStrings.get('list_empty', currentLang), style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center)
                else
                  Wrap(
                    spacing: 8.0,
                    children: List.generate(savedBarcodes.length, (index) {
                      return Chip(
                        label: Text("${AppStrings.get('item', currentLang)} ${index + 1}"),
                        avatar: const Icon(Icons.qr_code, size: 18),
                        deleteIcon: isAlarmActive ? null : const Icon(Icons.close, size: 18, color: Colors.redAccent),
                        onDeleted: isAlarmActive ? null : () => _removeBarcode(index),
                        backgroundColor: Colors.grey[800],
                      );
                    }),
                  ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20.0),
            child: SizedBox(
              width: double.infinity,
              height: 60,
              child: ElevatedButton.icon(
                onPressed: _handleAlarmButton,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isAlarmActive ? Colors.grey[800] : Colors.red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                ),
                icon: Icon(isAlarmActive ? Icons.alarm_off : Icons.alarm_add, size: 30),
                label: Text(
                  isAlarmActive ? AppStrings.get('btn_cancel', currentLang) : AppStrings.get('btn_set', currentLang),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RingScreen extends StatefulWidget {
  final List<String> targetBarcodes;
  final bool startWithoutVibration;
  final String language;

  const RingScreen({super.key, required this.targetBarcodes, this.startWithoutVibration = false, required this.language});

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> {
  MobileScannerController? controller;
  bool isVibrationStopped = false;
  bool isCameraReady = false;
  late String randomFact;

  bool _showEmergencyButton = false;
  Timer? _emergencyTimer;

  @override
  void initState() {
    super.initState();
    isVibrationStopped = widget.startWithoutVibration;
    randomFact = AppStrings.getRandomFact(widget.language);

    _emergencyTimer = Timer(const Duration(seconds: 60), () {
      if (mounted) {
        setState(() => _showEmergencyButton = true);
      }
    });

    if (isVibrationStopped) {
      _delayedCameraInit();
    } else {
      _initController();
      isCameraReady = true;
    }
  }

  Future<void> _delayedCameraInit() async {
    await Future.delayed(const Duration(milliseconds: 2500));
    if (mounted) {
      setState(() {
        _initController();
        isCameraReady = true;
      });
    }
  }

  void _initController() {
    controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      returnImage: false,
      torchEnabled: false,
    );
  }

  void _requestRestart() {
    Navigator.pop(context, 'RESTART');
  }

  void _handleEmergencyStop() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_ringing', false); // Bayrağı indir, hile sayılmasın

    setState(() => isLocked = true);
    Alarm.stop(42);
    HapticFeedback.lightImpact();
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("⚠️ ${AppStrings.get('alarm_cancelled', widget.language)}")),
    );
  }

  bool isLocked = false;
  Future<void> _onScanSuccess() async {
    if (isLocked) return;
    setState(() => isLocked = true);

    // 1. Alarmı Durdur
    await Alarm.stop(42);
    HapticFeedback.heavyImpact();

    // 2. Hile Bayrağını İndir
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_ringing', false);

    // 3. STREAK HESAPLAMA
    String today = DateTime.now().toString().split(' ')[0];
    String? lastScan = prefs.getString('last_scan_date');
    int currentStreak = prefs.getInt('user_streak') ?? 0;

    if (lastScan != today) {
        currentStreak++;
        await prefs.setInt('user_streak', currentStreak);
        await prefs.setString('last_scan_date', today);
    }

    if(mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("TEBRİKLER! 🔥 $currentStreak. GÜN!\n\n${AppStrings.get('morning_msg', widget.language)} \n${randomFact}"),
          duration: const Duration(seconds: 8),
          backgroundColor: Colors.green,
        ),
      );
    }

    await Future.delayed(const Duration(seconds: 2));

    if(mounted) {
      Navigator.pop(context, 'SUCCESS');
    }
  }

  @override
  void dispose() {
    _emergencyTimer?.cancel();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.red,
        body: Stack(
          children: [
            if (isCameraReady && controller != null)
              MobileScanner(
                controller: controller!,
                onDetect: (capture) {
                  final List<Barcode> barcodes = capture.barcodes;
                  for (final barcode in barcodes) {
                    if (barcode.rawValue != null && widget.targetBarcodes.contains(barcode.rawValue)) {
                      _onScanSuccess();
                      break;
                    }
                  }
                },
              )
            else
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text("Kamera başlatılıyor...", style: TextStyle(color: Colors.white))
                  ],
                ),
              ),

            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(20)),
                    child: Text(AppStrings.get('scan_instructions', widget.language), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 300),
                ],
              ),
            ),

            if (!isVibrationStopped)
              Positioned(
                bottom: 120, left: 0, right: 0,
                child: Center(
                  child: ElevatedButton.icon(
                    onPressed: _requestRestart,
                    icon: const Icon(Icons.vibration, color: Colors.white),
                    label: Text(AppStrings.get('camera_fix_btn', widget.language), textAlign: TextAlign.center),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)),
                  ),
                ),
              ),

            if (isCameraReady && controller != null)
              Positioned(
                top: 50, right: 20,
                child: ValueListenableBuilder(
                  valueListenable: controller!,
                  builder: (context, state, child) {
                    final isFlashOn = state.torchState == TorchState.on;
                    return IconButton(
                      iconSize: 40,
                      icon: Icon(isFlashOn ? Icons.flash_on : Icons.flash_off, color: isFlashOn ? Colors.yellow : Colors.white),
                      onPressed: () => controller?.toggleTorch(),
                    );
                  },
                ),
              ),

            if (_showEmergencyButton)
              Positioned(
                top: 50, left: 20,
                child: GestureDetector(
                  onTap: _handleEmergencyStop,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.redAccent, width: 2)
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 5),
                        Text(
                          AppStrings.get('emergency_btn', widget.language),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- EKSİK OLAN KISIM EKLENDİ ---
class ScannerScreen extends StatefulWidget {
  final String language;
  const ScannerScreen({super.key, required this.language});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    torchEnabled: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool isScanCompleted = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.get('scan_title', widget.language)), backgroundColor: Colors.black, actions: [
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, state, child) => IconButton(
            icon: Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off, color: state.torchState == TorchState.on ? Colors.yellow : Colors.grey),
            onPressed: () => controller.toggleTorch(),
          ),
        ),
      ]),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (isScanCompleted) return;
              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                HapticFeedback.mediumImpact();
                setState(() => isScanCompleted = true);
                Navigator.pop(context, barcodes.first.rawValue);
              }
            },
          ),
          Positioned(
            bottom: 50, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                child: Text(AppStrings.get('flash_hint', widget.language), style: const TextStyle(color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppStrings {
  static const Map<String, Map<String, String>> _localizedValues = {
    'notification_body': {'tr': 'Susmak için barkodu okut!', 'en': 'Scan barcode to stop alarm!'},
    'status_active': {'tr': 'ALARM KURULU', 'en': 'ALARM ACTIVE'},
    'status_inactive': {'tr': 'Saati değiştirmek için dokun', 'en': 'Tap clock to change time'},
    'saved_items': {'tr': 'Kayıtlı Ürünler', 'en': 'Saved Items'},
    'list_empty': {'tr': 'Alarm kurmak için (+) butonuna basıp ürün ekle.', 'en': 'Press (+) to add an item to scan.'},
    'item': {'tr': 'Ürün', 'en': 'Item'},
    'btn_set': {'tr': 'ALARMI KUR', 'en': 'SET ALARM'},
    'btn_cancel': {'tr': 'ALARMI İPTAL ET', 'en': 'CANCEL ALARM'},
    'scan_instructions': {'tr': 'SUSMAK İÇİN\nTANIMLI ÜRÜNÜ\nOKUT!', 'en': 'SCAN ITEM\nTO STOP!'},
    'morning_msg': {'tr': 'GÜNAYDIN ŞAMPİYON! ☀️', 'en': 'GOOD MORNING CHAMPION! ☀️'},
    'camera_fix_btn': {'tr': 'KAMERA ODAKLAMIYOR MU?\nTİTREŞİMİ KES', 'en': 'CAMERA BLURRY?\nCUT VIBRATION'},
    'scan_title': {'tr': 'Ürün Tara', 'en': 'Scan Item'},
    'flash_hint': {'tr': 'Karanlıktaysa flaşı aç 👆', 'en': 'Turn on flash if dark 👆'},
    'max_items': {'tr': 'En fazla 3 ürün eklenebilir.', 'en': 'Max 3 items allowed.'},
    'item_exists': {'tr': 'Bu ürün zaten ekli!', 'en': 'Item already exists!'},
    'item_added': {'tr': 'Ürün Eklendi! ✅', 'en': 'Item Added! ✅'},
    'add_item_first': {'tr': 'Önce barkod ekle!', 'en': 'Add an item first!'},
    'test_start': {'tr': '5 saniye sonra çalacak...', 'en': 'Ringing in 5 seconds...'},
    'alarm_cancelled': {'tr': 'Alarm İptal Edildi 🔕', 'en': 'Alarm Cancelled 🔕'},
    'alarm_set': {'tr': 'Alarm kuruldu:', 'en': 'Alarm set for'},
    'battery_title': {'tr': '⚠️ Önemli Uyarı', 'en': '⚠️ Important'},
    'battery_desc': {
      'tr': 'Alarmın garanti çalması ve uygulamanın kapanmaması için açılan ekranda şunları yapmalısınız:\n\n'
            '1. PİL/BATARYA: "Kısıtlama Yok" veya "Sınırsız" seçeneğini seçin.\n'
            '2. BAŞLATMA: Varsa "Otomatik Başlatma" veya "Arka Planda Çalışma" iznini açın.',
      
      'en': 'To ensure the alarm rings reliably, please adjust these settings in the next screen:\n\n'
            '1. BATTERY: Select "Unrestricted" or "No Restrictions".\n'
            '2. LAUNCH: Enable "Autostart" or "Run in Background" if available.'
    },
    'btn_close': {'tr': 'Kapat', 'en': 'Close'},
    'emergency_btn': {'tr': 'ACİL DURUM KAPAT', 'en': 'EMERGENCY STOP'},
    
    // --- HİLE MESAJI ---
    'cheat_msg': {
      'tr': 'Dün alarm çalarken uygulamayı zorla kapatıp kaçtığını tespit ettik.\n\nBu davranış "NoSnooze" ruhuna aykırı!\n\nCEZA: Seri (Streak) sıfırlandı.',
      'en': 'We detected that you forced closed the app while the alarm was ringing.\n\nThis is against the "NoSnooze" spirit!\n\nPENALTY: Streak reset.'
    }
  };
  
  static const Map<String, List<String>> _sleepFacts = {
    'tr': [
      "Biliyor muydun? Ortalama bir uyku döngüsü yaklaşık 90 dakikadır.",
      "Uyku sırasında beynin gün içinde öğrendiklerini pekiştirir.",
      "Yetişkinlerin %40'ı günde 7 saatten az uyuyor. Hedefin 7-9 saat olsun!",
      "Uyku eksikliği iştahını artırabilir. Kilo kontrolü için uykuna dikkat et.",
      "Uyanır uyanmaz yatağını toplamak, güne küçük bir başarı ile başlamanı sağlar.",
    ],
    'en': [
      "Did you know? An average sleep cycle is about 90 minutes.",
      "During sleep, your brain consolidates what you learned during the day.",
      "40% of adults sleep less than 7 hours a day. Aim for 7-9 hours!",
      "Lack of sleep increases hunger hormones. Watch your sleep for weight control.",
      "Making your bed right after waking up is a great way to start the day.",
    ],
  };

  static String get(String key, String lang) {
    return _localizedValues[key]?[lang] ?? key;
  }

  static String getRandomFact(String lang) {
    final facts = _sleepFacts[lang] ?? _sleepFacts['tr']!; 
    final randomIndex = DateTime.now().millisecondsSinceEpoch % facts.length; 
    return facts[randomIndex];
  }
}