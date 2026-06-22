package com.burakcam.uyan

import android.content.Context
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // FIX (lockscreen-mission-hidden): the alarm package's AlarmPlugin observer
    // calls activity.setShowWhenLocked(false) + setTurnScreenOn(false) the moment
    // Alarm.stop() flips AlarmRingingLiveData to false (AlarmService.stopAlarm).
    // That runtime call OVERRIDES the static manifest showWhenLocked=true, so the
    // Stage-2 mission surface drops behind the keyguard during the Stage-1 ->
    // Stage-2 handoff. We re-assert the lock-screen window flags here, invoked
    // from Dart right after Alarm.stop() inside _handoffToMission.
    //
    // CYCLE 2 (device-verified): requestDismissKeyguard was REMOVED. On a secure
    // lock it raised an unwanted PIN/auth prompt after the barcode (it asks to
    // UNLOCK, it does not show-over). Stage 1 was always shown OVER the keyguard
    // (setShowWhenLocked only, never dismissing it), so Stage 2 must do the same:
    // setShowWhenLocked(true) + setTurnScreenOn(true) ONLY, no keyguard dismiss.
    private val channelName = "com.burakcam.uyan/keyguard"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showOverLockscreen" -> {
                        showOverLockscreen()
                        result.success(true)
                    }
                    // ENG-01 (sov-02): force the system STREAM_ALARM volume to max
                    // during a Stage-2 mission so the volume:0.5 soft loop is loud
                    // and INDEPENDENT of the user's alarm-volume slider (the Stage-1
                    // -> Stage-2 Alarm.stop() drops the alarm package's volumeEnforced
                    // boost, so the alarm stream falls back to the slider level).
                    // Returns the ORIGINAL volume so Dart can restore it on exit.
                    "boostAlarmVolume" -> {
                        result.success(boostAlarmVolume())
                    }
                    // Restore the user's original alarm-stream volume on mission exit.
                    "restoreAlarmVolume" -> {
                        try {
                            val original = call.argument<Int>("original")
                            if (original != null) {
                                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                                am.setStreamVolume(AudioManager.STREAM_ALARM, original, 0)
                            }
                        } catch (_: Exception) {
                            // Swallow: a failed restore must never crash the app.
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ENG-01 (sov-02): read the current alarm-stream volume, then push it to max
    // (flags 0 — NO FLAG_SHOW_UI; we don't want a volume overlay mid-mission).
    // Returns the original volume (Int) so Dart can restore it, or null on any
    // failure. Best-effort/defensive: must never crash and trap the user.
    private fun boostAlarmVolume(): Int? {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val original = am.getStreamVolume(AudioManager.STREAM_ALARM)
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, max, 0)
            original
        } catch (_: Exception) {
            null
        }
    }

    private fun showOverLockscreen() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return
        runOnUiThread {
            // Show OVER the keyguard, exactly like Stage 1 did — do NOT dismiss it
            // (requestDismissKeyguard triggers a PIN prompt on secure locks).
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }
}
