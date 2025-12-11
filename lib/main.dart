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

// --- GLOBAL ALARM FONKSİYONU ---
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
  
  StreamSubscription? alarmSubscription;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _checkPermissions();
    _checkBatteryOptimization(); 
    _checkAlarmStatus();
    _startAlarmListener();
  }

  void _startAlarmListener() {
    alarmSubscription = Alarm.ringStream.stream.listen((alarmSettings) async {
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
        }
      }
    });
  }

  // --- HIZLI YENİDEN BAŞLATMA ---
  Future<void> _handleRestartSequence() async {
    // 1. Alarmı durdur (Vibrasyon sussun)
    await Alarm.stop(42);

    // 2. Çok kısa bekle
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Alarmı HEMEN başlat (Sessiz modda)
    await scheduleAlarmFn(DateTime.now().add(const Duration(milliseconds: 100)), false, false, currentLang);
  }

  Future<void> _checkBatteryOptimization() async {
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppStrings.get('battery_title', currentLang)),
            content: Text(AppStrings.get('battery_desc', currentLang)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppStrings.get('btn_close', currentLang), style: const TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () async {
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
      setState(() => isAlarmActive = false);
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
      if (mounted) _showSnack("${AppStrings.get('alarm_set', currentLang)} ${selectedTime.format(context)}!");
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
          TextButton.icon(
            onPressed: _testAlarm,
            icon: const Icon(Icons.bolt, color: Colors.yellow),
            label: const Text("TEST", style: TextStyle(color: Colors.yellow)),
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

// --- RING SCREEN (CORTLAMA KORUMALI) ---
class RingScreen extends StatefulWidget {
  final List<String> targetBarcodes;
  final bool startWithoutVibration;
  final String language;
  
  const RingScreen({super.key, required this.targetBarcodes, this.startWithoutVibration = false, required this.language});

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> {
  // Controller artık nullable, böylece belleği boşaltabiliriz
  MobileScannerController? controller;
  bool isVibrationStopped = false;
  // Kamera hazır mı? (Çarkı döndürmek için)
  bool isCameraReady = false; 
  late String randomFact;

  @override
  void initState() {
    super.initState();
    isVibrationStopped = widget.startWithoutVibration;
    randomFact = AppStrings.getRandomFact(widget.language);
    
    if (isVibrationStopped) {
      // RESTART DURUMU: Ses çalar, kamera 2.5 sn sonra gelir
      _delayedCameraInit();
    } else {
      // NORMAL DURUM: Kamera hemen açılır
      _initController();
      isCameraReady = true;
    }
  }

  // --- KRİTİK: GECİKMELİ BAŞLATMA ---
  Future<void> _delayedCameraInit() async {
    // Kamerayı açmadan önce 2.5 saniye bekle
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

  // TİTREŞİMİ DURDURMA İSTEĞİ (SİNYAL GÖNDERME)
  void _requestRestart() {
    // Kamerayı kapatıp ana ekrana sinyal gönder
    Navigator.pop(context, 'RESTART');
  }

  // BAŞARILI TARAMA
  bool isLocked = false;
  void _onScanSuccess() {
  if (isLocked) return; 
  setState(() => isLocked = true);

  Alarm.stop(42);
  HapticFeedback.heavyImpact();

  // Show SnackBar before popping
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text("${AppStrings.get('morning_msg', widget.language)} \n\n${randomFact}"),
      // Extend duration because the fact is long
      duration: const Duration(seconds: 8), 
    ),
  );

  // Pop after SnackBar shown
  Navigator.pop(context);
}

  @override
  void dispose() {
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
            // KAMERA: Sadece hazırsa ve controller varsa göster
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
              // KAMERA BEKLERKEN ÇIKAN EKRAN (Ses çalmaya devam eder)
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
            
            // ORTA YAZI
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

            // Flaş Butonu (Sadece kamera hazırsa göster)
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
          ],
        ),
      ),
    );
  }
}

// --- SCANNER SCREEN (ADD ITEM) ---
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

// --- APP STRINGS ---
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
    'battery_desc': {'tr': 'Alarmın sabah kesin çalması için ayarlardan "Kısıtlama Yok" seçeneğini seçmelisin.', 'en': 'To ensure alarm rings, please select "No Restrictions" in battery settings.'},
    'btn_close': {'tr': 'Kapat', 'en': 'Close'},
  };
  static const Map<String, List<String>> _sleepFacts = {
        'tr': [
            "Biliyor muydun? Ortalama bir uyku döngüsü yaklaşık 90 dakikadır. Bu döngüler arasında uyanırsan daha dinç hissedersin!",
            "Uyku sırasında beynin gün içinde öğrendiklerini pekiştirir ve hafızaya kaydeder. Kaliteli uyku, öğrenme demektir.",
            "Yetişkinlerin %40'ı günde 7 saatten az uyuyor. Daha iyi bir gün için 7-9 saati hedefle!",
            "Uyku eksikliği, açlık hormonu grelini yükselterek iştahını artırır. Kilo kontrolü için uykuna dikkat et.",
            "Uyanır uyanmaz yatağını toplamak, güne küçük bir başarı ile başlamanın en kolay yoludur.",
        ],
        'en': [
            "Did you know? An average sleep cycle is about 90 minutes. Waking up between these cycles can make you feel more refreshed!",
            "During sleep, your brain consolidates what you learned during the day. Quality sleep means better memory.",
            "40% of adults sleep less than 7 hours a day. Aim for 7-9 hours for a better day!",
            "Lack of sleep increases the hunger hormone ghrelin, boosting your appetite. Pay attention to your sleep for weight control.",
            "Making your bed right after waking up is the easiest way to start your day with a small achievement.",
        ],
    };

  static String get(String key, String lang) {
    return _localizedValues[key]?[lang] ?? key;
  }

  static String getRandomFact(String lang) {
        final facts = _sleepFacts[lang] ?? _sleepFacts['tr']!; // Dil yoksa TR kullan
        final randomIndex = DateTime.now().millisecondsSinceEpoch % facts.length; // Basit rastgele seçim
        return facts[randomIndex];
    }
    
}