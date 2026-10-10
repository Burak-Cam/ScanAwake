package com.burakcam.uyan

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.view.WindowManager
import com.gdelataillade.alarm.services.AlarmRingingLiveData
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

    // FIX (lockscreen-leak, 2026-10-10, device-reported): the manifest declares
    // showWhenLocked/turnScreenOn statically (kept on purpose — a cold-start
    // alarm must surface over the keyguard), and Stage 2 re-asserts them via
    // showOverLockscreen(). Nothing ever turned them back OFF when no alarm was
    // ringing, so with the app in the foreground, power-off -> power-on showed
    // the full app OVER the lock screen without PIN/fingerprint: alarms could be
    // disabled and barcodes deleted on a locked phone.
    // ringFlowActive mirrors RingScreen's lifetime (keepScreenOn true/false is
    // already called exactly at its initState/dispose).
    private var ringFlowActive = false

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
                    // FIX 2026-07-26 (Phase 10 finding): nothing in this app kept the
                    // screen awake while an alarm was being dismissed. With MIUI's
                    // default 30s screen timeout, a mission that takes a while — the
                    // water mission in particular, which the user reported as "baya
                    // zor doldu" — can lose the foreground when the display sleeps.
                    // Two consequences, both bad:
                    //   1) the mission silently stalls (its camera/mic stop feeding),
                    //   2) on Android 14+ the microphone is cut the moment the app
                    //      leaves the foreground, because this app deliberately has
                    //      NO microphone-typed foreground service (see AndroidManifest).
                    // Holding FLAG_KEEP_SCREEN_ON for the lifetime of RingScreen keeps
                    // the app in the foreground for the whole dismiss flow, which is
                    // also simply correct UX: the alarm screen must not sleep while it
                    // is asking the user to do something.
                    "keepScreenOn" -> {
                        ringFlowActive = true
                        setKeepScreenOn(true)
                        result.success(true)
                    }
                    "releaseScreenOn" -> {
                        ringFlowActive = false
                        setKeepScreenOn(false)
                        releaseLockscreenIfIdle()
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

    // Best-effort, like every other native helper here: a failure must never crash
    // the app mid-alarm. Worst case on failure is the pre-existing behaviour (the
    // screen may time out), never a trapped user.
    private fun setKeepScreenOn(on: Boolean) {
        try {
            runOnUiThread {
                if (on) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        } catch (_: Exception) {
        }
    }

    // Screen-off pauses the activity: the moment to drop the over-keyguard
    // flags so the next screen-on shows the keyguard, not the app.
    override fun onPause() {
        super.onPause()
        releaseLockscreenIfIdle()
    }

    // Clear showWhenLocked/turnScreenOn unless an alarm is ringing or the
    // dismiss flow (RingScreen, Stage 1 or 2) is on screen. While ringing, the
    // alarm plugin's own observer sets them TRUE again on every ringing=true
    // transition, so clearing here can never hide a later alarm. Best-effort.
    private fun releaseLockscreenIfIdle() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return
        if (ringFlowActive) return
        if (AlarmRingingLiveData.instance.value == true) return
        try {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        } catch (_: Exception) {
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
