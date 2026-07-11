# Source: 09-PROGUARD-RULES-STARTER-DRAFT.md + flutter-tflite#278 (kanonik GPU-delegate kuralı)
# ── TensorFlow Lite / LiteRT (tflite_flutter 0.12.1 → litert 1.4.0 + litert-gpu 1.4.0) ──
-keep class org.tensorflow.** { *; }
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.gpu.**

# ── Google ML Kit (mobile_scanner barkod + image labeling) ──
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**

# ── Flutter (savunmacı; embedding consumer-rules genelde yeter) ──
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# ── play-core (Flutter deferred-components referansı R8'i takar) ──
-dontwarn com.google.android.play.core.**

# ── (RUNTIME) İlk minified build FAIL ederse:
#    uyan/build/app/outputs/mapping/release/missing_rules.txt içeriğini buraya
#    yapıştır → rebuild. Build temiz geçerse dosya oluşmayabilir (== eksik kural yok). ──
