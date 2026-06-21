import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.burakcam.uyan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    // MIS-03 (Phase 6): do NOT compress the bundled .tflite object-labeling model
    // — ML Kit memory-maps it, and a compressed asset fails to load at runtime.
    androidResources {
        noCompress += "tflite"
    }

    defaultConfig {
        applicationId = "com.burakcam.uyan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 26: tflite_flutter 0.12.1 floor (MIS-04 Phase 7); drops <Android 8.0
        // — Redmi Note 9S Android 11 unaffected. Set explicitly because the inherited
        // flutter.minSdkVersion (24) is below the TFLite native-lib floor.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Defined ONLY when key.properties exists. Wrapping in this guard avoids
        // the "null cannot be cast to non-null type kotlin.String" crash that would
        // otherwise break BOTH debug and release builds when no keystore is present.
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Uses the real release config when key.properties is present;
            // falls back to the debug key so `flutter run --release` keeps working.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
