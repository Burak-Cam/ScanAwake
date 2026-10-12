package com.burakcam.uyan

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.lifecycle.Observer
import com.gdelataillade.alarm.services.AlarmRingingLiveData
import com.gdelataillade.alarm.services.NotificationOnKillService
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

    // FIX (pin-prompt-on-ring, 2026-10-10, device-reported on MIUI): the alarm
    // plugin's own ringing observer (AlarmPlugin.notificationObserver) calls
    // KeyguardManager.requestDismissKeyguard() when the alarm starts. On a
    // secure lock that opens the PIN/fingerprint bouncer ON TOP of the ring
    // screen — the alarm is only reachable after a "back" gesture. This app
    // already removed requestDismissKeyguard from its Stage-2 path for exactly
    // this reason (see showOverLockscreen); Stage 1 still got it from the
    // plugin. We replace the plugin's observer with one that does the same
    // show-over-keyguard work WITHOUT asking to unlock: showWhenLocked +
    // turnScreenOn alone is device-verified on MIUI (Stage 2 runs that way).
    // On ringing=false the flags are released only when idle (see
    // releaseLockscreenIfIdle) instead of unconditionally — so Stage 2 no
    // longer depends on winning the old postValue(false) race either.
    private val ringingObserver = Observer<Boolean> { ringing ->
        if (ringing == true) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                try {
                    setShowWhenLocked(true)
                    setTurnScreenOn(true)
                } catch (_: Exception) {
                }
            }
        } else {
            releaseLockscreenIfIdle()
        }
    }

    // The plugin registers its observer in onAttachedToActivity, which runs
    // inside FlutterActivity.onCreate. Drop every observer bound to this
    // activity (the plugin's included) and install ours. Idempotent; re-run on
    // onStart in case the plugin re-attached. LiveData only dispatches once the
    // activity is STARTED, so the plugin's observer never fires in between.
    private fun takeOverRingingObserver() {
        try {
            AlarmRingingLiveData.instance.removeObservers(this)
            AlarmRingingLiveData.instance.observe(this, ringingObserver)
        } catch (_: Exception) {
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        takeOverRingingObserver()
    }

    override fun onStart() {
        takeOverRingingObserver()
        super.onStart()
    }

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
                    // F-2 (CR-03 follow-up): raw exact-alarm app-op state. See
                    // exactAlarmOpDenied() for why canScheduleExactAlarms() alone
                    // is not enough on Android 12.
                    "exactAlarmOpDenied" -> {
                        result.success(exactAlarmOpDenied())
                    }
                    // F-1 (CR-03 follow-up): open the "Alarms & reminders" page
                    // for this app directly. false = could not open (caller falls
                    // back to the generic app settings page).
                    "openExactAlarmSettings" -> {
                        result.success(openExactAlarmSettings())
                    }
                    // Review 2026-10-10 #1: is the plugin's kill-warning service
                    // running right now? See killWarningServiceRunning().
                    "killWarningServiceRunning" -> {
                        result.success(killWarningServiceRunning())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Review 2026-10-10 #1: the alarm plugin's setWarningNotificationOnKill
    // stops a running NotificationOnKillService and then tries to start it in
    // the same main-thread step; the start returns early because isRunning
    // stays true until onDestroy, so the service ends up stopped. Dart reads
    // this flag to sequence the restart (refreshKillWarning). Read-only.
    private fun killWarningServiceRunning(): Boolean {
        return try {
            NotificationOnKillService.isRunning
        } catch (_: Exception) {
            false
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

    // F-2 (CR-03 follow-up, device evidence 2026-10-10, Redmi Note 9S /
    // Android 12): an app on the battery-optimization allowlist is EXEMPT from
    // SCHEDULE_EXACT_ALARM, so switching "Alarms & reminders" off cancels
    // nothing and canScheduleExactAlarms() stays true (dumpsys alarm:
    // exactAllowReason=allow-listed). If the exemption goes away later, the
    // pending alarm cannot start its foreground service and drops silently
    // (ForegroundServiceStartNotAllowedException). Read the RAW app-op so Dart
    // can warn about that "one setting away from silence" state.
    // - SDK < 31: no such permission -> false.
    // - SDK >= 33: the manifest declares USE_EXACT_ALARM, granted at install and
    //   not user-revocable -> the state cannot occur -> false.
    // - 31..32: denied unless MODE_ALLOWED or MODE_DEFAULT (AlarmManagerService
    //   on S treats MODE_DEFAULT as granted for an app that declares the
    //   permission). The Settings app writes the UID mode, which
    //   unsafeCheckOpNoThrow evaluates first (device: "Uid mode:
    //   SCHEDULE_EXACT_ALARM: deny"). Literal op string on purpose: the OPSTR
    //   constant may be hidden on API 31.
    // Best-effort: any failure -> false, which is exactly today's behavior.
    private fun exactAlarmOpDenied(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return false
        return try {
            val appOps = getSystemService(AppOpsManager::class.java) ?: return false
            val mode = appOps.unsafeCheckOpNoThrow(
                "android:schedule_exact_alarm",
                applicationInfo.uid,
                packageName
            )
            mode != AppOpsManager.MODE_ALLOWED && mode != AppOpsManager.MODE_DEFAULT
        } catch (_: Exception) {
            false
        }
    }

    // F-1 (CR-03 follow-up): open this app's "Alarms & reminders" page directly
    // (device-verified to be the right page on MIUI). permission_handler's
    // Permission.scheduleExactAlarm.request() is NOT used: it skips the request
    // when the status already reads GRANTED, which is exactly the F-2 state
    // (battery exemption), so it would open nothing. packageName is the
    // applicationId -> correct target. Started from the activity, so no
    // NEW_TASK flag. Any failure (incl. ActivityNotFoundException) -> false.
    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:$packageName")
                )
            )
            true
        } catch (_: Exception) {
            false
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
