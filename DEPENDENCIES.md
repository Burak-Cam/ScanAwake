# Dependencies & Security Inventory — ScanAwake

A living inventory of everything third-party the app ships: SDKs, Dart/Flutter
packages, on-device ML models, and data assets. Purpose: track versions so we
can **update on release / advisory**, and know exactly what is bundled for
license + security review.

> Maintain this file whenever `pubspec.yaml` changes or a model/asset is added.
> Resolved versions below are from `pubspec.lock` — re-check with
> `flutter pub outdated` (updates) and each package's pub.dev / repo (advisories).
> Last reviewed: 2026-06-21.

## Toolchain

| Component | Version / constraint | Notes |
|-----------|----------------------|-------|
| Flutter (CI pin) | **3.41.7** stable | `.github/workflows/ci.yml`. Must track the lockfile floor. |
| Dart SDK | `>=3.11.0 <4.0.0` (lockfile floor) | `pubspec.yaml` declares `>=3.5.0` but `vibration 3.2.0` raised the real floor to Dart 3.11 / Flutter 3.41. |
| Android | minSdk **26**, targetSdk **36**, JDK 17 | minSdk 26 floor comes from `tflite_flutter` native libs (Phase 7). |
| iOS | secondary target | `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` set. |

## Direct runtime dependencies

Resolved versions from `pubspec.lock`. The **license** column is the commonly
published license per package and is informational — the authoritative,
exact-text aggregation is the in-app **Licenses** page (`showLicensePage`) and
each package's pub.dev page. Verify before relying on it legally.

| Package | Constraint | Resolved | Purpose | License (verify) |
|---------|-----------|----------|---------|------------------|
| `alarm` | ^5.1.0 | 5.1.5 | Full-screen looping alarms (audio + vibration + kill-warning). Core. | MIT |
| `mobile_scanner` | ^5.2.3 | 5.2.3 | Barcode/QR scanning (ML Kit) to dismiss. | BSD-3-Clause |
| `audioplayers` | ^6.0.0 | 6.5.1 | Soft-loop audio hand-off + ringtone preview. | MIT |
| `camera` | ^0.12.0+1 | 0.12.0+1 | Camera frames for Lümen/Renk/Nesne missions. | BSD-3-Clause |
| `google_mlkit_image_labeling` | ^0.14.2 | 0.14.2 | On-device image labeling (Nesne mission), bundled local model. | MIT |
| `google_mlkit_commons` | ^0.11.0 | 0.11.1 | `InputImage` conversion (direct import). | MIT |
| `tflite_flutter` | ^0.12.1 | 0.12.1 | Raw on-device TFLite inference (YAMNet, Su mission). | Apache-2.0 |
| `record` | ^6.1.1 | 6.2.1 | 16kHz PCM16 mic stream for YAMNet. Pinned to 6.x (7.x not cleared). | BSD-3-Clause |
| `vibration` | ^3.2.0 | 3.2.0 | Looping vibration for the Su mission (mic audio-focus pivot). Raises Dart floor to 3.11. | MIT |
| `permission_handler` | ^11.3.1 | 11.4.0 | Runtime permissions (camera, mic, notif, exact-alarm, battery). | MIT |
| `shared_preferences` | ^2.3.2 | 2.5.4 | Local key/value persistence (alarms, barcodes, streak, tokens, settings). | BSD-3-Clause |
| `file_picker` | ^8.0.0 | 8.3.7 | Pick a custom ringtone file. | MIT |
| `path_provider` | ^2.1.5 | 2.1.5 | App-support path for the bundled .tflite model copy. | BSD-3-Clause |
| `flutter_fgbg` | ^0.7.1 | 0.7.1 | Foreground/background escape detection (anti-cheat). | MIT |
| `cupertino_icons` | ^1.0.8 | 1.0.8 | iOS-style icons. | MIT |
| `flutter_localizations` | SDK | — | TR/EN Material/Cupertino delegates. | BSD-3-Clause |
| `intl` | (transitive) | 0.20.2 | Locale formatting (via flutter_localizations). | BSD-3-Clause |

## Dev dependencies

| Package | Constraint | Resolved | Purpose | License (verify) |
|---------|-----------|----------|---------|------------------|
| `flutter_test` | SDK | — | Test framework. | BSD-3-Clause |
| `flutter_lints` | ^5.0.0 | 5.0.0 | Lint rule set (`analysis_options.yaml`). | BSD-3-Clause |
| `mocktail` | ^1.0.4 | 1.0.5 | Mocking in unit tests. | MIT |

## On-device ML models & data (bundled in `assets/ml/`)

All run fully on-device; no network, no Firebase. See `NOTICE` for attributions.

| Asset | Provenance | License | Shape / notes |
|-------|-----------|---------|---------------|
| `yamnet.tflite` | Official Google MediaPipe YAMNet (audio event classifier) | **Apache-2.0** | input `[15600]` (rank-1) → output `[1,521]`. Su mission. |
| `yamnet_class_map.csv` | tensorflow/models AudioSet class map (521 rows) | **Apache-2.0** | maps YAMNet output index → label. |
| `object_labeler.tflite` | EfficientNet-Lite0, ImageNet-trained, metadata-embedded | **Apache-2.0** (model arch/weights) | Nesne mission; copied to app-private dir at runtime. |

## Audio assets (bundled in `assets/sounds/`)

| Asset | License | Status |
|-------|---------|--------|
| `alarm1.mp3` … `alarm9.mp3` | **UNKNOWN — must verify before Play Store release** | ⚠️ Provenance unconfirmed. If not original/royalty-free, replace with CC0/royalty-free alarm tones before a commercial release (potential copyright risk on a paid app). |

## Maintenance & security checklist

- **Check for updates:** `flutter pub outdated` (and review changelogs before
  bumping). Major bumps: `flutter pub upgrade --major-versions` — then re-run
  `flutter analyze` + `flutter test` + **device-test** the affected mission.
- **CI pin discipline:** when a new dep raises the Dart/Flutter floor (see the
  `vibration` → Dart 3.11 case), bump `ci.yml`'s `flutter-version` to match the
  lockfile floor, or CI `pub get` fails before analyze/test run.
- **Network surface:** the app is offline by design. The release APK previously
  merged `INTERNET`/push/telephony permissions from ML deps — stripped via
  `tools:node="remove"` (PR #11). **Re-verify with `aapt` if ML deps change.**
- **Pinned on purpose:** `record` stays on 6.x (7.x API not cleared for this
  device/flow). Revisit deliberately, not via blanket upgrade.
- **Advisories:** watch each package's repo/pub.dev. No known-vulnerable package
  is flagged as of the last review.
- **Provenance to close before release:** the `assets/sounds/*.mp3` licensing.
