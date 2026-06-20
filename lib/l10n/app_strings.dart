/// UX-02 / D-09: default UI language when no `app_lang` is saved. English
/// device locale => 'en'; every other locale (incl. TR and other languages)
/// => 'tr'. Accepts either a bare language code ('en') or a full locale
/// string ('en_US') — only the language prefix matters (RESEARCH Q3).
String defaultLocaleLang(String deviceLocale) =>
    deviceLocale.toLowerCase().startsWith('en') ? 'en' : 'tr';

class AppStrings {
  static const Map<String, Map<String, String>> _localizedValues = {
    'notification_body': {'tr': 'Susmak için barkodu okut!', 'en': 'Scan barcode to stop alarm!'},
    'saved_items': {'tr': 'Kayıtlı Ürünler', 'en': 'Saved Items'},
    'list_empty': {'tr': 'Barkod eklemek için tarama ikonuna bas.', 'en': 'Tap scanner icon to add barcodes.'},
    'item': {'tr': 'Ürün', 'en': 'Item'},
    'alarm_cancelled': {'tr': 'Alarm İptal Edildi 🔕', 'en': 'Alarm Cancelled 🔕'},
    'scan_instructions': {'tr': 'SUSMAK İÇİN\nTANIMLI ÜRÜNÜ\nOKUT!', 'en': 'SCAN ITEM\nTO STOP!'},
    'morning_msg': {'tr': 'GÜNAYDIN ŞAMPİYON! ☀️', 'en': 'GOOD MORNING CHAMPION! ☀️'},
    'camera_fix_btn': {'tr': 'KAMERA ODAKLAMIYOR MU?\nTİTREŞİMİ KES', 'en': 'CAMERA BLURRY?\nCUT VIBRATION'},
    'scan_title': {'tr': 'Ürün Tara', 'en': 'Scan Item'},
    'flash_hint': {'tr': 'Karanlıktaysa flaşı aç 👆', 'en': 'Turn on flash if dark 👆'},
    'camera_starting': {'tr': 'Kamera başlatılıyor...', 'en': 'Starting camera...'},
    'camera_retry': {'tr': 'Kamera açılamadı. Tekrar denemek için dokun.', 'en': 'Camera failed to open. Tap to retry.'},
    'item_exists': {'tr': 'Bu ürün zaten ekli!', 'en': 'Item already exists!'},
    'item_added': {'tr': 'Ürün Eklendi! ✅', 'en': 'Item Added! ✅'},
    'add_item_first': {'tr': 'Önce barkod ekle!', 'en': 'Add an item first!'},
    'test_start': {'tr': '5 saniye sonra çalacak...', 'en': 'Ringing in 5 seconds...'},
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
    'cheat_title': {'tr': '🚨 HİLE TESPİT EDİLDİ! 🚨', 'en': '🚨 CHEAT DETECTED! 🚨'},
    'cheat_msg': {
      'tr': 'Dün alarm çalarken uygulamayı zorla kapatıp kaçtığını tespit ettik.\n\nBu davranış "ScanAwake" ruhuna aykırı!\n\nCEZA: Seri (Streak) sıfırlandı.',
      'en': 'We detected that you forced closed the app while the alarm was ringing.\n\nThis is against the "ScanAwake" spirit!\n\nPENALTY: Streak reset.'
    },
    'max_items': {'tr': 'En fazla 3 ürün eklenebilir.', 'en': 'Max 3 items allowed.'},
    'streak_title': {'tr': 'Ateş Serisi (Streak)', 'en': 'Fire Streak'},
    'streak_desc': {'tr': 'Her gün zamanında uyanarak seriyi koru. Ateşin sönmesin!', 'en': 'Wake up on time daily to keep the fire burning!'},
    'token_title': {'tr': 'Erteleme Jetonu', 'en': 'Snooze Token'},
    'token_desc': {'tr': 'Her 3 günlük seride 1 jeton kazanırsın. En fazla 3 jeton birikebilir.', 'en': 'Earn 1 token every 3-day streak. Max 3 tokens allowed.'},
    'streak_day': {'tr': '. Gün', 'en': '. Day'},
    'token_name': {'tr': 'Jeton', 'en': 'Token'},
    'ringtone_menu': {'tr': 'Zil Sesi', 'en': 'Ringtone'},
    'language_menu': {'tr': 'Dil / Language', 'en': 'Language'},
    'dark_mode_menu': {'tr': 'Karanlık Mod', 'en': 'Dark Mode'},
    'test_alarm_menu': {'tr': 'Alarmı Test Et', 'en': 'Test Alarm'},
    'select_ringtone': {'tr': 'Zil Sesi Seç', 'en': 'Select Ringtone'},
    'pick_from_files': {'tr': 'Dosyalardan Seç...', 'en': 'Pick from files...'},
    'weekly_msg': {'tr': 'TEBRİKLER! BİR HAFTAYI DEVİRDİN! 🏆', 'en': 'CONGRATS! YOU CRUSHED A WEEK! 🏆'},
    'snooze_btn': {'tr': 'Zzz Ertele', 'en': 'Zzz Snooze'},
    'snooze_used': {'tr': 'Alarm 5dk ertelendi. Jeton kullanıldı.', 'en': 'Alarm snoozed for 5m. Token used.'},
    'alarms_not_restored': {'tr': '{n} alarm geri yüklenemedi', 'en': '{n} alarm(s) could not be restored'},
    'developer_mode': {'tr': '🛠️ Geliştirici Modu', 'en': '🛠️ Developer Mode'},
    'no_alarms_set': {'tr': 'Henüz Alarm Kurulmadı', 'en': 'No Alarms Set'},
    'select_days': {'tr': 'Tekrarlanacak Günleri Seç', 'en': 'Select Repeat Days'},
    'select_day_warning': {'tr': 'En az bir gün seçmelisiniz!', 'en': 'You must select at least one day!'},
    'daily_repeat': {'tr': 'Her Gün', 'en': 'Daily'},
    'weekdays_repeat': {'tr': 'Hafta İçi', 'en': 'Weekdays'},
    'custom_repeat': {'tr': 'Özel...', 'en': 'Custom...'},
    'repeat_once': {'tr': 'Tek Seferlik', 'en': 'One-time'},
    'repeat_title': {'tr': 'Tekrar', 'en': 'Repeat'},
    'label_title': {'tr': 'Etiket', 'en': 'Label'},
    'label_hint': {'tr': 'Alarm', 'en': 'Alarm'},
    'add_alarm_title': {'tr': 'Alarm Ekle', 'en': 'Add Alarm'},
    // UX-01: in-place edit modal title (reuses the add modal; TR/EN parity).
    'edit_alarm_title': {'tr': 'Alarmı Düzenle', 'en': 'Edit Alarm'},
    'btn_cancel': {'tr': 'İptal', 'en': 'Cancel'},
    'btn_save': {'tr': 'Kaydet', 'en': 'Save'},
    'inactive': {'tr': 'Pasif', 'en': 'Inactive'},
    'app_version': {'tr': 'v1.0.0 (Beta)', 'en': 'v1.0.0 (Beta)'},
    // RLS-04 / D-03: exact-alarm permission redirect dialog (TR/EN parity).
    'exact_alarm_title': {'tr': '⏰ İzin Gerekli', 'en': '⏰ Permission Required'},
    'exact_alarm_desc': {
      'tr': 'Alarmın tam zamanında ve güvenilir şekilde çalabilmesi için '
            '"Alarm ve hatırlatıcı ayarlama" (kesin alarm) iznine ihtiyacımız var.\n\n'
            'Bu izin olmadan alarm kurulamaz. Lütfen ayarlardan izni açın.',
      'en': 'To ring exactly on time and reliably, the alarm needs the '
            '"Alarms & reminders" (exact alarm) permission.\n\n'
            'Without it the alarm cannot be set. Please enable the permission in settings.'
    },
    'btn_open_settings': {'tr': 'Ayarları Aç', 'en': 'Open Settings'},
    // MIS-01 / ENG-03: Lümen mission (Stage 2) strings (TR/EN parity, UI-SPEC).
    'mission_lumen_title': {'tr': '2. AŞAMA: LÜMEN', 'en': 'STAGE 2: LUMEN'},
    'mission_lumen_guide': {'tr': 'IŞIĞA DOĞRU TUT — DAHA PARLAK!', 'en': 'POINT AT LIGHT — BRIGHTER!'},
    'mission_lumen_brighter': {'tr': 'DAHA PARLAK!', 'en': 'BRIGHTER!'},
    'mission_lumen_hold': {'tr': 'NEREDEYSE TAMAM, SABIT TUT!', 'en': 'ALMOST THERE, HOLD STEADY!'},
    'mission_sound_lowered': {'tr': 'Ses kısıldı', 'en': 'Sound lowered'},
    'mission_menu_title': {'tr': 'Görev', 'en': 'Mission'},
    'mission_none': {'tr': 'Görev Yok', 'en': 'No Mission'},
    'mission_lumen_name': {'tr': 'Lümen (Işığa Tut)', 'en': 'Lumen (Find Light)'},
    'mission_select_title': {'tr': 'Görev Seç', 'en': 'Select Mission'},
    // MIS-02 / ENG-03: Renk Bulma (Color Find) mission (Stage 2) strings
    // (TR/EN parity, UI-SPEC). Every key MUST exist in both languages —
    // enforced by color_match_test.dart parity group (Pitfall 6).
    'mission_color_title': {'tr': '2. AŞAMA: RENK BUL', 'en': 'STAGE 2: FIND THE COLOR'},
    'mission_color_guide': {'tr': 'BU RENKTE BİR NESNE GÖSTER', 'en': 'SHOW AN OBJECT OF THIS COLOR'},
    'mission_color_hold': {'tr': 'NEREDEYSE TAMAM, SABIT TUT!', 'en': 'ALMOST THERE, HOLD STEADY!'},
    'mission_color_name': {'tr': 'Renk Bul', 'en': 'Find Color'},
    'mission_color_reroll': {'tr': 'Yeniden Çevir', 'en': 'Reroll'},
    'color_red': {'tr': 'Kırmızı', 'en': 'Red'},
    'color_orange': {'tr': 'Turuncu', 'en': 'Orange'},
    'color_yellow': {'tr': 'Sarı', 'en': 'Yellow'},
    'color_green': {'tr': 'Yeşil', 'en': 'Green'},
    'color_blue': {'tr': 'Mavi', 'en': 'Blue'},
    'color_purple': {'tr': 'Mor', 'en': 'Purple'},
    // MIS-03 / ENG-03: Nesne Tanıma (Object Find, ML Kit) mission (Stage 2)
    // strings (TR/EN parity, UI-SPEC). Every key MUST exist in both languages —
    // enforced by object_match_test.dart parity group (Pitfall 6). `object_<key>`
    // names mirror kObjectTargets keys; ML Kit labels stay English (internal map).
    'mission_object_title': {'tr': '2. AŞAMA: NESNE BUL', 'en': 'STAGE 2: FIND THE OBJECT'},
    'mission_object_guide': {'tr': 'ŞUNU GÖSTER:', 'en': 'SHOW THIS:'},
    'mission_object_hold': {'tr': 'NEREDEYSE TAMAM, SABIT TUT!', 'en': 'ALMOST THERE, HOLD STEADY!'},
    'mission_object_name': {'tr': 'Nesne Bul', 'en': 'Find Object'},
    'mission_object_reroll': {'tr': 'Başka Nesne', 'en': 'Another Object'},
    'mission_object_detected': {'tr': 'Algılanan:', 'en': 'Detected:'},
    'object_mug': {'tr': 'Bardak / Kupa', 'en': 'Cup / Mug'},
    'object_bottle': {'tr': 'Şişe', 'en': 'Bottle'},
    'object_pillow': {'tr': 'Yastık', 'en': 'Pillow'},
    'object_fruit': {'tr': 'Meyve', 'en': 'Fruit'},
    'object_shoe': {'tr': 'Ayakkabı', 'en': 'Shoe'},
    'object_laptop': {'tr': 'Dizüstü / Laptop', 'en': 'Laptop'},
    'object_lighter': {'tr': 'Çakmak', 'en': 'Lighter'},
    'object_paper': {'tr': 'Havlu / Peçete', 'en': 'Towel / Tissue'},
    'object_clock': {'tr': 'Saat', 'en': 'Clock'},
    'object_remote': {'tr': 'Kumanda', 'en': 'Remote'},
    'object_backpack': {'tr': 'Sırt Çantası', 'en': 'Backpack'},
    'object_keyboard': {'tr': 'Klavye', 'en': 'Keyboard'},
  };

  static const Map<int, Map<String, String>> _dayShortNames = {
      1: {'tr': 'Pzt', 'en': 'Mon'},
      2: {'tr': 'Sal', 'en': 'Tue'},
      3: {'tr': 'Çar', 'en': 'Wed'},
      4: {'tr': 'Per', 'en': 'Thu'},
      5: {'tr': 'Cum', 'en': 'Fri'},
      6: {'tr': 'Cmt', 'en': 'Sat'},
      7: {'tr': 'Paz', 'en': 'Sun'},
  };

  static String get(String key, String lang) {
    return _localizedValues[key]?[lang] ?? key;
  }

  static String getDayShortName(int day, String lang) {
    return _dayShortNames[day]?[lang] ?? 'Day';
  }

  static String getRandomFact(String lang) {
    final facts = _sleepFacts[lang] ?? _sleepFacts['tr']!;
    final randomIndex = DateTime.now().millisecondsSinceEpoch % facts.length;
    return facts[randomIndex];
  }

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
}
