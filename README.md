# NoSnooze 📵

**"No Snooze Allowed. You Have To Get Up."**

NoSnooze is an aggressive alarm application developed for people who have difficulty waking up. It **will not stop ringing until the user scans a pre-defined barcode**. Unlike standard alarms, NoSnooze forces you to get out of bed and perform a physical action.

## 🚀 Key Features

* **Barcode Dismissal:** The ONLY way to stop the alarm is by scanning a saved barcode of an item (toothpaste, book, or shampoo) with the camera.
* **Fault-Tolerant Camera Management:** A custom "Restart Sequence" architecture prevents conflicts between the vibrator motor and the camera hardware.
* **Smart Battery Management:** Stable operation even on devices with aggressive battery optimization, such as Xiaomi/MIUI.
* **Multi-Language Support:** Full support for Turkish (TR) and English (EN).
* **Dark Mode:** A full black, OLED-friendly interface that is easy on the eyes.
* **Flashlight Control:** Integrated torch control for scanning barcodes easily in dark rooms.

## 🛠️ Technical Architecture and Stack

This project is built with **Flutter** and incorporates specific engineering solutions against hardware limitations.

* **SDK:** Flutter (Dart 3.x)
* **Alarm Engine:** `alarm: ^5.0.0` (Utilizes the Android AlarmManager API)
* **Scanner:** `mobile_scanner: ^5.0.0` (ML Kit based)
* **Storage:** `shared_preferences`
* **Permissions:** `permission_handler`

### 🔥 Critical Engineering Challenges and Solutions

Specialized algorithms were developed to overcome the hardware bottlenecks (Resource Busy) experienced particularly on **Redmi Note 9S** and similar mid-range devices:

#### 1. "Camera Resource Busy" / BufferQueue Abandoned Error
The hardware would freeze when the camera tried to open while the alarm was ringing (vibration motor active).

* **Solution:** A "Restart Sequence" is executed within `RingScreen`. When the user taps "Cut Vibration":
    1.  The camera page is closed (`Navigator.pop`).
    2.  The alarm is completely stopped.
    3.  A **2.5 SECOND** hardware cool-down period is enforced (`Future.delayed`).
    4.  The alarm is restarted silently.
    5.  The camera is safely reopened after the delay.

#### 2. CPU Overload (Lag)
The camera continuously scanning at high frame rates would lock up the UI thread.

* **Solution:** Scanning speed was optimized using `DetectionSpeed.noDuplicates` within `MobileScannerController` and stabilized with an `isScanCompleted` flag, reducing CPU load by approximately 60%.

#### 3. "Machine Gun" Effect (Multi-Triggering)
A single barcode read would trigger the stop function 10 times within milliseconds, causing instability.

* **Solution:** The system is locked immediately after the first successful read using a `PopScope` and boolean lock (`isLocked` flag).

## ⚙️ Setup and Running the Project

To run the project in your local environment:

1.  Clone the repository:
    ```bash
    git clone [https://github.com/kullaniciadi/NoSnooze.git](https://github.com/kullaniciadi/NoSnooze.git)
    ```
2.  Install dependencies:
    ```bash
    flutter pub get
    ```
3.  Run the application (A physical device is recommended for testing the alarm functionality):
    ```bash
    flutter run
    ```

## 📱 Android Configuration (Crucial)

This project utilizes critical permissions and settings within `AndroidManifest.xml`:

* `SCHEDULE_EXACT_ALARM`: For timely alarm triggering.
* `WAKE_LOCK` & `turnScreenOn`: To ensure the alarm interface displays over the lock screen.
* `showWhenLocked`: Allows the `RingScreen` to appear even when the phone is locked.

## 🤝 Contributing

1.  Fork the repository.
2.  Create a feature branch (`git checkout -b feature/NewFeature`).
3.  Commit your changes (`git commit -m 'feat: Added new feature'`).
4.  Push to the branch (`git push origin feature/NewFeature`).
5.  Open a Pull Request.

## 📝 License

This project is licensed under the MIT License.

---
**Developer:** Burak Çam
**Version:** v1.0 (Stable)
