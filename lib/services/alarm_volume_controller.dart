import 'package:flutter/services.dart';

import 'native_channel.dart';

/// ENG-01 (sov-02): thin MethodChannel wrapper over the native AudioManager
/// STREAM_ALARM controls in MainActivity. During a Stage-2 mission the
/// `volume: 0.5` soft loop is routed to the Android ALARM stream (sov-01), but
/// the user's alarm-volume SLIDER can still make it nearly silent. These calls
/// temporarily force the system alarm-stream volume to max and restore the
/// user's original value on every mission exit.
///
/// Uses the app's single native channel ([kNativeChannel], native_channel.dart
/// — shared on purpose, do NOT rename). The Android-first app has no iOS
/// native counterpart, so on iOS (or any platform/engine without the handler)
/// these are safe no-ops: boost returns null (=> nothing to restore) and
/// restore swallows the error.

/// Pushes the system STREAM_ALARM volume to max and returns the ORIGINAL volume
/// so the caller can restore it later. Returns `null` on any failure
/// (PlatformException, missing handler, iOS) — a null result means "no boost
/// happened", so the caller treats restore as a no-op. Best-effort: a failed
/// volume call must never trap the user (core value).
Future<int?> boostAlarmVolume() async {
  try {
    return await kNativeChannel.invokeMethod<int>('boostAlarmVolume');
  } on PlatformException {
    return null;
  } catch (_) {
    return null;
  }
}

/// Restores the user's original alarm-stream volume captured by
/// [boostAlarmVolume]. Best-effort: any error (PlatformException/iOS/missing
/// handler) is swallowed — a failed restore must never crash the app.
Future<void> restoreAlarmVolume(int original) async {
  try {
    await kNativeChannel
        .invokeMethod('restoreAlarmVolume', {'original': original});
  } on PlatformException {
    // No-op: not available on this platform / engine.
  } catch (_) {
    // No-op: best-effort restore.
  }
}
