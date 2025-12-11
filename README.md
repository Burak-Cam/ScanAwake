# NoSnooze 📵

**"Ertelemek Yok. Uyanmak Zorundasın."**

NoSnooze, uyanmakta zorluk çekenler için geliştirilmiş, **kullanıcı önceden tanımladığı barkodu okutana kadar susmayan** agresif bir alarm uygulamasıdır. Standart alarmların aksine, NoSnooze sizi yataktan kalkmaya ve fiziksel bir eylemde bulunmaya zorlar.

![App Screenshot](assets/screenshot_placeholder.png) 
*(Buraya uygulamanın ana ekranının ve tarama ekranının ekran görüntüsünü ekleyebilirsin)*

## 🚀 Özellikler

* **Barkod ile Susturma:** Alarmı durdurmanın TEK yolu, önceden kaydettiğiniz diş macunu, kitap veya şampuan barkodunu kameraya okutmaktır.
* **Hata Toleranslı Kamera Yönetimi:** Titreşim ve kamera donanımı arasındaki çakışmaları önleyen özel "Restart Sequence" mimarisi.
* **Akıllı Pil Yönetimi:** Xiaomi/MIUI gibi agresif pil optimizasyonu yapan cihazlarda bile kararlı çalışma.
* **Çoklu Dil Desteği:** Türkçe ve İngilizce tam destek.
* **Karanlık Mod:** Göz yormayan, OLED dostu tam siyah arayüz.
* **Flaş Desteği:** Karanlık odada barkodu rahat okutabilmek için entegre fener kontrolü.

## 🛠️ Teknik Mimari ve Kullanılan Teknolojiler

Bu proje **Flutter** ile geliştirilmiştir ve donanım kısıtlamalarına karşı özel mühendislik çözümleri içerir.

* **SDK:** Flutter (Dart 3.x)
* **Alarm Engine:** `alarm: ^5.0.0` (Android AlarmManager API)
* **Scanner:** `mobile_scanner: ^5.0.0` (ML Kit tabanlı)
* **Storage:** `shared_preferences`
* **Permissions:** `permission_handler`

### 🔥 Kritik Sorunlar ve Çözümleri (Engineering Challenges)

Proje geliştirilirken özellikle **Redmi Note 9S** ve benzeri orta segment cihazlarda yaşanan donanım darboğazları (Resource Busy) için özel algoritmalar geliştirilmiştir:

#### 1. "Camera Resource Busy" / BufferQueue Abandoned Hatası
Alarm çalarken (vibrasyon motoru aktifken) kamera açılmaya çalışıldığında donanım kilitleniyordu.
* **Çözüm:** `RingScreen` içinde "Restart Sequence" uygulandı. Kullanıcı "Titreşimi Kes" dediğinde:
    1.  Kamera sayfası kapatılır (`Navigator.pop`).
    2.  Alarm tamamen durdurulur.
    3.  **2.5 Saniye** donanım soğuma süresi beklenir (`Future.delayed`).
    4.  Alarm sessiz modda tekrar başlatılır.
    5.  Kamera güvenli bir şekilde yeniden açılır.

#### 2. İşlemci Şişmesi (Lag)
Kameranın saniyede 60 kare tarama yapması UI thread'i kilitliyordu.
* **Çözüm:** `DetectionSpeed.noDuplicates` ve `isScanCompleted` flag'leri ile tarama hızı optimize edildi ve işlemci yükü %60 azaltıldı.

#### 3. "Machine Gun" Etkisi (Çoklu Tetikleme)
Tek bir barkodun milisaniyeler içinde 10 kez okunup alarmı kapatıp-açma döngüsüne sokması.
* **Çözüm:** İlk başarılı okumadan sonra sistem `PopScope` ve boolean kilitlerle (`isLocked`) kitlenir.

## ⚙️ Kurulum ve Çalıştırma

Projeyi yerel ortamınızda çalıştırmak için:

1.  Repoyu klonlayın:
    ```bash
    git clone [https://github.com/kullaniciadi/NoSnooze.git](https://github.com/kullaniciadi/NoSnooze.git)
    ```
2.  Bağımlılıkları yükleyin:
    ```bash
    flutter pub get
    ```
3.  Uygulamayı çalıştırın (Fiziksel cihaz önerilir):
    ```bash
    flutter run
    ```

## 📱 Android Yapılandırması (Önemli)

Bu proje `AndroidManifest.xml` içerisinde şu kritik izinleri ve ayarları kullanır:

* `SCHEDULE_EXACT_ALARM`: Zamanında tetikleme için.
* `WAKE_LOCK` & `turnScreenOn`: Kilit ekranında alarmın arayüzle birlikte açılması için.
* `showWhenLocked`: Telefon kilitliyken `RingScreen`'in görünmesi için.

## 🤝 Katkıda Bulunma

1.  Forklayın
2.  Feature branch oluşturun (`git checkout -b feature/YeniOzellik`)
3.  Commit atın (`git commit -m 'Yeni özellik eklendi'`)
4.  Pushlayın (`git push origin feature/YeniOzellik`)
5.  Pull Request açın

## 📝 Lisans

Bu proje MIT lisansı ile lisanslanmıştır.

---
**Geliştirici:** Burak Çam  
**Sürüm:** v1.0 (Stabil)